// The library in memory: filters, playlists and offline play-state changes.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../filter/filter.dart';
import 'db.dart';
import 'models.dart';

class Library extends ChangeNotifier {
  Library(this.db);
  final LocalDb db;

  Map<int, Channel> channels = {};

  List<String> get allTags => {for (final c in channels.values) ...c.tags}.toList()..sort();
  List<Episode> episodes = [];
  Map<int, Episode> byId = {};
  Map<int, Play> plays = {};
  List<Playlist> playlists = [];
  Map<int, Map<int, double>> manual = {};
  Map<int, String> downloaded = {};
  Prefs prefs = Prefs({});
  DeviceSettings device = DeviceSettings({});

  late FilterEnv env;
  bool _countedUseDownloaded = false;
  List<FilterItem> _items = [];
  Map<int, int> _index = {};

  /// Called after a play changes locally, so sync can push it soon.
  VoidCallback? onLocalChange;

  Future<void> load() async {
    channels = {for (final c in await db.channels()) c.id: c};
    episodes = await db.episodes();
    plays = {for (final p in await db.plays()) p.episode: p};
    for (final (_, c) in await db.pending()) {
      plays.putIfAbsent(c.episode, () => Play(c.episode)).apply(c);
    }
    playlists = await db.playlists();
    manual = await db.playlistItems();
    downloaded = {for (final r in await db.downloads()) r['episode'] as int: r['path'] as String};
    prefs = Prefs(await db.getJson('prefs') ?? {});
    // Falls back once to the copy the server used to send.
    device = DeviceSettings(await db.getJson('device_settings') ?? ((await db.getJson('device'))?['settings'] as Map?)?.cast<String, dynamic>() ?? {});
    _rebuild();
  }

  Future<void> saveDevice(DeviceSettings d) async {
    device = d;
    await db.put('device_settings', jsonEncode(d.json));
    notifyListeners();
  }

  /// Why this device can't download a playlist: downloading would change which episodes it holds.
  String? downloadError(String filter) {
    final r = parseFilter(filter, env.copyWith(forbidDownloaded: true));
    if (r.error != null) return r.error!.msg;
    if (r.filter!.usesPlaylist && _countedUseDownloaded) return r"it uses $playlist, and another playlist uses $downloaded";
    return null;
  }

  bool usesDownloaded(String filter) => parseFilter(filter, env).filter?.usesDownloaded ?? false;

  Play play(int id) => plays[id] ?? Play(id);
  Channel? channelOf(Episode e) => channels[e.channelId];

  List<FilterOption> _unique(List<FilterOption> opts) {
    final count = <String, int>{};
    for (final o in opts) {
      count.update(o.label.toLowerCase(), (n) => n + 1, ifAbsent: () => 1);
    }
    final seen = <String, int>{};
    final out = <FilterOption>[];
    for (final o in opts) {
      final k = o.label.toLowerCase();
      final n = seen.update(k, (n) => n + 1, ifAbsent: () => 1);
      out.add(count[k]! > 1 && n > 1 ? FilterOption(o.id, '${o.label} ($n)') : o);
    }
    return out;
  }

  void _rebuild() {
    episodes.sort((a, b) => b.publishedUnix != a.publishedUnix ? b.publishedUnix.compareTo(a.publishedUnix) : b.id.compareTo(a.id));
    byId = {for (final e in episodes) e.id: e};
    _index = {for (var i = 0; i < episodes.length; i++) episodes[i].id: i};
    playlists.sort((a, b) => a.pos != b.pos ? a.pos.compareTo(b.pos) : a.id.compareTo(b.id));
    final chs = channels.values.toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    env = FilterEnv(now: DateTime.now(), channels: _unique([for (final c in chs) FilterOption('${c.id}', c.title)]));
    _items = [for (final e in episodes) _item(e)];
    _countedUseDownloaded = false;
    // $playlist counts the listener's own playlists that don't use it themselves.
    for (final p in playlists) {
      final f = parseFilter(p.filter, env).filter;
      if (p.builtin.isNotEmpty || f == null || f.usesPlaylist) continue;
      if (f.usesDownloaded) _countedUseDownloaded = true;
      for (final it in _items) {
        if (f.match(it)) it.inPlaylist = true;
      }
    }
    notifyListeners();
  }

  FilterItem _item(Episode e) {
    final ch = channels[e.channelId];
    final p = play(e.id);
    return FilterItem(
      title: e.title,
      channel: '${e.channelId}',
      channelName: ch?.title ?? '',
      length: e.duration,
      published: e.publishedUnix,
      media: e.media,
      season: e.season,
      number: e.number,
      type: e.type,
      position: p.position,
      played: p.played,
      starred: p.starred,
      downloaded: downloaded.containsKey(e.id),
      tags: ch?.tags ?? const [],
    );
  }

  /// Refreshes one episode's filter view after its play changed, without rebuilding everything.
  void _refreshItem(int id) {
    final i = _index[id];
    if (i == null) return;
    final pl = _items[i].inPlaylist;
    _items[i] = _item(episodes[i])..inPlaylist = pl;
  }

  ParseResult parse(String text) => parseFilter(text, env.copyWith());

  List<Episode> match(Filter f) => [
    for (var i = 0; i < episodes.length; i++)
      if (f.match(_items[i])) episodes[i],
  ];

  /// An episode's place in a playlist's shuffle; the server's library.go has the same sum.
  static int shuffleKey(int seed, int id) {
    var h = 0;
    for (final n in [id, seed]) {
      for (var s = 0; s < 32; s += 8) {
        h = (h + ((n >> s) & 0xff)) & 0xffffffff;
        h = (h + (h << 10)) & 0xffffffff;
        h ^= h >> 6;
      }
    }
    h = (h + (h << 3)) & 0xffffffff;
    h ^= h >> 11;
    return (h + (h << 15)) & 0xffffffff;
  }

  /// [seed] fixes the shuffle order, so it only changes when the seed does.
  void sortEpisodes(List<Episode> list, String how, [Map<int, double>? order, int seed = 0]) {
    if (how == 'shuffle') {
      final keys = {for (final e in list) e.id: shuffleKey(seed, e.id)};
      list.sort((a, b) => keys[a.id] != keys[b.id] ? keys[a.id]!.compareTo(keys[b.id]!) : a.id.compareTo(b.id));
      return;
    }
    int cmp(Episode a, Episode b) {
      switch (how) {
        case 'oldest':
          return a.publishedUnix.compareTo(b.publishedUnix);
        case 'shortest':
          return a.duration.compareTo(b.duration);
        case 'longest':
          return b.duration.compareTo(a.duration);
        case 'manual':
          final pa = order?[a.id], pb = order?[b.id];
          if (pa != null && pb != null) return pa.compareTo(pb);
          if ((pa == null) != (pb == null)) return pa != null ? -1 : 1;
          return a.publishedUnix.compareTo(b.publishedUnix);
      }
      return b.publishedUnix.compareTo(a.publishedUnix);
    }

    mergeSort(list, compare: cmp);
  }

  /// A playlist's episodes in its show order, or the filter error.
  (List<Episode>, FilterError?) playlistEpisodes(Playlist p) {
    final r = parseFilter(p.filter, env);
    if (r.error != null) return (const [], r.error);
    final list = match(r.filter!);
    sortEpisodes(list, p.sort, manual[p.id], p.seed);
    return (list, null);
  }

  int notDone(List<Episode> list) => list.where((e) => !play(e.id).played).length;

  Playlist? _playlistOf(String from) {
    if (!from.startsWith('playlist:')) return null;
    final id = int.tryParse(from.substring(9));
    return playlists.where((x) => x.id == id).firstOrNull;
  }

  /// Whether the next episode starts by itself: only from a playlist ("playlist:ID") that is set to.
  bool autoplays(String from) => _playlistOf(from)?.autoplay ?? false;

  /// The next unplayed episode of the playlist this one was started from; nothing follows outside a playlist.
  Episode? nextAfter(String from, int id) {
    final p = _playlistOf(from);
    if (p == null) return null;
    var seen = false;
    for (final e in playlistEpisodes(p).$1) {
      if (seen && e.id != id && !play(e.id).played) return e;
      if (e.id == id) seen = true;
    }
    return null;
  }

  Episode? startOf(List<Episode> list) => list.where((e) => !play(e.id).played).firstOrNull;

  int unplayed(int channelId) => episodes.where((e) => e.channelId == channelId && !play(e.id).played).length;

  /// Every local change goes to the database, the pending list for sync, and the filter view.
  Future<void> change(PlayChange c) async {
    final p = plays.putIfAbsent(c.episode, () => Play(c.episode));
    if (!p.apply(c)) return;
    await db.savePlay(p);
    await db.addPending(c);
    _refreshItem(c.episode);
    notifyListeners();
    onLocalChange?.call();
  }

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> mark(int id, String field, bool value) => change(PlayChange(episode: id, field: field, value: value, at: _now()));

  Future<void> markMany(Iterable<int> ids, String field, bool value) async {
    for (final id in ids) {
      await mark(id, field, value);
    }
  }

  Future<void> setPosition(int id, int pos) => change(PlayChange(episode: id, field: 'position', position: pos, at: _now()));

  Future<void> markOlderPlayed(Episode e) => markMany(
    [
      for (final x in episodes)
        if (x.channelId == e.channelId && x.publishedUnix < e.publishedUnix) x.id,
    ],
    'played',
    true,
  );

  void setDownloaded(Map<int, String> d) {
    downloaded = d;
    _rebuild();
  }

  Future<void> reload() async {
    await load();
  }
}
