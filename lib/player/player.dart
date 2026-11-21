// Playback: the downloaded file, else the enclosure, else the server's stream.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' as ja;
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import '../data/api.dart';
import '../data/library.dart';
import '../data/models.dart';

/// One playback backend; just_audio on phones for audio, media_kit for video and on desktop.
abstract class _Engine {
  Future<void> open(String url, Duration start);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration d);
  Future<void> setSpeed(double s);
  Future<void> dispose();
  Duration get position;
  Duration? get duration;
  bool get playing;
  bool get buffering;
  Stream<void> get stalls;

  /// Fires when playing starts or stops, whoever asked: the app, a headset going away, a phone call.
  Stream<void> get pauses;
  Stream<void> get changes;
  Stream<void> get completed;
  Stream<String> get errors;
}

class _JustAudio implements _Engine {
  final ja.AudioPlayer p = ja.AudioPlayer(userAgent: 'podcasts-app');
  @override
  Future<void> open(String url, Duration start) async {
    final src = url.startsWith('/') ? ja.AudioSource.file(url) : ja.AudioSource.uri(Uri.parse(url));
    await p.setAudioSource(src, initialPosition: start);
  }

  @override
  Future<void> play() async => unawaited(p.play());
  @override
  Future<void> pause() => p.pause();
  @override
  Future<void> seek(Duration d) => p.seek(d);
  @override
  Future<void> setSpeed(double s) => p.setSpeed(s);
  @override
  Future<void> dispose() => p.dispose();
  @override
  Duration get position => p.position;
  @override
  Duration? get duration => p.duration;
  @override
  bool get playing => p.playing;
  @override
  bool get buffering => p.processingState == ja.ProcessingState.buffering || p.processingState == ja.ProcessingState.loading;
  @override
  Stream<void> get stalls => p.processingStateStream.map((_) {});
  @override
  Stream<void> get pauses => p.playingStream.map((_) {});
  @override
  Stream<void> get changes => p.playbackEventStream.map((_) {});
  @override
  Stream<void> get completed => p.processingStateStream.where((s) => s == ja.ProcessingState.completed).map((_) {});
  @override
  Stream<String> get errors =>
      p.playbackEventStream.transform(StreamTransformer.fromHandlers(handleData: (_, _) {}, handleError: (Object e, _, sink) => sink.add('$e')));
}

class _MediaKit implements _Engine {
  _MediaKit({required this.session}) : video = null;
  final mk.Player p = mk.Player(configuration: const mk.PlayerConfiguration(logLevel: mk.MPVLogLevel.warn));
  mkv.VideoController? video;

  /// On a phone, where media_kit doesn't ask for the sound itself, so other apps would play on over it.
  final AudioSession? session;
  @override
  Future<void> open(String url, Duration start) async {
    // media_kit's 5 s default is shorter than a joined stream takes to send its first byte.
    final native = p.platform;
    if (native is mk.NativePlayer) await native.setProperty('network-timeout', '60');
    // A start of zero would still ask for a seek, which a joined stream refuses.
    await p.open(mk.Media(url, start: start == Duration.zero ? null : start), play: false);
  }

  @override
  Future<void> play() async {
    await session?.setActive(true);
    await p.play();
  }

  @override
  Future<void> pause() => p.pause();
  @override
  Future<void> seek(Duration d) => p.seek(d);
  @override
  Future<void> setSpeed(double s) => p.setRate(s);
  @override
  Future<void> dispose() => p.dispose();
  @override
  Duration get position => p.state.position;
  @override
  Duration? get duration => p.state.duration == Duration.zero ? null : p.state.duration;
  @override
  bool get playing => p.state.playing;
  @override
  bool get buffering => p.state.buffering;
  @override
  Stream<void> get stalls => p.stream.buffering.map((_) {});
  @override
  Stream<void> get pauses => p.stream.playing.map((_) {});
  @override
  Stream<void> get changes => p.stream.position.map((_) {});
  @override
  Stream<void> get completed => p.stream.completed.where((c) => c).map((_) {});
  @override
  Stream<String> get errors => p.stream.error;
}

class Chapter {
  const Chapter(this.start, this.title);
  final int start;
  final String title;
}

/// An episode's chapters: the ones synced with it, or else its podcast's chapter file; none when neither is there.
Future<List<Chapter>> fetchChapters(Episode e) async {
  final synced = [
    for (final c in (e.json['chapters'] as List? ?? const []))
      if (c is Map) Chapter((c['start'] as num? ?? 0).toInt(), '${c['title'] ?? ''}'),
  ];
  if (synced.isNotEmpty || e.chaptersUrl.isEmpty) return synced;
  try {
    final r = await http.get(Uri.parse(e.chaptersUrl)).timeout(const Duration(seconds: 20));
    final doc = jsonDecode(utf8.decode(r.bodyBytes)) as Map;
    return [
      for (final c in (doc['chapters'] as List? ?? const []))
        if (c is Map && c['toc'] != false) Chapter((c['startTime'] as num? ?? 0).toInt(), '${c['title'] ?? ''}'),
    ]..sort((a, b) => a.start.compareTo(b.start));
  } catch (_) {
    return const [];
  }
}

class PlayerController extends ChangeNotifier {
  PlayerController({required this.lib, required this.api});
  final Library lib;
  final Api api;

  Episode? episode;
  String from = '';
  String error = '';
  bool joined = false;
  int offset = 0;
  String _base = '';

  /// The length the server found for a stream, for an episode whose listing gave none.
  int _streamLength = 0;
  int speed = 100;
  List<Chapter> chapters = [];
  Episode? next;

  /// Whether [next] starts by itself when this episode ends.
  bool autoNext = false;
  bool skipNext = false;
  bool showNotice = false;
  String sleep = '';
  _Engine? _engine;
  final List<StreamSubscription<void>> _subs = [];
  Timer? _saveTimer;
  Timer? _sleepTimer;
  Timer? _watchTimer;
  Duration _seenAt = Duration.zero;
  bool _moving = false;
  bool _primed = false;
  int _stuck = 0;
  bool _ending = false;
  bool _skipping = false;

  /// Whether the episode plays from a file on this device, which has no connection to lose.
  bool _local = false;

  /// Reopens since the episode last played on for a while; a broken connection is opened again a few times before it counts as a failure.
  int _retries = 0;
  int _retryFrom = 0;

  /// The connection broke or may have while paused, so Play opens the episode again where it is.
  bool _stale = false;
  DateTime? _pausedAt;
  SystemControls? handler;

  /// The phone's audio session, which a video claims as it plays; just_audio claims it for audio itself.
  AudioSession? _session;

  /// A call or another app's short sound paused the video, which plays on once it is over.
  bool _resumeAfterInterruption = false;

  /// The Next episode button over a video was swiped away, for this episode.
  bool nextHidden = false;

  mkv.VideoController? get video => _engine is _MediaKit ? (_engine as _MediaKit).video : null;
  bool get playing => _engine?.playing ?? false;
  bool get buffering => loading || (_engine?.buffering ?? false);

  /// True from the moment an episode is asked for until its player has opened it, which for a stream takes the server a few seconds.
  bool loading = false;

  /// Counts the episodes asked for, so one that is still opening can tell it has been replaced.
  int _asking = 0;

  /// How many times an episode was started from somewhere that doesn't show the player; the app brings the player up for a video.
  int asked = 0;
  int get position => offset + (_engine?.position.inSeconds ?? 0);
  int get duration {
    final d = episode?.duration ?? 0;
    if (d > 0) return d;
    // What the player itself reports for a stream is only what has arrived so far.
    if (_streamLength > 0) return _streamLength;
    return offset + (_engine?.duration?.inSeconds ?? 0);
  }

  /// [reveal] says the caller isn't the episode's own page, so a video needs the player brought up.
  Future<void> start(Episode e, {String from = '', int? at, required bool reveal}) {
    if (reveal) asked++;
    _retries = 0;
    return _play(e, from: from, at: at);
  }

  /// [keepSpeed] carries the speed over when the same episode is opened again.
  Future<void> _play(Episode e, {required String from, int? at, int? keepSpeed}) async {
    await _savePosition();
    await _teardown();
    episode = e;
    this.from = from;
    error = '';
    skipNext = false;
    showNotice = false;
    nextHidden = false;
    _resumeAfterInterruption = false;
    _ending = false;
    joined = false;
    offset = 0;
    _streamLength = 0;
    _stale = false;
    _pausedAt = null;
    chapters = [];
    final ch = lib.channelOf(e);
    final pl = lib.play(e.id);
    speed = keepSpeed ?? ch?.speed ?? 100;
    var start = at ?? (pl.inProgress ? pl.position : (ch?.skipStart ?? 0));
    next = lib.nextAfter(from, e.id);
    autoNext = lib.autoplays(from);
    _moving = _primed = false;
    _stuck = 0;
    // The player exists before its address is known, so a video shows its picture area, loading, at once.
    final video = e.media == 'video';
    final engine = (video || isDesktop) ? _MediaKit(session: _session) : _JustAudio();
    if (engine is _MediaKit && video) engine.video = mkv.VideoController(engine.p);
    _engine = engine;
    final asking = ++_asking;
    loading = true;
    notifyListeners();
    String url;
    final local = lib.downloaded[e.id];
    _local = local != null && File(local).existsSync();
    if (_local) {
      url = local!;
    } else if (!e.streamed) {
      url = e.mediaUrl;
    } else {
      try {
        final link = await api.get('/episodes/${e.id}/stream') as Map;
        _base = api.absolute('${link['url']}');
        joined = link['joined'] == true;
        _streamLength = (link['duration'] as num?)?.toInt() ?? 0;
        url = _base;
      } on Object catch (err) {
        if (asking != _asking) return;
        error = '$err';
        loading = false;
        notifyListeners();
        return;
      }
      if (asking != _asking) return;
    }
    _subs.add(engine.errors.listen(_playError));
    if (engine is _MediaKit) _subs.add(engine.p.stream.log.listen((l) => debugPrint('player ${l.level} ${l.prefix}: ${l.text}')));
    try {
      debugPrint('player: opening ${joined ? '$url&t=$start' : url} at ${joined ? 0 : start}s');
      if (joined) {
        offset = start;
        await engine.open(start > 0 ? '$url&t=$start' : url, Duration.zero);
      } else {
        await engine.open(url, Duration(seconds: start));
      }
      if (asking != _asking) return;
      await engine.setSpeed(speed / 100);
      _subs.add(engine.changes.listen((_) => _tick()));
      _subs.add(engine.completed.listen((_) => _ended()));
      _subs.add(engine.stalls.listen((_) => notifyListeners()));
      _subs.add(engine.pauses.listen((_) => _shown()));
      await engine.play();
    } catch (err) {
      if (asking != _asking) return;
      error = 'Could not play: $err';
    }
    if (asking != _asking) return;
    loading = false;
    _saveTimer = Timer.periodic(const Duration(seconds: 30), (_) => _savePosition());
    _watchTimer = Timer.periodic(const Duration(seconds: 1), (_) => _watch());
    unawaited(_loadChapters(e));
    handler?.show(this);
    notifyListeners();
  }

  Future<void> _attachSession() async {
    final s = await AudioSession.instance;
    await s.configure(const AudioSessionConfiguration.music());
    s.interruptionEventStream.listen(_interrupted);
    s.becomingNoisyEventStream.listen((_) => _soundGone());
    _session = s;
  }

  _MediaKit? get _claimed => _engine is _MediaKit && _session != null ? _engine as _MediaKit : null;

  /// Another app took the sound for a video; just_audio does the same for audio by itself.
  Future<void> _interrupted(AudioInterruptionEvent ev) async {
    final e = _claimed;
    if (e == null) return;
    if (ev.type == AudioInterruptionType.duck) return e.p.setVolume(ev.begin ? 50 : 100);
    if (ev.begin) {
      if (!e.playing) return;
      _resumeAfterInterruption = ev.type == AudioInterruptionType.pause;
      await e.pause();
      await _savePosition();
    } else if (_resumeAfterInterruption && !e.playing) {
      _resumeAfterInterruption = false;
      _moving = _primed = false;
      await e.play();
    }
  }

  /// Headphones came out during a video.
  Future<void> _soundGone() async {
    final e = _claimed;
    if (e == null || !e.playing) return;
    await e.pause();
    await _savePosition();
  }

  void hideNext() {
    nextHidden = true;
    notifyListeners();
  }

  void _shown() {
    _pausedAt = playing ? null : (_pausedAt ?? DateTime.now());
    handler?.show(this);
    notifyListeners();
  }

  // The system can stop the sound (a headset connects or goes away) without telling the player, which then says it plays while standing still.
  Future<void> _watch() async {
    final e = _engine;
    if (e == null || loading || error.isNotEmpty || !e.playing) {
      _moving = _primed = false;
      return;
    }
    if (e.buffering) {
      _stuck = 0;
      return;
    }
    final at = e.position;
    if (at != _seenAt) {
      // The first change after a start or a seek is the jump to the new place, not playing.
      _seenAt = at;
      _moving = _primed;
      _primed = true;
      _stuck = 0;
      return;
    }
    // Only an episode seen moving can have been stopped; one still opening or seeking has not started.
    if (!_moving || ++_stuck < 3) return;
    _moving = _primed = false;
    _stale = !_local;
    await e.pause();
    await _savePosition();
    _shown();
  }

  void _playError(String err) {
    debugPrint('player error: $err');
    // A joined stream can't be seeked in; the player says so and plays on.
    if (err.contains('force-seekable') || err.contains('Cannot seek in this stream')) return;
    // A dropped connection plays on from what is buffered, so it is opened again now, or on Play when paused.
    if (_canRetry) {
      if (playing) {
        unawaited(_reopen());
      } else {
        _stale = true;
      }
      return;
    }
    error = 'Could not play: $err';
    notifyListeners();
  }

  bool get _canRetry => !_local && !loading && _retries < 3 && episode != null;

  /// Opens the episode again where it is, with a fresh stream link, keeping its speed.
  Future<void> _reopen() async {
    final e = episode;
    if (e == null) return;
    _retries++;
    _retryFrom = position;
    debugPrint('player: reopening at ${_retryFrom}s (try $_retries)');
    await _play(e, from: from, at: _retryFrom, keepSpeed: speed);
  }

  Future<void> _loadChapters(Episode e) async {
    final found = await fetchChapters(e);
    if (episode?.id != e.id) return;
    chapters = found;
    notifyListeners();
  }

  int _lastTick = -1;
  void _tick() {
    final e = episode;
    if (e == null) return;
    final t = position, d = duration;
    final end = d - (lib.channelOf(e)?.skipEnd ?? 0);
    final notice = d > 0 && next != null && autoNext && from.startsWith('playlist:') && !skipNext && end - t < 30 && end - t > 0;
    if (notice != showNotice) showNotice = notice;
    if (d > 0 && (lib.channelOf(e)?.skipEnd ?? 0) > 0 && t >= end) unawaited(_finish());
    if (_retries > 0 && t - _retryFrom > 60) _retries = 0;
    if (t != _lastTick) {
      _lastTick = t;
      handler?.show(this);
      notifyListeners();
    }
  }

  Future<void> _savePosition() async {
    final e = episode;
    if (e == null || _ending || position < (lib.channelOf(e)?.skipStart ?? 0) + 10) return;
    await lib.setPosition(e.id, position);
  }

  // A stream that breaks off looks like the end to the player, so the end only counts near the episode's known length.
  Future<void> _ended() async {
    final d = duration, short = d - position > (d > 600 ? d ~/ 10 : 60);
    if (error.isEmpty && !short) return _finish();
    if (error.isEmpty && _canRetry) return _reopen();
    await _engine?.pause();
    await _savePosition();
    if (error.isEmpty) error = 'Playback stopped before the end of the episode. Press play to carry on from here.';
    handler?.show(this);
    notifyListeners();
  }

  Future<void> _finish() async {
    final e = episode;
    if (e == null || _ending) return;
    _ending = true;
    await _engine?.pause();
    await lib.mark(e.id, 'played', true);
    if (sleep == 'end') {
      sleep = '';
      notifyListeners();
      return;
    }
    final n = next;
    if (n != null && autoNext && !skipNext) {
      await _play(n, from: from);
    } else {
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    // An episode that is still opening starts by itself.
    if (_engine == null || loading) return;
    // After a failure there is nothing open to resume, so Play opens the episode again where it stopped.
    final e = episode;
    _resumeAfterInterruption = false;
    if (error.isNotEmpty && e != null) return _play(e, from: from);
    if (playing) {
      await _engine!.pause();
      await _savePosition();
    } else {
      // A stream paused for long has lost its connection, and its link may have run out.
      final paused = _pausedAt;
      if (e != null && !_local && (_stale || (paused != null && DateTime.now().difference(paused) > const Duration(minutes: 5)))) {
        _retries = 0;
        return _play(e, from: from, at: position, keepSpeed: speed);
      }
      _moving = _primed = false;
      await _engine!.play();
    }
    handler?.show(this);
    notifyListeners();
  }

  Future<void> seek(int secs) async {
    final e = _engine;
    if (e == null || loading) return;
    secs = secs.clamp(0, duration > 0 ? duration - 1 : secs);
    _moving = _primed = false;
    if (joined) {
      offset = secs;
      await e.open('$_base&t=$secs', Duration.zero);
      await e.play();
    } else {
      await e.seek(Duration(seconds: secs));
    }
    notifyListeners();
  }

  Future<void> skipBack() => seek(position - lib.prefs.skipBack);
  Future<void> skipForward() => seek(position + lib.prefs.skipForward);

  Future<void> chapter(int dir) async {
    if (chapters.isEmpty) return;
    final t = position;
    var i = chapters.lastIndexWhere((c) => c.start <= t);
    if (i < 0) i = 0;
    if (dir < 0 && t - chapters[i].start < 3) i--;
    if (dir > 0) i++;
    if (i >= 0 && i < chapters.length) {
      await seek(chapters[i].start);
    } else if (dir < 0) {
      await seek(0);
    }
  }

  Future<void> setSpeed(int s) async {
    speed = s;
    await _engine?.setSpeed(s / 100);
    notifyListeners();
    final e = episode;
    if (e != null && lib.prefs.rememberSpeed) unawaited(_rememberSpeed(e.channelId, s));
  }

  Future<void> _rememberSpeed(int channel, int s) async {
    try {
      await api.post('/channels/$channel/speed', {'speed': '$s'});
      await lib.setChannelSpeed(channel, s);
    } on Object catch (err) {
      await lib.db.event('sync', 'Could not save the speed for "${lib.channels[channel]?.title ?? channel}": $err');
    }
  }

  void setSleep(String v) {
    _sleepTimer?.cancel();
    sleep = v;
    final m = int.tryParse(v);
    if (m != null) {
      _sleepTimer = Timer(Duration(minutes: m), () async {
        await _engine?.pause();
        await _savePosition();
        sleep = '';
        notifyListeners();
      });
    }
    notifyListeners();
  }

  /// Whether Next is offered: an episode is lined up and this one is in its last stretch, where the outro is.
  bool get offerNext {
    final d = duration;
    return next != null && d > 0 && position >= d * (100 - lib.prefs.nextAt) / 100;
  }

  /// Next skips what is left: the episode counts as played and the next one starts.
  Future<void> finishToNext() async {
    final e = episode, n = next;
    if (e == null || n == null || _skipping) return;
    _skipping = true;
    try {
      // An episode that already ended is still left by Next, so only a second press is ignored.
      _ending = true;
      await _engine?.pause();
      await lib.mark(e.id, 'played', true);
      await _play(n, from: from);
    } finally {
      _skipping = false;
    }
  }

  Future<void> playNext() async {
    final n = next;
    if (n == null) return;
    await _savePosition();
    await _play(n, from: from);
  }

  void dontPlayNext() {
    skipNext = true;
    showNotice = false;
    notifyListeners();
  }

  Future<void> close() async {
    await _savePosition();
    await _drop();
  }

  Future<void> _drop() async {
    await _teardown();
    episode = null;
    handler?.clear();
    notifyListeners();
  }

  /// Marks episodes played or unplayed; the one playing stops unsaved, so no later save puts it back in progress.
  Future<void> setPlayed(Iterable<int> ids, bool value) async {
    final list = ids.toList();
    if (list.contains(episode?.id)) await _drop();
    await lib.markMany(list, 'played', value);
  }

  Future<void> _teardown() async {
    _asking++;
    loading = false;
    _saveTimer?.cancel();
    _watchTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _engine?.dispose();
    _engine = null;
  }
}

/// Lock screen, notification, headset and Bluetooth controls.
class SystemControls extends BaseAudioHandler with SeekHandler {
  SystemControls(this.c);
  final PlayerController c;

  void show(PlayerController p) {
    final e = p.episode;
    if (e == null) return;
    final ch = p.lib.channelOf(e);
    mediaItem.add(
      MediaItem(
        id: '${e.id}',
        title: e.title,
        album: ch?.title,
        artist: ch?.author,
        duration: p.duration > 0 ? Duration(seconds: p.duration) : null,
        artUri: (e.artwork.isNotEmpty ? e.artwork : ch?.artwork ?? '').isEmpty ? null : Uri.parse(e.artwork.isNotEmpty ? e.artwork : ch!.artwork),
      ),
    );
    playbackState.add(
      PlaybackState(
        controls: [MediaControl.rewind, if (p.playing) MediaControl.pause else MediaControl.play, MediaControl.fastForward, MediaControl.skipToNext],
        systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: p.playing,
        updatePosition: Duration(seconds: p.position),
        speed: p.speed / 100,
      ),
    );
  }

  void clear() => playbackState.add(PlaybackState(processingState: AudioProcessingState.idle));

  @override
  Future<void> play() => c.playing ? Future.value() : c.toggle();
  @override
  Future<void> pause() => c.playing ? c.toggle() : Future.value();
  @override
  Future<void> seek(Duration position) => c.seek(position.inSeconds);
  @override
  Future<void> rewind() => c.skipBack();
  @override
  Future<void> fastForward() => c.skipForward();
  @override
  Future<void> skipToNext() => c.playNext();
  @override
  Future<void> stop() => c.close();
}

/// Connects the system media controls where the platform has them.
Future<void> attachSystemControls(PlayerController c) async {
  if (kIsWeb || Platform.isLinux || Platform.isWindows) return;
  if (!isDesktop) {
    try {
      await c._attachSession();
    } catch (e) {
      debugPrint('audio session unavailable: $e');
    }
  }
  try {
    c.handler = await AudioService.init(
      builder: () => SystemControls(c),
      config: const AudioServiceConfig(androidNotificationChannelId: 'ninja.rotten.rpodcast.playback', androidNotificationChannelName: 'Playback'),
    );
  } catch (e) {
    debugPrint('system controls unavailable: $e');
  }
}
