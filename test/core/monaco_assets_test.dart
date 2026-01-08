import 'dart:io';

import 'package:flutter_monaco/src/core/monaco_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this.baseDir);

  final Directory baseDir;

  @override
  Future<String?> getApplicationSupportPath() async => baseDir.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MonacoAssets', () {
    late PathProviderPlatform originalPlatform;
    late Directory tempDir;

    setUp(() async {
      originalPlatform = PathProviderPlatform.instance;
      tempDir = await Directory.systemTemp.createTemp('monaco_assets_test_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir);
      await MonacoAssets.clearCache();
    });

    tearDown(() async {
      await MonacoAssets.clearCache();
      PathProviderPlatform.instance = originalPlatform;
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('ensureReady extracts assets and writes sentinel', () async {
      await MonacoAssets.ensureReady();
      final info = await MonacoAssets.assetInfo();
      expect(info['exists'], true);
      final targetDir = info['path'] as String;
      final sentinel = File(p.join(targetDir, '.monaco_complete'));
      expect(sentinel.existsSync(), true);
      expect(sentinel.readAsStringSync().trim(), MonacoAssets.monacoVersion);
      expect(File(p.join(targetDir, 'index.html')).existsSync(), true);
    });

    test('ensureReady is re-entrant', () async {
      await Future.wait(List.generate(5, (_) => MonacoAssets.ensureReady()));
      final info = await MonacoAssets.assetInfo();
      expect(info['exists'], true);
      final targetDir = info['path'] as String;
      expect(Directory(targetDir).existsSync(), true);
    });

    test('version mismatch forces re-extract', () async {
      final info = await MonacoAssets.assetInfo();
      final targetDir = info['path'] as String;
      final loader = File(p.join(targetDir, 'min', 'vs', 'loader.js'));
      await loader.parent.create(recursive: true);
      await loader.writeAsString('');
      final sentinel = File(p.join(targetDir, '.monaco_complete'));
      await sentinel.writeAsString('0.0.0');
      await MonacoAssets.ensureReady();
      expect(sentinel.readAsStringSync().trim(), MonacoAssets.monacoVersion);
    });

    test('indexHtmlPath caches by customCss/allowCdnFonts', () async {
      final pathA = await MonacoAssets.indexHtmlPath(
        customCss: null,
        allowCdnFonts: false,
      );
      final pathA2 = await MonacoAssets.indexHtmlPath(
        customCss: null,
        allowCdnFonts: false,
      );
      final pathB = await MonacoAssets.indexHtmlPath(
        customCss: 'body{background:red;}',
        allowCdnFonts: false,
      );
      final pathC = await MonacoAssets.indexHtmlPath(
        customCss: null,
        allowCdnFonts: true,
      );
      expect(pathA, pathA2);
      expect(pathB == pathA, false);
      expect(pathC == pathA, false);
      expect(File(pathA).existsSync(), true);
      expect(File(pathB).existsSync(), true);
      expect(File(pathC).existsSync(), true);
    });

    test('CSP toggles CDN fonts correctly', () async {
      final pathNoCdn = await MonacoAssets.indexHtmlPath(
        allowCdnFonts: false,
      );
      final pathCdn = await MonacoAssets.indexHtmlPath(
        allowCdnFonts: true,
      );
      final noCdn = await File(pathNoCdn).readAsString();
      final cdn = await File(pathCdn).readAsString();
      expect(noCdn.contains('style-src'), true);
      expect(noCdn.contains("style-src 'self' 'unsafe-inline' https:"), false);
      expect(cdn.contains("style-src 'self' 'unsafe-inline' https:"), true);
    });

    test('clearCache removes assets and resets caches', () async {
      await MonacoAssets.ensureReady();
      final infoBefore = await MonacoAssets.assetInfo();
      expect(infoBefore['exists'], true);
      await MonacoAssets.clearCache();
      final infoAfter = await MonacoAssets.assetInfo();
      expect(infoAfter['exists'], false);
    });
  });
}
