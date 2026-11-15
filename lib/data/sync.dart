// Sync with the server: push this device's pending changes, then pull everything since the cursor.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'db.dart';
import 'library.dart';

class SyncService extends ChangeNotifier {
  SyncService({required this.api, required this.db, required this.lib, required this.onSignedOut});
  final Api api;
  final LocalDb db;
  final Library lib;
  final VoidCallback onSignedOut;

  bool running = false;
  DateTime? lastSync;
  String lastError = '';
  int pending = 0;

  /// Runs after each successful sync, so downloads can follow the new state.
  Future<void> Function()? afterSync;

  Timer? _soon;
  Timer? _every;
  Completer<void>? _queued;
  Duration _backoff = const Duration(seconds: 30);

  Future<void> start() async {
    final last = await db.get('last_sync');
    if (last != null) lastSync = DateTime.fromMillisecondsSinceEpoch(int.parse(last));
    pending = await db.pendingCount();
    lib.onLocalChange = () {
      pending++;
      notifyListeners();
      _soon?.cancel();
      _soon = Timer(const Duration(seconds: 5), syncNow);
    };
    _every = Timer.periodic(const Duration(minutes: 15), (_) => syncNow());
    unawaited(syncNow());
  }

  @override
  void dispose() {
    _soon?.cancel();
    _every?.cancel();
    super.dispose();
  }

  Future<void> syncNow() async {
    if (running) return (_queued ??= Completer<void>()).future;
    running = true;
    lastError = '';
    notifyListeners();
    try {
      final todo = await db.pending();
      if (todo.isNotEmpty) {
        for (var i = 0; i < todo.length; i += 2000) {
          final chunk = todo.sublist(i, (i + 2000).clamp(0, todo.length));
          await api.post('/sync', {
            'changes': [for (final (_, c) in chunk) c.toJson()],
          });
          await db.clearPending(chunk.last.$1);
        }
        await db.event('sync', 'Sent ${todo.length} change${todo.length == 1 ? '' : 's'}');
      }
      var cursor = await db.get('cursor') ?? '0';
      var pulled = 0;
      while (true) {
        final page = (await api.get('/sync', {'cursor': cursor, 'limit': '2000'}) as Map).cast<String, dynamic>();
        await db.applyChanges(page);
        pulled += (page['episodes'] as List).length + (page['plays'] as List).length + (page['channels'] as List).length;
        cursor = '${page['cursor']}';
        if (page['more'] != true) break;
      }
      await lib.load();
      lastSync = DateTime.now();
      await db.put('last_sync', '${lastSync!.millisecondsSinceEpoch}');
      if (pulled > 0) await db.event('sync', 'Received $pulled updates');
      pending = await db.pendingCount();
      _backoff = const Duration(seconds: 30);
      // Downloads can take minutes to start, so they must not hold up the next sync.
      if (afterSync != null) unawaited(afterSync!().catchError((Object e) => db.event('download', 'Planning downloads failed: $e')));
    } on ApiError catch (e) {
      lastError = e.message;
      await db.event('sync', 'Sync failed: ${e.message}');
      if (e.signedOut) {
        onSignedOut();
      } else {
        _retry();
      }
    } catch (e) {
      lastError = '$e';
      await db.event('sync', 'Sync failed: $e');
      _retry();
    } finally {
      running = false;
      notifyListeners();
    }
    final q = _queued;
    if (q != null) {
      _queued = null;
      unawaited(syncNow().whenComplete(q.complete));
    }
  }

  // Retrying after a failure notices the connection coming back without asking the OS.
  void _retry() {
    _soon?.cancel();
    _soon = Timer(_backoff, syncNow);
    final next = _backoff * 2;
    _backoff = next > const Duration(minutes: 15) ? const Duration(minutes: 15) : next;
  }
}
