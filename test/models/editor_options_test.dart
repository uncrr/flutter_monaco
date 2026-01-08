import 'package:flutter_monaco/flutter_monaco.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EditorOptions', () {
    test('fromJson maps values and defaults', () {
      final options = EditorOptions.fromJson({
        'language': 'python',
        'theme': 'vs',
        'fontSize': 16,
        'lineNumbers': false,
        'tabSize': 2,
      });
      expect(options.language, MonacoLanguage.python);
      expect(options.theme, MonacoTheme.vs);
      expect(options.fontSize, 16);
      expect(options.lineNumbers, false);
      expect(options.tabSize, 2);
      expect(options.wordWrap, true);
    });

    test('toMonacoOptions maps expected keys', () {
      const options = EditorOptions(
        wordWrap: false,
        minimap: true,
        lineNumbers: false,
        cursorBlinking: CursorBlinking.expand,
        cursorStyle: CursorStyle.block,
        renderWhitespace: RenderWhitespace.all,
        parameterHints: false,
        hover: false,
        contextMenu: false,
        bracketPairColorization: false,
      );
      final map = options.toMonacoOptions();
      expect(map['wordWrap'], 'off');
      expect(map['minimap'], {'enabled': true});
      expect(map['lineNumbers'], 'off');
      expect(map['cursorBlinking'], 'expand');
      expect(map['cursorStyle'], 'block');
      expect(map['renderWhitespace'], 'all');
      expect(map['parameterHints'], {'enabled': false});
      expect(map['hover'], {'enabled': false});
      expect(map['contextmenu'], false);
      expect(map['bracketPairColorization'], {'enabled': false});
      expect(map.containsKey('padding'), false);
    });
  });
}
