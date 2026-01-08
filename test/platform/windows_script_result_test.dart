import 'dart:convert';

import 'package:flutter_monaco/src/platform/platform_webview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseWindowsScriptResult', () {
    test('decodes JSON string literals without parsing objects', () {
      final input = jsonEncode('{"a":1}');
      final result = parseWindowsScriptResult(input);
      expect(result, '{"a":1}');
    });

    test('does not decode JSON object strings', () {
      const input = '{"a":1}';
      final result = parseWindowsScriptResult(input);
      expect(result, input);
      expect(result, isA<String>());
    });

    test('does not decode JSON array strings', () {
      const input = '["a","b"]';
      final result = parseWindowsScriptResult(input);
      expect(result, input);
    });

    test('converts null token to null', () {
      final result = parseWindowsScriptResult('null');
      expect(result, isNull);
    });
  });
}
