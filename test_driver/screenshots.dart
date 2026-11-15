// Saves each screenshot integration_test/screenshots.dart takes into SCREENSHOT_DIR.
// With SCREENSHOT_UDID or SCREENSHOT_WINDOW it serves 127.0.0.1:8749/shot?name=…, which captures that simulator, iOS status bar included, or that X11 window.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final dir = Directory(Platform.environment['SCREENSHOT_DIR'] ?? 'build/screenshots')..createSync(recursive: true);
  final udid = Platform.environment['SCREENSHOT_UDID'] ?? '';
  final window = Platform.environment['SCREENSHOT_WINDOW'] ?? '';
  HttpServer? capture;
  if (udid.isNotEmpty || window.isNotEmpty) {
    capture = await HttpServer.bind(InternetAddress.loopbackIPv4, 8749);
    capture.listen((req) async {
      final name = (req.uri.queryParameters['name'] ?? 'shot').replaceAll(RegExp('[^a-z0-9-]'), '');
      final file = '${dir.path}/$name.png';
      final r = udid.isNotEmpty
          ? await Process.run('xcrun', ['simctl', 'io', udid, 'screenshot', '--type=png', file])
          : await Process.run('import', ['-window', window, file]);
      req.response.statusCode = r.exitCode == 0 ? 200 : 500;
      req.response.write(r.stderr);
      await req.response.close();
    });
  }
  await integrationDriver(
    onScreenshot: (name, bytes, [args]) async {
      await File('${dir.path}/$name.png').writeAsBytes(bytes);
      return true;
    },
  );
  await capture?.close();
}
