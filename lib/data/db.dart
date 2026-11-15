// The local copy of the library, so the app works offline.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import 'models.dart';

class LocalDb {
  LocalDb._(this.db);
  final Database db;

  static Future<LocalDb> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    return openAt(p.join(dir.path, 'podcasts.db'));
  }

  static Future<LocalDb> openAt(String path) async {
    if (Platform.isLinux || Platform.isWindows) {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
    }
    final db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, _) async {
        final b = db.batch();
        b.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
        b.execute('CREATE TABLE channels (id INTEGER PRIMARY KEY, json TEXT NOT NULL)');
        b.execute('CREATE TABLE episodes (id INTEGER PRIMARY KEY, channel_id INTEGER NOT NULL, json TEXT NOT NULL)');
        b.execute('CREATE INDEX episodes_channel ON episodes (channel_id)');
        b.execute('CREATE TABLE plays (episode INTEGER PRIMARY KEY, json TEXT NOT NULL)');
        b.execute('CREATE TABLE playlists (id INTEGER PRIMARY KEY, json TEXT NOT NULL)');
        b.execute('CREATE TABLE playlist_items (playlist INTEGER NOT NULL, episode INTEGER NOT NULL, pos REAL NOT NULL, PRIMARY KEY (playlist, episode))');
        b.execute('CREATE TABLE pending (id INTEGER PRIMARY KEY AUTOINCREMENT, json TEXT NOT NULL)');
        b.execute(
          'CREATE TABLE downloads (episode INTEGER PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, done_at INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0)',
        );
        b.execute('CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL)');
        await b.commit(noResult: true);
      },
      // Version 2 dropped the queue and the archive; the server no longer takes their changes.
      onUpgrade: (db, from, _) async {
        if (from < 2) await db.delete('pending', where: "json LIKE '%\"field\":\"queued\"%' OR json LIKE '%\"field\":\"archived\"%'");
        // Version 3 moved flags and keys from #name to $name; # is tags only.
        if (from < 3) {
          for (final r in await db.query('playlists')) {
            final j = jsonDecode(r['json'] as String) as Map<String, dynamic>;
            final f = j['filter'];
            if (f is! String || !f.contains('#')) continue;
            await db.update('playlists', {'json': jsonEncode({...j, 'filter': _hashToDollar(f)})}, where: 'id = ?', whereArgs: [r['id']]);
          }
        }
      },
    );
    return LocalDb._(db);
  }

  Future<String?> get(String k) async {
    final r = await db.query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String;
  }

  Future<void> put(String k, String v) => db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<Map<String, dynamic>?> getJson(String k) async {
    final v = await get(k);
    return v == null ? null : jsonDecode(v) as Map<String, dynamic>;
  }

  Future<void> putJson(String k, Object v) => put(k, jsonEncode(v));

  Future<List<Map<String, dynamic>>> _jsonRows(String table) async => [
    for (final r in await db.query(table)) jsonDecode(r['json'] as String) as Map<String, dynamic>,
  ];

  Future<List<Channel>> channels() async => [for (final j in await _jsonRows('channels')) Channel(j)];
  Future<List<Episode>> episodes() async => [for (final j in await _jsonRows('episodes')) Episode(j)];
  Future<List<Play>> plays() async => [for (final j in await _jsonRows('plays')) Play.fromJson(j)];
  Future<List<Playlist>> playlists() async => [for (final j in await _jsonRows('playlists')) Playlist(j)];

  Future<Map<int, Map<int, double>>> playlistItems() async {
    final out = <int, Map<int, double>>{};
    for (final r in await db.query('playlist_items')) {
      out.putIfAbsent(r['playlist'] as int, () => {})[r['episode'] as int] = (r['pos'] as num).toDouble();
    }
    return out;
  }

  /// Applies one page of server changes in one transaction.
  Future<void> applyChanges(Map<String, dynamic> c) async {
    await db.transaction((t) async {
      final b = t.batch();
      for (final d in (c['deleted'] as List? ?? const [])) {
        final id = d['id'];
        switch (d['kind']) {
          case 'channel':
            b.delete('channels', where: 'id = ?', whereArgs: [id]);
          case 'episode':
            b.delete('episodes', where: 'id = ?', whereArgs: [id]);
            b.delete('plays', where: 'episode = ?', whereArgs: [id]);
            b.delete('playlist_items', where: 'episode = ?', whereArgs: [id]);
          case 'playlist':
            b.delete('playlists', where: 'id = ?', whereArgs: [id]);
            b.delete('playlist_items', where: 'playlist = ?', whereArgs: [id]);
        }
      }
      for (final j in (c['channels'] as List? ?? const [])) {
        b.insert('channels', {'id': j['id'], 'json': jsonEncode(j)}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final j in (c['episodes'] as List? ?? const [])) {
        b.insert('episodes', {'id': j['id'], 'channel_id': j['channel'], 'json': jsonEncode(j)}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final j in (c['plays'] as List? ?? const [])) {
        b.insert('plays', {'episode': j['episode'], 'json': jsonEncode(j)}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final j in (c['playlists'] as List? ?? const [])) {
        b.insert('playlists', {'id': j['id'], 'json': jsonEncode(j)}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final j in (c['playlist_items'] as List? ?? const [])) {
        b.insert('playlist_items', {'playlist': j['playlist'], 'episode': j['episode'], 'pos': j['pos']}, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (c['prefs'] != null) b.insert('kv', {'k': 'prefs', 'v': jsonEncode(c['prefs'])}, conflictAlgorithm: ConflictAlgorithm.replace);
      b.insert('kv', {'k': 'cursor', 'v': '${c['cursor']}'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await b.commit(noResult: true);
    });
  }

  Future<void> savePlay(Play p) => db.insert('plays', {'episode': p.episode, 'json': jsonEncode(p.toJson())}, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> addPending(PlayChange c) => db.insert('pending', {'json': jsonEncode(c.toJson())});

  Future<List<(int, PlayChange)>> pending() async => [
    for (final r in await db.query('pending', orderBy: 'id')) (r['id'] as int, PlayChange.fromJson(jsonDecode(r['json'] as String))),
  ];

  Future<void> clearPending(int upTo) => db.delete('pending', where: 'id <= ?', whereArgs: [upTo]);

  Future<int> pendingCount() async => Sqflite.firstIntValue(await db.rawQuery('SELECT count(*) FROM pending')) ?? 0;

  Future<List<Map<String, Object?>>> downloads() => db.query('downloads');

  Future<void> saveDownload(int episode, String path, int size, {bool pinned = false}) => db.insert('downloads', {
    'episode': episode,
    'path': path,
    'size': size,
    'done_at': DateTime.now().millisecondsSinceEpoch,
    'pinned': pinned ? 1 : 0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> setPinned(int episode, bool pinned) => db.update('downloads', {'pinned': pinned ? 1 : 0}, where: 'episode = ?', whereArgs: [episode]);

  Future<void> deleteDownload(int episode) => db.delete('downloads', where: 'episode = ?', whereArgs: [episode]);

  /// Events are the device's own history for the Status page.
  Future<void> event(String kind, String text) async {
    await db.insert('events', {'at': DateTime.now().millisecondsSinceEpoch, 'kind': kind, 'text': text});
    await db.delete('events', where: 'id <= (SELECT max(id) - 500 FROM events)');
  }

  Future<List<Map<String, Object?>>> events() => db.query('events', orderBy: 'id DESC', limit: 200);

  /// Signing out forgets the whole local copy.
  Future<void> wipe() async {
    for (final t in ['kv', 'channels', 'episodes', 'plays', 'playlists', 'playlist_items', 'pending', 'downloads', 'events']) {
      await db.delete(t);
    }
  }
}

/// Turns #name into $name for the names that were flags or keys, leaving tags and quoted text alone.
String _hashToDollar(String f) {
  const old = {'unplayed', 'played', 'inprogress', 'starred', 'downloaded', 'playlist', 'title', 'title.length', 'channel', 'length', 'left', 'published', 'media', 'type', 'season', 'number'};
  final name = RegExp(r'^[\p{L}\p{N}_.\-]*', unicode: true);
  final before = RegExp(r'[\s(!]', unicode: true);
  final r = f.runes.toList();
  var quoted = false;
  for (var i = 0; i < r.length; i++) {
    if (r[i] == 0x22) quoted = !quoted;
    if (r[i] != 0x23 || quoted || (i > 0 && !before.hasMatch(String.fromCharCode(r[i - 1])))) continue;
    if (old.contains(name.stringMatch(String.fromCharCodes(r, i + 1))!.toLowerCase())) r[i] = 0x24;
  }
  return String.fromCharCodes(r);
}
