import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'app.dart';
import 'data/db.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PathProviderPlatform.instance = _Paths(PathProviderPlatform.instance);
  MediaKit.ensureInitialized();
  final db = await LocalDb.open();
  runApp(PodcastsApp(db: db));
}

// Some systems have no documents folder (Linux without xdg-user-dir); fall back to app support.
class _Paths extends PathProviderPlatform {
  _Paths(this.os);
  final PathProviderPlatform os;

  @override
  Future<String?> getApplicationDocumentsPath() async => await os.getApplicationDocumentsPath() ?? p.join((await os.getApplicationSupportPath())!, 'documents');
  @override
  Future<String?> getApplicationSupportPath() => os.getApplicationSupportPath();
  @override
  Future<String?> getApplicationCachePath() => os.getApplicationCachePath();
  @override
  Future<String?> getTemporaryPath() => os.getTemporaryPath();
  @override
  Future<String?> getLibraryPath() => os.getLibraryPath();
  @override
  Future<String?> getExternalStoragePath() => os.getExternalStoragePath();
  @override
  Future<List<String>?> getExternalCachePaths() => os.getExternalCachePaths();
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) => os.getExternalStoragePaths(type: type);
  @override
  Future<String?> getDownloadsPath() => os.getDownloadsPath();
}
