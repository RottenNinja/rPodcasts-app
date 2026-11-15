// Artwork kept on the device, so podcasts and episodes look the same offline.
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'db.dart';

class ArtCache {
  ArtCache._(this.dir, this.db);
  final Directory dir;
  final LocalDb db;

  /// Bytes the cache holds on disk, for the Status page.
  int used = 0;

  final Map<String, Future<Uint8List>> _fetching = {};
  bool _keeping = false;

  static const _limit = 400 * 1048576;
  static const _shrinkOver = 800 * 1024;
  static const _shrinkTo = 640;

  static Future<ArtCache> open(LocalDb db) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'artwork'));
    await dir.create(recursive: true);
    final cache = ArtCache._(dir, db);
    await cache._prune();
    return cache;
  }

  // FNV-1a over the address: a stable file name without a hashing package.
  File _file(String url) {
    var h = 0xcbf29ce484222325;
    for (final c in url.codeUnits) {
      h = ((h ^ c) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return File(p.join(dir.path, '${h.toRadixString(16)}-${url.length}'));
  }

  /// The image at [url]: from the device when it is held, else fetched and kept.
  Future<Uint8List> bytes(String url) async {
    final f = _file(url);
    if (await f.exists()) return f.readAsBytes();
    // The block body matters: returning the removed future would make this one wait for itself.
    return _fetching[url] ??= _fetch(url, f).whenComplete(() {
      _fetching.remove(url);
    });
  }

  Future<Uint8List> _fetch(String url, File f) async {
    final r = await http.get(Uri.parse(url), headers: {'User-Agent': 'podcasts-app'}).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200 || r.bodyBytes.isEmpty) throw HttpException('artwork: HTTP ${r.statusCode}', uri: Uri.parse(url));
    final data = r.bodyBytes.length > _shrinkOver ? await _shrink(r.bodyBytes) : r.bodyBytes;
    final tmp = File('${f.path}.part');
    await tmp.writeAsBytes(data, flush: true);
    await tmp.rename(f.path);
    used += data.length;
    return data;
  }

  // Feeds often carry 3000 px covers of several MB; a phone never shows more than a few hundred.
  Future<Uint8List> _shrink(Uint8List original) async {
    try {
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(original),
        getTargetSize: (w, h) => w > _shrinkTo ? ui.TargetImageSize(width: _shrinkTo) : ui.TargetImageSize(width: w, height: h),
      );
      final image = (await codec.getNextFrame()).image;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      codec.dispose();
      return png == null || png.lengthInBytes >= original.length ? original : png.buffer.asUint8List();
    } on Object {
      return original;
    }
  }

  /// Fetches what is missing of [urls], a few at a time, and notes the outcome on the Status page.
  Future<void> keep(Iterable<String> urls) async {
    if (_keeping) return;
    _keeping = true;
    try {
      final missing = <String>[];
      for (final u in urls.toSet()) {
        if (u.isNotEmpty && !await _file(u).exists()) missing.add(u);
      }
      if (missing.isEmpty) return;
      var saved = 0, failed = 0;
      Future<void> worker() async {
        while (missing.isNotEmpty) {
          try {
            await bytes(missing.removeLast());
            saved++;
          } on Object {
            failed++;
          }
        }
      }

      await Future.wait([for (var i = 0; i < 4; i++) worker()]);
      await db.event('artwork', 'Saved $saved artwork image${saved == 1 ? '' : 's'} for offline use${failed > 0 ? '; $failed could not be fetched' : ''}');
      await _prune();
    } finally {
      _keeping = false;
    }
  }

  /// Measures the cache and drops the oldest files once it is over the limit.
  Future<void> _prune() async {
    final files = [
      await for (final f in dir.list())
        if (f is File) (f, await f.stat()),
    ]..sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var total = files.fold(0, (a, f) => a + f.$2.size);
    var dropped = 0;
    for (final (f, st) in files) {
      if (total <= _limit) break;
      await f.delete();
      total -= st.size;
      dropped++;
    }
    used = total;
    if (dropped > 0) await db.event('artwork', 'Deleted $dropped old artwork image${dropped == 1 ? '' : 's'}: the cache was full');
  }

  /// Forgets everything, on sign-out.
  Future<void> clear() async {
    await for (final f in dir.list()) {
      if (f is File) await f.delete();
    }
    used = 0;
  }
}

/// An image that comes from the [ArtCache], so it shows without a connection once it has been seen or kept.
class CachedArt extends ImageProvider<CachedArt> {
  const CachedArt(this.url, this.cache);
  final String url;
  final ArtCache cache;

  @override
  Future<CachedArt> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedArt key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: cache.bytes(url).then((b) async => decode(await ui.ImmutableBuffer.fromUint8List(b))), scale: 1);

  @override
  bool operator ==(Object other) => other is CachedArt && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
