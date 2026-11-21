// The server's JSON API: the device token travels as a bearer token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

class ApiError implements Exception {
  ApiError(this.message, [this.status = 0]);
  final String message;
  final int status;
  bool get signedOut => status == 401;
  @override
  String toString() => message;
}

/// The request never reached the server, or its answer never came back.
class Unreachable implements Exception {
  Unreachable(this.cause);
  final Object cause;
  @override
  String toString() => "Can't reach the server ($cause)";
}

enum Reach { unknown, online, offline }

/// Whether the server answers. Every request reports here, so the whole app shares one state.
class Link extends ChangeNotifier {
  Reach reach = Reach.unknown;
  String error = '';

  /// Whether the device itself has internet, checked each time the server can't be reached.
  bool network = true;

  /// The server can't be reached, for whatever reason.
  bool get offline => reach == Reach.offline;

  /// The device has no internet at all, so podcasts' own enclosures won't stream either.
  bool get noNetwork => offline && !network;

  void _set(Reach r, String why, {required bool network}) {
    if (r == reach && why == error && network == this.network) return;
    reach = r;
    error = why;
    this.network = network;
    notifyListeners();
  }

  static Future<bool> _hasNetwork() async {
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        return await const MethodChannel('rpodcasts/device').invokeMethod<bool>('online') ?? true;
      } on Object {
        return true;
      }
    }
    try {
      final all = await NetworkInterface.list();
      return all.any((i) => i.addresses.any((a) => !a.isLoopback && !a.isLinkLocal));
    } on Object {
      return true;
    }
  }
}

class Api {
  Api({required this.base, required this.token});
  final String base;
  final String token;
  final Link link = Link();
  HttpClient _io = _fresh();
  late http.Client _http = IOClient(_io);

  // A short connect timeout fails fast offline; a short idle timeout drops sockets a network change killed.
  static HttpClient _fresh() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 5)
    ..idleTimeout = const Duration(seconds: 5);

  Uri uri(String path, [Map<String, String>? q]) => Uri.parse('$base/api/v1$path').replace(queryParameters: q);

  /// Absolute address for a path the server returns, such as a signed stream link.
  String absolute(String path) => path.startsWith('http') ? path : '$base$path';

  static Future<(String token, Map<String, dynamic> device)> signIn(String base, String password, String device) async {
    final r = await http
        .post(Uri.parse('$base/api/v1/signin'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({'password': password, 'device': device}))
        .timeout(const Duration(seconds: 30));
    final body = _decode(r);
    return (body['token'] as String, (body['device'] as Map).cast<String, dynamic>());
  }

  static dynamic _decode(http.Response r) {
    dynamic body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw ApiError('The server answered ${r.statusCode} without JSON. Is the address right?', r.statusCode);
    }
    if (r.statusCode >= 400) throw ApiError(body is Map ? '${body['error']}' : 'error ${r.statusCode}', r.statusCode);
    return body;
  }

  Map<String, String> get _headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json', 'User-Agent': 'podcasts-app'};

  // Pooled sockets may be dead after a network change, so the next request starts on new ones.
  void _reconnect() {
    final old = _io;
    _io = _fresh();
    _http = IOClient(_io);
    old.close();
  }

  static bool _lost(Object e) => e is IOException || e is http.ClientException || e is TimeoutException;

  // Only a quick failure is a dead pooled socket worth one more try; a slow one means no network.
  Future<dynamic> _send(Future<http.Response> Function(http.Client c) call, {required bool idempotent}) async {
    for (var tries = idempotent ? 2 : 1; ; tries--) {
      final began = DateTime.now();
      try {
        final r = await call(_http).timeout(const Duration(seconds: 30));
        link._set(Reach.online, '', network: true);
        return _decode(r);
      } on Object catch (e) {
        if (!_lost(e)) rethrow;
        _reconnect();
        if (tries == 1 || DateTime.now().difference(began) > const Duration(seconds: 2)) {
          link._set(Reach.offline, '$e', network: await Link._hasNetwork());
          throw Unreachable(e);
        }
      }
    }
  }

  Future<dynamic> get(String path, [Map<String, String>? q]) => _send((c) => c.get(uri(path, q), headers: _headers), idempotent: true);

  Future<dynamic> post(String path, [Object? body]) => _send((c) => c.post(uri(path), headers: _headers, body: jsonEncode(body ?? {})), idempotent: false);

  Future<dynamic> delete(String path) => _send((c) => c.delete(uri(path), headers: _headers), idempotent: false);
}
