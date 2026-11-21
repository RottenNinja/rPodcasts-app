// Downloads: what this device keeps, fetched in the background and shown on the Status page with the reason for each.
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'db.dart';
import 'library.dart';
import 'models.dart';

class DownloadState {
  DownloadState(this.episode);
  final int episode;
  double progress = 0;
  int expectedBytes = 0;
  double speedMBps = 0;
  String waiting = '';
  String error = '';

  /// The task that failed, kept so it can pick up where it stopped.
  DownloadTask? task;

  /// Where the finished file lands, so a finish the downloader didn't report can still be seen.
  String path = '';
}

class Downloads extends ChangeNotifier {
  Downloads({required this.api, required this.db, required this.lib});
  final Api api;
  final LocalDb db;
  final Library lib;

  final Map<int, DownloadState> active = {};
  final Map<int, DownloadState> waiting = {};
  final Map<int, DownloadState> failed = {};
  Map<int, int> sizes = {};
  Set<int> pinned = {};

  /// Playlists set to download that can't be, by id, with the reason.
  Map<int, String> skipped = {};

  /// Automatic tries so far for each failed download; a manual Retry starts the count again.
  final Map<int, int> _tries = {};
  static const _autoTries = 5;

  /// Whether a failed download is tried again by itself after the next sync.
  bool retriesItself(int id) => (_tries[id] ?? 0) < _autoTries;

  /// Waiting their turn in this app, in order, each with the reason it was asked for; [_running] are handed to the downloader.
  final List<(Episode, String)> _queue = [];
  final Set<int> _running = {};
  final Set<int> _finishing = {};

  /// Automatic downloads stopped part way by Pause downloads, kept to resume from where they were.
  final Map<int, DownloadState> _held = {};
  Timer? _check;

  bool _planning = false;
  bool _ready = false;
  bool _replan = false;

  /// Where new downloads go; desktops can change it in Settings.
  String folder = '';

  /// How many downloads run at once, the rest waiting their turn: the server's "Streams at once", as each video download is one of its streams.
  int atOnce = 0;

  int get used => sizes.values.fold(0, (a, b) => a + b);

  Future<void> start() async {
    folder = await db.get('download_dir') ?? await _defaultFolder();
    await Directory(folder).create(recursive: true);
    await _loadHeld();
    if (Platform.isLinux) await _skipDownloaderMigration();
    try {
      await FileDownloader().ready.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      await db.event('download', 'Downloads unavailable: the downloader did not start');
      notifyListeners();
      return;
    }
    _ready = true;
    await _limit(int.tryParse(await db.get('downloads_at_once') ?? '') ?? 4);
    FileDownloader().updates.listen(_onUpdate);
    await FileDownloader().trackTasks();
    await FileDownloader().start();
  }

  Future<void> _loadHeld() async {
    var rows = await db.downloads();
    if (await _relink(rows)) rows = await db.downloads();
    sizes = {for (final r in rows) r['episode'] as int: r['size'] as int};
    pinned = {
      for (final r in rows)
        if (r['pinned'] == 1) r['episode'] as int,
    };
    lib.setDownloaded({for (final r in rows) r['episode'] as int: r['path'] as String});
  }

  // iOS gives the app a new container folder on each update, so a file's saved full path goes stale while the file stays.
  Future<bool> _relink(List<Map<String, Object?>> rows) async {
    final folders = {folder, await _defaultFolder()};
    var moved = 0;
    for (final r in rows) {
      final old = r['path'] as String;
      if (await File(old).exists()) continue;
      for (final dir in folders) {
        final now = p.join(dir, p.basename(old));
        if (now == old || !await File(now).exists()) continue;
        await db.moveDownload(r['episode'] as int, now);
        moved++;
        break;
      }
    }
    if (moved > 0) await db.event('download', 'Found $moved downloaded episodes again after the app moved its folder');
    return moved > 0;
  }

  Future<void> _limit(int n) async {
    if (n < 1 || n == atOnce) return;
    await FileDownloader().configure(globalConfig: (Config.holdingQueue, (n, null, null)));
    atOnce = n;
    await db.put('downloads_at_once', '$n');
    for (final (e, _) in _queue) {
      active[e.id]?.waiting = _queuedText;
    }
    await _pump();
  }

  String get _queuedText => 'queued (${atOnce < 1 ? 4 : atOnce} at a time)';

  // Asked for after each sync, when the server has just answered; without an answer the last known limit stays.
  Future<void> _followServerLimit() async {
    try {
      final r = await api.get('/settings') as Map;
      await _limit(((r['server'] as Map)['streams'] as num).toInt());
    } on Object catch (e) {
      debugPrint('downloads: no limit from the server: $e');
    }
  }

  int _estimate(Episode e) {
    if (e.size > 0) return e.size;
    final secs = e.duration > 0 ? e.duration : 3600;
    return e.media == 'video' ? secs * 250000 : secs * 16000;
  }

  /// The episodes this device should hold: the newest or oldest unplayed of each downloaded playlist, round-robin, within the storage limit.
  (List<Episode> want, List<Episode> overLimit) plan() {
    final lists = <List<Episode>>[];
    skipped = {};
    for (final pl in lib.playlists) {
      final pd = lib.device.forPlaylist(pl.id);
      if (!pd.download) continue;
      final why = lib.downloadError(pl.filter);
      if (why != null) {
        skipped[pl.id] = why;
        continue;
      }
      final (eps, err) = lib.playlistEpisodes(pl);
      if (err != null) continue;
      final open = eps.where((e) => !lib.play(e.id).played).toList()
        ..sort((a, b) {
          final c = a.publishedUnix.compareTo(b.publishedUnix);
          return pd.oldest ? (c != 0 ? c : a.id.compareTo(b.id)) : (c != 0 ? -c : b.id.compareTo(a.id));
        });
      lists.add(open.take(pd.count).toList());
    }
    final want = <Episode>[];
    final over = <Episode>[];
    final seen = <int>{};
    final limit = lib.device.storageMb * 1024 * 1024;
    var total = 0;
    for (final id in pinned) {
      final e = lib.byId[id];
      if (e != null && seen.add(id)) {
        want.add(e);
        total += sizes[id] ?? _estimate(e);
      }
    }
    for (var round = 0; lists.any((l) => round < l.length); round++) {
      for (final l in lists) {
        if (round >= l.length || !seen.add(l[round].id)) continue;
        final e = l[round];
        final size = sizes[e.id] ?? _estimate(e);
        if (limit > 0 && total + size > limit) {
          over.add(e);
          continue;
        }
        total += size;
        want.add(e);
      }
    }
    return (want, over);
  }

  /// Runs after each sync: downloads what is missing and deletes what is no longer wanted.
  Future<void> reconcile() async {
    if (!_ready) return;
    if (_planning) {
      _replan = true;
      return;
    }
    _planning = true;
    try {
      await _followServerLimit();
      final (want, over) = plan();
      final wantIds = {for (final e in want) e.id};
      for (final id in sizes.keys.toList()) {
        if (wantIds.contains(id)) continue;
        final pl = lib.play(id);
        if (pl.played) {
          if (pl.starred) continue;
          final after = lib.device.deleteAfter;
          if (after == 'never') continue;
          if (after == '1d' && DateTime.now().millisecondsSinceEpoch - pl.playedAt < 86400000) continue;
          await remove(id, 'played');
        } else if (!pinned.contains(id)) {
          await remove(id, 'no longer in a downloaded playlist');
        }
      }
      for (final id in {...active.keys, ..._held.keys}) {
        if (wantIds.contains(id) || pinned.contains(id)) continue;
        await cancel(id);
        await db.event('download', 'Cancelled "${lib.byId[id]?.title ?? id}": no longer in a downloaded playlist');
      }
      waiting.clear();
      for (final e in over) {
        waiting[e.id] = DownloadState(e.id)..waiting = 'storage limit';
      }
      final paused = lib.device.downloadsPaused;
      if (paused) await _holdAll();
      for (final e in want) {
        if (sizes.containsKey(e.id) || active.containsKey(e.id)) continue;
        if (paused) {
          if (failed.containsKey(e.id)) continue;
          final at = _held[e.id]?.progress ?? 0;
          waiting[e.id] = DownloadState(e.id)..waiting = at > 0 ? 'downloads paused at ${(at * 100).round()}%' : 'downloads paused';
          continue;
        }
        final held = _held.remove(e.id);
        if (held != null) {
          await _resume(e, held);
          continue;
        }
        // A sync just worked, so the connection is back: the moment to try failures again.
        if (!failed.containsKey(e.id)) {
          await _enqueue(e, 'in a downloaded playlist');
        } else if (retriesItself(e.id)) {
          await _again(e.id, 'trying again after a failure');
        }
      }
    } finally {
      _planning = false;
      notifyListeners();
    }
    if (_replan) {
      _replan = false;
      await reconcile();
    }
  }

  /// Stops automatic downloads, holding those part way, or lets them carry on; a tap on Download still downloads.
  Future<void> setPaused(bool paused) async {
    await lib.saveDevice(lib.device.withPaused(paused));
    await db.event('download', paused ? 'Downloads paused' : 'Downloads resumed');
    await reconcile();
    await _pump();
  }

  /// Asks the downloader, not just this app, as downloads started before the app did run on unseen.
  Future<void> _holdAll() async {
    final ids = {
      ...active.keys,
      for (final t in await FileDownloader().allTasks())
        if (t.metaData != 'pinned') ?int.tryParse(t.taskId),
    };
    for (final id in ids) {
      if (!pinned.contains(id) && !_held.containsKey(id)) await _hold(id);
    }
  }

  /// Pauses a running download so it can resume; one not yet running is cancelled, as nothing is lost.
  Future<void> _hold(int id) async {
    final st = active.remove(id) ?? DownloadState(id);
    _queue.removeWhere((q) => q.$1.id == id);
    _running.remove(id);
    final rec = await FileDownloader().database.recordForId('$id');
    final task = rec?.task ?? await FileDownloader().taskForId('$id');
    if (task is! DownloadTask) {
      if (task != null) await FileDownloader().cancelTaskWithId('$id');
      return;
    }
    if (rec != null && st.progress == 0) st.progress = rec.progress.clamp(0, 1);
    // Held before pausing, so the downloader's paused report doesn't bring it back.
    _held[id] = st..task = task;
    if (rec?.status == TaskStatus.paused) return;
    if (rec?.status == TaskStatus.running && await FileDownloader().pause(task)) return;
    _held.remove(id);
    await FileDownloader().cancelTaskWithId('$id');
  }

  Future<void> _resume(Episode e, DownloadState st) async {
    final task = st.task;
    if (task == null || !await FileDownloader().resume(task)) {
      await FileDownloader().cancelTaskWithId('${e.id}');
      return _enqueue(e, 'downloads resumed');
    }
    active[e.id] = st..waiting = 'resuming';
    _running.add(e.id);
    _watch();
    await db.event('download', 'Resumed "${e.title}" at ${(st.progress * 100).round()}%: downloads resumed');
  }

  /// Download on one episode keeps it until it is played.
  Future<void> pin(Episode e) async {
    pinned.add(e.id);
    if (sizes.containsKey(e.id)) {
      await db.setPinned(e.id, true);
    } else {
      failed.remove(e.id);
      await _enqueue(e, 'you asked for it');
    }
    notifyListeners();
  }

  Future<void> retry(int id) async {
    _tries.remove(id);
    await _again(id, 'retry');
    notifyListeners();
  }

  /// Picks a failed download up where it stopped when the server allows that, else starts it over.
  Future<void> _again(int id, String reason) async {
    final st = failed.remove(id);
    final e = lib.byId[id];
    if (e == null) return;
    _tries[id] = (_tries[id] ?? 0) + 1;
    final task = st?.task;
    if (task != null && await FileDownloader().taskCanResume(task) && await FileDownloader().resume(task)) {
      active[id] = DownloadState(id)
        ..progress = st!.progress
        ..expectedBytes = st.expectedBytes
        ..path = st.path
        ..waiting = 'resuming';
      _running.add(id);
      _watch();
      await db.event('download', 'Resumed "${e.title}" at ${(st.progress * 100).round()}%: $reason');
      return;
    }
    await _enqueue(e, reason);
  }

  /// Puts a download in line; it starts once fewer than [atOnce] are running.
  Future<void> _enqueue(Episode e, String reason) async {
    active[e.id] = DownloadState(e.id)..waiting = _queuedText;
    _queue.add((e, reason));
    notifyListeners();
    await _pump();
  }

  /// Hands queued downloads to the downloader while there is room.
  Future<void> _pump() async {
    while (_queue.isNotEmpty && _running.length < (atOnce < 1 ? 4 : atOnce)) {
      final (e, reason) = _queue.removeAt(0);
      if (!active.containsKey(e.id)) continue;
      _running.add(e.id);
      await _start(e, reason);
    }
    notifyListeners();
  }

  Future<void> _start(Episode e, String reason) async {
    final st = active[e.id] ?? (active[e.id] = DownloadState(e.id));
    st.waiting = 'starting';
    notifyListeners();
    try {
      var url = e.mediaUrl;
      var size = e.size;
      // A server from before podcast videos were streamed answers with the enclosure itself.
      if (e.streamed) {
        final link = await api.get('/episodes/${e.id}/stream', {'download': '1'}) as Map;
        url = api.absolute('${link['url']}');
        size = (link['size'] as num?)?.toInt() ?? size;
      }
      final own = p.extension(Uri.parse(url).path);
      final ext = url.startsWith(api.base) ? '.mp4' : (own.isEmpty || own.length > 5 ? (e.media == 'video' ? '.mp4' : '.mp3') : own);
      final task = DownloadTask(
        taskId: '${e.id}',
        url: url,
        // Used for progress only when the response has no Content-Length, as joined video streams don't.
        headers: {if (size > 0) 'Known-Content-Length': '$size'},
        filename: 'episode-${e.id}$ext',
        directory: folder,
        baseDirectory: BaseDirectory.root,
        updates: Updates.statusAndProgress,
        // Enforced by Android and iOS; desktops have no metered links, so they ignore it.
        requiresWiFi: lib.device.wifiOnly && !pinned.contains(e.id),
        allowPause: true,
        // Each retry resumes from the bytes already held when the server allows ranges.
        retries: 6,
        metaData: pinned.contains(e.id) ? 'pinned' : '',
      );
      st.path = p.join(folder, task.filename);
      // Logged first, as a short audio file can finish before enqueue returns.
      await db.event('download', 'Started "${e.title}": $reason');
      if (!await FileDownloader().enqueue(task)) throw StateError('the downloader refused it');
      _watch();
    } catch (err) {
      active.remove(e.id);
      _running.remove(e.id);
      failed[e.id] = st..error = '$err';
      await db.event('download', 'Failed "${e.title}": $err');
      notifyListeners();
    }
  }

  // The downloader doesn't always report a finish while the app runs; a running download whose task is gone and whose file is there has finished.
  void _watch() {
    _check ??= Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_running.isEmpty) {
        _check?.cancel();
        _check = null;
        return;
      }
      for (final id in _running.toList()) {
        final st = active[id];
        if (st == null || st.path.isEmpty || !await File(st.path).exists()) continue;
        if (await FileDownloader().taskForId('$id') != null) continue;
        await _completed(id, st.path, pinned.contains(id));
      }
    });
  }

  Future<void> _completed(int id, String path, bool pin) async {
    if ((sizes.containsKey(id) && !active.containsKey(id)) || !_finishing.add(id)) return;
    try {
      active.remove(id);
      _running.remove(id);
      final size = await File(path).length();
      await db.saveDownload(id, path, size, pinned: pin);
      _tries.remove(id);
      await db.event('download', 'Downloaded "${lib.byId[id]?.title ?? 'episode $id'}" (${(size / 1048576).toStringAsFixed(1)} MB)');
      await _loadHeld();
    } finally {
      _finishing.remove(id);
    }
    await _pump();
  }

  Future<void> _onUpdate(TaskUpdate u) async {
    final id = int.tryParse(u.task.taskId);
    if (id == null) return;
    if (u.task.metaData == 'pinned') pinned.add(id);
    if (_held.containsKey(id)) return;
    if (lib.device.downloadsPaused && u.task.metaData != 'pinned' && !pinned.contains(id)) {
      if (u is TaskStatusUpdate && !u.status.isFinalState) await _hold(id);
      if (u is! TaskStatusUpdate || !u.status.isFinalState) return;
    }
    if (u is TaskProgressUpdate) {
      // A late progress report must not bring back a download that has finished.
      final st = active[id];
      if (st == null) return;
      st.progress = u.progress.clamp(0, 1);
      if (u.hasExpectedFileSize) st.expectedBytes = u.expectedFileSize;
      if (u.hasNetworkSpeed) st.speedMBps = u.networkSpeed;
      notifyListeners();
      return;
    }
    if (u is! TaskStatusUpdate) return;
    final title = lib.byId[id]?.title ?? 'episode $id';
    final task = u.task;
    if (u.status == TaskStatus.complete) return _completed(id, await task.filePath(), task.metaData == 'pinned');
    if (u.status.isFinalState) {
      final st = active.remove(id) ?? DownloadState(id);
      _running.remove(id);
      if (u.status != TaskStatus.canceled) {
        failed[id] = st
          ..error = u.exception?.description ?? u.status.name
          ..task = task is DownloadTask ? task : null;
        // A file that isn't there won't appear by asking again.
        if (u.status == TaskStatus.notFound) _tries[id] = _autoTries;
        await db.event(
          'download',
          'Failed "$title" at ${(st.progress * 100).round()}%: ${st.error}${retriesItself(id) ? '; it is tried again after the next sync' : ''}',
        );
      }
      await _pump();
      return;
    }
    // A late report about a download that has finished must not bring it back.
    if (_finishing.contains(id) || (sizes.containsKey(id) && !active.containsKey(id))) return;
    // A download still running from before the app started counts towards those at once.
    final st = active.putIfAbsent(id, () => DownloadState(id));
    if (st.path.isEmpty && task is DownloadTask) st.path = p.join(task.directory, task.filename);
    _running.add(id);
    _watch();
    switch (u.status) {
      case TaskStatus.waitingToRetry:
        st.waiting = 'connection lost, retrying shortly';
      case TaskStatus.paused:
        st.waiting = 'paused, resumes by itself';
      case TaskStatus.enqueued:
        st.waiting = lib.device.wifiOnly ? 'queued (Wi-Fi only)' : _queuedText;
      default:
        st.waiting = '';
    }
    notifyListeners();
  }

  Future<void> remove(int id, String reason) async {
    final rows = await db.downloads();
    for (final r in rows.where((r) => r['episode'] == id)) {
      final f = File(r['path'] as String);
      if (await f.exists()) await f.delete();
    }
    await db.deleteDownload(id);
    pinned.remove(id);
    await db.event('download', 'Deleted "${lib.byId[id]?.title ?? id}": $reason');
    await _loadHeld();
    notifyListeners();
  }

  Future<void> cancel(int id) async {
    _queue.removeWhere((q) => q.$1.id == id);
    if (_running.remove(id) | (_held.remove(id) != null)) await FileDownloader().cancelTaskWithId('$id');
    active.remove(id);
    notifyListeners();
    await _pump();
  }

  // background_downloader's first-run migration needs the Documents folder, which Linux lacks without xdg-user-dirs, and then never becomes ready.
  static Future<void> _skipDownloaderMigration() async {
    final meta = File(p.join((await getApplicationSupportDirectory()).path, 'backgroundDownloaderDatabase', 'metaData'));
    if (await meta.exists() && await meta.length() > 0) return;
    await meta.parent.create(recursive: true);
    await meta.writeAsString('{"version":1}');
  }

  static Future<String> _defaultFolder() async {
    final env = Platform.environment;
    if (Platform.isLinux && env['HOME'] != null) return p.join(env['HOME']!, '.podcasts');
    if (Platform.isWindows && env['USERPROFILE'] != null) return p.join(env['USERPROFILE']!, 'Videos', 'Podcasts');
    return p.join((await getApplicationSupportDirectory()).path, 'downloads');
  }

  /// Files already held stay where they are; only new downloads use the new folder.
  Future<String?> setFolder(String path) async {
    final dir = Directory(p.normalize(path.trim()));
    if (!dir.isAbsolute) return 'Give a full path';
    try {
      await dir.create(recursive: true);
      final probe = File(p.join(dir.path, '.podcasts-write-test'));
      await probe.writeAsString('');
      await probe.delete();
    } on FileSystemException catch (e) {
      return 'Cannot write there: ${e.osError?.message ?? e.message}';
    }
    folder = dir.path;
    await db.put('download_dir', folder);
    await db.event('download', 'Download folder set to $folder');
    notifyListeners();
    return null;
  }
}
