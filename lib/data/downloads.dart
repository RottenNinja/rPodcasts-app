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
    final rows = await db.downloads();
    sizes = {for (final r in rows) r['episode'] as int: r['size'] as int};
    pinned = {
      for (final r in rows)
        if (r['pinned'] == 1) r['episode'] as int,
    };
    lib.setDownloaded({for (final r in rows) r['episode'] as int: r['path'] as String});
  }

  Future<void> _limit(int n) async {
    if (n < 1 || n == atOnce) return;
    await FileDownloader().configure(globalConfig: (Config.holdingQueue, (n, null, null)));
    atOnce = n;
    await db.put('downloads_at_once', '$n');
  }

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
      for (final id in active.keys.toList()) {
        if (wantIds.contains(id) || pinned.contains(id)) continue;
        await cancel(id);
        await db.event('download', 'Cancelled "${lib.byId[id]?.title ?? id}": no longer in a downloaded playlist');
      }
      waiting.clear();
      for (final e in over) {
        waiting[e.id] = DownloadState(e.id)..waiting = 'storage limit';
      }
      for (final e in want) {
        if (sizes.containsKey(e.id) || active.containsKey(e.id)) continue;
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
        ..waiting = 'resuming';
      await db.event('download', 'Resumed "${e.title}" at ${(st.progress * 100).round()}%: $reason');
      return;
    }
    await _enqueue(e, reason);
  }

  Future<void> _enqueue(Episode e, String reason) async {
    final st = DownloadState(e.id);
    active[e.id] = st;
    notifyListeners();
    try {
      var url = e.mediaUrl;
      var size = e.size;
      if (!e.direct) {
        final link = await api.get('/episodes/${e.id}/stream', {'download': '1'}) as Map;
        url = api.absolute('${link['url']}');
        size = (link['size'] as num?)?.toInt() ?? 0;
      }
      final ext = e.direct ? (p.extension(Uri.parse(url).path).isEmpty ? '.mp3' : p.extension(Uri.parse(url).path)) : '.mp4';
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
      await FileDownloader().enqueue(task);
      await db.event('download', 'Started "${e.title}": $reason');
    } catch (err) {
      active.remove(e.id);
      failed[e.id] = st..error = '$err';
      await db.event('download', 'Failed "${e.title}": $err');
      notifyListeners();
    }
  }

  Future<void> _onUpdate(TaskUpdate u) async {
    final id = int.tryParse(u.task.taskId);
    if (id == null) return;
    final st = active.putIfAbsent(id, () => DownloadState(id));
    if (u.task.metaData == 'pinned') pinned.add(id);
    if (u is TaskProgressUpdate) {
      st.progress = u.progress.clamp(0, 1);
      if (u.hasExpectedFileSize) st.expectedBytes = u.expectedFileSize;
      if (u.hasNetworkSpeed) st.speedMBps = u.networkSpeed;
      notifyListeners();
      return;
    }
    if (u is! TaskStatusUpdate) return;
    final title = lib.byId[id]?.title ?? 'episode $id';
    switch (u.status) {
      case TaskStatus.complete:
        active.remove(id);
        final path = await u.task.filePath();
        final size = await File(path).length();
        await db.saveDownload(id, path, size, pinned: u.task.metaData == 'pinned');
        _tries.remove(id);
        await db.event('download', 'Downloaded "$title" (${(size / 1048576).toStringAsFixed(1)} MB)');
        await _loadHeld();
      case TaskStatus.failed || TaskStatus.notFound:
        active.remove(id);
        failed[id] = st
          ..error = u.exception?.description ?? u.status.name
          ..task = u.task is DownloadTask ? u.task as DownloadTask : null;
        // A file that isn't there won't appear by asking again.
        if (u.status == TaskStatus.notFound) _tries[id] = _autoTries;
        await db.event(
          'download',
          'Failed "$title" at ${(st.progress * 100).round()}%: ${st.error}${retriesItself(id) ? '; it is tried again after the next sync' : ''}',
        );
      case TaskStatus.canceled:
        active.remove(id);
      case TaskStatus.waitingToRetry:
        st.waiting = 'connection lost, retrying shortly';
      case TaskStatus.paused:
        st.waiting = 'paused, resumes by itself';
      case TaskStatus.enqueued:
        st.waiting = lib.device.wifiOnly ? 'queued (Wi-Fi only)' : 'queued ($atOnce at a time)';
      case TaskStatus.running:
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
    await FileDownloader().cancelTaskWithId('$id');
    active.remove(id);
    notifyListeners();
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
