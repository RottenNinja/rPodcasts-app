// The server's JSON API: the device token travels as a bearer token.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiError implements Exception {
  ApiError(this.message, [this.status = 0]);
  final String message;
  final int status;
  bool get signedOut => status == 401;
  @override
  String toString() => message;
}

class Api {
  Api({required this.base, required this.token});
  final String base;
  final String token;
  final http.Client _http = http.Client();

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

  Future<dynamic> get(String path, [Map<String, String>? q]) async =>
      _decode(await _http.get(uri(path, q), headers: _headers).timeout(const Duration(seconds: 60)));

  Future<dynamic> post(String path, [Object? body]) async =>
      _decode(await _http.post(uri(path), headers: _headers, body: jsonEncode(body ?? {})).timeout(const Duration(seconds: 60)));

  Future<dynamic> delete(String path) async => _decode(await _http.delete(uri(path), headers: _headers).timeout(const Duration(seconds: 60)));
}
