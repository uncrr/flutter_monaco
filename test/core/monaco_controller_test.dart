import 'package:flutter_monaco/flutter_monaco.dart';
import 'package:flutter_monaco/src/core/monaco_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_platform_webview_controller.dart';

class _TestBundle {
  _TestBundle(this.controller, this.webview, this.bridge);

  final MonacoController controller;
  final FakePlatformWebViewController webview;
  final MonacoBridge bridge;
}

Future<_TestBundle> _createBundle({bool ready = true}) async {
  final webview = FakePlatformWebViewController();
  final bridge = MonacoBridge();
  final controller = await MonacoController.createForTesting(
    webViewController: webview,
    bridge: bridge,
    markReady: ready,
  );
  return _TestBundle(controller, webview, bridge);
}

void main() {
  group('MonacoController', () {
    group('initialization', () {
      test('createForTesting wires channel and marks ready', () async {
        final webview = FakePlatformWebViewController();
        final controller = await MonacoController.createForTesting(
          webViewController: webview,
          markReady: true,
        );
        expect(webview.hasChannel('flutterChannel'), true);
        expect(webview.initialized, true);
        expect(webview.jsEnabled, true);
        await expectLater(controller.onReady, completes);
      });

      test('createForTesting with custom channel name', () async {
        final webview = FakePlatformWebViewController();
        await MonacoController.createForTesting(
          webViewController: webview,
          markReady: true,
          channelName: 'customChannel',
        );
        expect(webview.hasChannel('customChannel'), true);
      });

      test('completeReadyForTesting is idempotent', () async {
        final bundle = await _createBundle(ready: false);
        bundle.controller.completeReadyForTesting();
        bundle.controller.completeReadyForTesting(); // Should not throw
        await expectLater(bundle.controller.onReady, completes);
      });

      test('isReady reflects ready state', () async {
        final bundle = await _createBundle(ready: false);
        expect(bundle.controller.isReady, false);

        bundle.controller.completeReadyForTesting();
        expect(bundle.controller.isReady, true);
      });
    });

    group('ready gating', () {
      test('ensureReady blocks operations until ready', () async {
        final bundle = await _createBundle(ready: false);
        final future = bundle.controller.updateOptions(
          const EditorOptions(fontSize: 18),
        );
        expect(bundle.webview.executed, isEmpty);
        bundle.controller.completeReadyForTesting();
        await future;
        expect(bundle.webview.executed.join('\n'), contains('updateOptions'));
      });

      test('execute helpers wait for ready on JS results', () async {
        final bundle = await _createBundle(ready: false);
        bundle.webview.resultResolver = (script) {
          if (script.contains('findMatches')) {
            return const <Map<String, dynamic>>[];
          }
          return null;
        };
        final future = bundle.controller.findMatches('x');
        expect(bundle.webview.executed, isEmpty);
        bundle.controller.completeReadyForTesting();
        await future;
        expect(
          bundle.webview.executed
              .any((script) => script.contains('findMatches')),
          true,
        );
      });

      test('multiple operations queue correctly', () async {
        final bundle = await _createBundle(ready: false);
        final futures = [
          bundle.controller.setTheme(MonacoTheme.vs),
          bundle.controller.setLanguage(MonacoLanguage.python),
          bundle.controller.focus(),
        ];

        expect(bundle.webview.executed, isEmpty);
        bundle.controller.completeReadyForTesting();
        await Future.wait(futures);

        final joined = bundle.webview.executed.join('\n');
        expect(joined.contains('setTheme'), true);
        expect(joined.contains('setLanguage'), true);
        expect(joined.contains('forceFocus'), true);
      });
    });

    group('content queuing', () {
      test('queued setValue overwrites older value', () async {
        final bundle = await _createBundle(ready: false);
        final first = bundle.controller.setValue('A');
        final second = bundle.controller.setValue('B');
        bundle.controller.completeReadyForTesting();
        await Future.wait([first, second]);

        final joined = bundle.webview.executed.join('\n');
        expect(joined.contains('setValue("A")'), false);
        expect(joined.contains('setValue("B")'), true);
      });

      test('queued setLanguage overwrites older value', () async {
        final bundle = await _createBundle(ready: false);
        final first = bundle.controller.setLanguage(MonacoLanguage.dart);
        final second = bundle.controller.setLanguage(MonacoLanguage.python);
        bundle.controller.completeReadyForTesting();
        await Future.wait([first, second]);

        final joined = bundle.webview.executed.join('\n');
        expect(joined.contains('"dart"'), false);
        expect(joined.contains('"python"'), true);
      });

      test('setValue after ready executes immediately', () async {
        final bundle = await _createBundle();
        await bundle.controller.setValue('immediate');
        expect(
          bundle.webview.executed.join('\n'),
          contains('setValue("immediate")'),
        );
      });
    });

    group('getValue', () {
      test('does not JSON-decode content', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getValue()', '{"a":1}');
        final value = await bundle.controller.getValue();
        expect(value, '{"a":1}');
      });

      test('returns defaultValue on error', () async {
        final bundle = await _createBundle();
        bundle.webview.throwOn((s) => s.contains('getValue'));
        final value =
            await bundle.controller.getValue(defaultValue: 'fallback');
        expect(value, 'fallback');
      });

      test('handles null result', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getValue()', null);
        final value = await bundle.controller.getValue(defaultValue: 'default');
        expect(value, 'default');
      });

      test('handles unicode content', () async {
        final bundle = await _createBundle();
        const unicode = 'مرحبا 👋🏽 é 🇪🇬';
        bundle.webview.enqueueResult('flutterMonaco.getValue()', unicode);
        final value = await bundle.controller.getValue();
        expect(value, unicode);
      });
    });

    group('selection operations', () {
      test('getSelection parses JSON', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult(
          'JSON.stringify(flutterMonaco.getSelection())',
          '{"startLineNumber":1,"startColumn":2,"endLineNumber":3,"endColumn":4}',
        );
        final selection = await bundle.controller.getSelection();
        expect(selection, isNotNull);
        expect(selection!.startLine, 1);
        expect(selection.startColumn, 2);
        expect(selection.endLine, 3);
        expect(selection.endColumn, 4);
      });

      test('getSelection returns null on error', () async {
        final bundle = await _createBundle();
        bundle.webview.throwOn((s) => s.contains('getSelection'));
        final selection = await bundle.controller.getSelection();
        expect(selection, isNull);
      });

      test('setSelection generates correct payload', () async {
        final bundle = await _createBundle();
        const range = Range(
          startLine: 1,
          startColumn: 1,
          endLine: 2,
          endColumn: 5,
        );
        await bundle.controller.setSelection(range);
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('setSelection'));
        expect(joined, contains('startLineNumber'));
      });
    });

    group('navigation', () {
      test('revealLine clamps to valid range', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 10);
        await bundle.controller.revealLine(0);
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 10);
        await bundle.controller.revealLine(999);

        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('revealLine(1, false)'));
        expect(joined, contains('revealLine(10, false)'));
      });

      test('revealLine is a no-op when lineCount is zero', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 0);
        await bundle.controller.revealLine(1);

        final joined = bundle.webview.executed.join('\n');
        expect(joined.contains('revealLine('), false);
      });

      test('revealLine with center option', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 10);
        await bundle.controller.revealLine(5, center: true);
        expect(
          bundle.webview.executed.join('\n'),
          contains('revealLine(5, true)'),
        );
      });

      test('revealRange generates correct payload', () async {
        final bundle = await _createBundle();
        const range = Range(
          startLine: 1,
          startColumn: 1,
          endLine: 5,
          endColumn: 10,
        );
        await bundle.controller.revealRange(range, center: true);
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('revealRange'));
        expect(joined, contains('true')); // center param
      });

      test('revealLines creates range and calls revealRange', () async {
        final bundle = await _createBundle();
        await bundle.controller.revealLines(2, 5);
        expect(bundle.webview.executed.join('\n'), contains('revealRange'));
      });

      test('revealPosition creates collapsed range', () async {
        final bundle = await _createBundle();
        const pos = Position(line: 3, column: 7);
        await bundle.controller.revealPosition(pos);
        expect(bundle.webview.executed.join('\n'), contains('revealRange'));
      });
    });

    group('actions', () {
      test('executeAction forwards args to JS', () async {
        final bundle = await _createBundle();
        await bundle.controller.executeAction('myAction', {'foo': 'bar'});

        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('executeAction'));
        expect(joined, contains('"foo":"bar"'));
      });
    });

    group('line operations', () {
      test('getLineCount returns valid count', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 42);
        final count = await bundle.controller.getLineCount();
        expect(count, 42);
      });

      test('getLineCount returns default on error', () async {
        final bundle = await _createBundle();
        bundle.webview.throwOn((s) => s.contains('getLineCount'));
        final count = await bundle.controller.getLineCount(defaultValue: 0);
        expect(count, 0);
      });

      test('getLineContent validates bounds - below', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 3);
        final value =
            await bundle.controller.getLineContent(0, defaultValue: 'x');
        expect(value, 'x');
        expect(
          bundle.webview.executed.any((s) => s.contains('getLineContent')),
          false,
        );
      });

      test('getLineContent validates bounds - above', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 3);
        final value =
            await bundle.controller.getLineContent(10, defaultValue: 'y');
        expect(value, 'y');
      });

      test('getLineContent returns content for valid line', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 5);
        bundle.webview
            .enqueueResult('flutterMonaco.getLineContent(3)', 'line 3');
        final value = await bundle.controller.getLineContent(3);
        expect(value, 'line 3');
      });

      test('getLinesContent returns values per line', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 3);
        bundle.webview.enqueueResult('flutterMonaco.getLineContent(1)', 'a');
        bundle.webview.enqueueResult('flutterMonaco.getLineContent(2)', 'b');
        bundle.webview.enqueueResult('flutterMonaco.getLineContent(3)', 'c');

        final lines = await bundle.controller.getLinesContent([1, 2, 3]);
        expect(lines, ['a', 'b', 'c']);
      });
    });

    group('edit operations', () {
      test('applyEdits skips empty list', () async {
        final bundle = await _createBundle();
        await bundle.controller.applyEdits([]);
        expect(
          bundle.webview.executed.any((s) => s.contains('applyEdits')),
          false,
        );
      });

      test('applyEdits generates expected payload', () async {
        final bundle = await _createBundle();
        final edits = [
          EditOperation.insert(
            position: const Position(line: 1, column: 1),
            text: 'hi',
            forceMoveMarkers: true,
          ),
          EditOperation.delete(
            range: const Range(
              startLine: 2,
              startColumn: 1,
              endLine: 2,
              endColumn: 5,
            ),
          ),
        ];
        await bundle.controller.applyEdits(edits);

        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('applyEdits'));
        expect(joined, contains('"text":"hi"'));
        expect(joined, contains('"forceMoveMarkers":true'));
      });

      test('insertText creates insert operation', () async {
        final bundle = await _createBundle();
        await bundle.controller.insertText(
          const Position(line: 1, column: 1),
          'inserted',
        );
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('applyEdits'));
        expect(joined, contains('"inserted"'));
      });

      test('deleteRange creates delete operation', () async {
        final bundle = await _createBundle();
        await bundle.controller.deleteRange(
          const Range(
            startLine: 1,
            startColumn: 1,
            endLine: 1,
            endColumn: 5,
          ),
        );
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('applyEdits'));
        expect(joined, contains('"text":""'));
      });

      test('replaceRange creates replace operation', () async {
        final bundle = await _createBundle();
        await bundle.controller.replaceRange(
          const Range(
            startLine: 1,
            startColumn: 1,
            endLine: 1,
            endColumn: 5,
          ),
          'replacement',
        );
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('applyEdits'));
        expect(joined, contains('"replacement"'));
      });

      test('deleteLine creates line range', () async {
        final bundle = await _createBundle();
        await bundle.controller.deleteLine(3);
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('applyEdits'));
        expect(joined, contains('"startLineNumber":3'));
      });
    });

    group('decorations', () {
      test('setDecorations tracks ids across calls', () async {
        final bundle = await _createBundle();
        var calls = 0;
        bundle.webview.resultResolver = (script) {
          if (!script.contains('deltaDecorations')) return null;
          calls++;
          return calls == 1 ? ['a', 'b'] : ['c'];
        };

        final first = await bundle.controller.setDecorations([
          DecorationOptions.inlineClass(
            range: const Range(
              startLine: 1,
              startColumn: 1,
              endLine: 1,
              endColumn: 2,
            ),
            className: 'x',
          ),
        ]);
        expect(first, ['a', 'b']);

        final second = await bundle.controller.setDecorations(const []);
        expect(second, ['c']);

        // Verify the old IDs were passed
        expect(bundle.webview.executed.join('\n'), contains('["a","b"]'));
      });

      test('addInlineDecorations creates correct options', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (script) {
          if (script.contains('deltaDecorations')) return ['d1'];
          return null;
        };

        final ids = await bundle.controller.addInlineDecorations(
          [const Range(startLine: 1, startColumn: 1, endLine: 1, endColumn: 5)],
          'highlight',
          hoverMessage: 'hover text',
        );
        expect(ids, ['d1']);
        expect(bundle.webview.executed.join('\n'), contains('inlineClassName'));
      });

      test('addLineDecorations creates whole line decorations', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (script) {
          if (script.contains('deltaDecorations')) return ['l1', 'l2'];
          return null;
        };

        final ids = await bundle.controller.addLineDecorations(
          [1, 2],
          'line-highlight',
        );
        expect(ids, ['l1', 'l2']);
        expect(bundle.webview.executed.join('\n'), contains('isWholeLine'));
      });

      test('clearDecorations passes empty array', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (script) {
          if (script.contains('deltaDecorations')) return <String>[];
          return null;
        };

        await bundle.controller.clearDecorations();
        expect(
            bundle.webview.executed.join('\n'), contains('deltaDecorations'));
      });
    });

    group('markers', () {
      test('setMarkers uses owner and severity values', () async {
        final bundle = await _createBundle();
        await bundle.controller.setMarkers(
          [
            MarkerData.error(
              range: const Range(
                startLine: 1,
                startColumn: 1,
                endLine: 1,
                endColumn: 10,
              ),
              message: 'Error message',
            ),
          ],
          owner: 'flutter-errors',
        );

        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('setModelMarkers'));
        expect(joined, contains('flutter-errors'));
        expect(joined, contains('"severity":8')); // Error severity
      });

      test('setErrorMarkers uses error owner', () async {
        final bundle = await _createBundle();
        await bundle.controller.setErrorMarkers([
          MarkerData.error(
            range: const Range(
              startLine: 1,
              startColumn: 1,
              endLine: 1,
              endColumn: 5,
            ),
            message: 'err',
          ),
        ]);
        expect(bundle.webview.executed.join('\n'), contains('flutter-errors'));
      });

      test('setWarningMarkers uses warning owner', () async {
        final bundle = await _createBundle();
        await bundle.controller.setWarningMarkers([
          MarkerData.warning(
            range: const Range(
              startLine: 1,
              startColumn: 1,
              endLine: 1,
              endColumn: 5,
            ),
            message: 'warn',
          ),
        ]);
        expect(
            bundle.webview.executed.join('\n'), contains('flutter-warnings'));
      });

      test('clearAllMarkers clears all known owners', () async {
        final bundle = await _createBundle();
        await bundle.controller.clearAllMarkers();

        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('"flutter"'));
        expect(joined, contains('"flutter-errors"'));
        expect(joined, contains('"flutter-warnings"'));
      });
    });

    group('find and replace', () {
      test('findMatches returns FindMatch list', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (script) {
          if (!script.contains('findMatches')) return null;
          return [
            {
              'match': 'abc',
              'range': {
                'startLineNumber': 1,
                'startColumn': 1,
                'endLineNumber': 1,
                'endColumn': 4,
              },
            },
            {
              'match': 'abc',
              'range': {
                'startLineNumber': 2,
                'startColumn': 5,
                'endLineNumber': 2,
                'endColumn': 8,
              },
            },
          ];
        };

        final matches = await bundle.controller.findMatches('abc');
        expect(matches.length, 2);
        expect(matches[0].match, 'abc');
        expect(matches[0].range.startLine, 1);
        expect(matches[1].range.startLine, 2);
      });

      test('findMatches with options', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (_) => <Map<String, dynamic>>[];

        await bundle.controller.findMatches(
          'test',
          options: FindOptions.caseSensitive(wholeWord: true),
          limit: 50,
        );

        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('findMatches'));
        expect(joined, contains('"matchCase":true'));
        expect(joined, contains('"wholeWord":true'));
        expect(joined, contains('50'));
      });

      test('findMatches returns empty list on error', () async {
        final bundle = await _createBundle();
        bundle.webview.throwOn((s) => s.contains('findMatches'));
        final matches = await bundle.controller.findMatches('test');
        expect(matches, isEmpty);
      });

      test('replaceMatches returns count', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult(
          'flutterMonaco.replaceMatches("old", "new", {})',
          5,
        );
        bundle.webview.resultResolver = (script) {
          if (script.contains('replaceMatches')) return 5;
          return null;
        };

        final count = await bundle.controller.replaceMatches('old', 'new');
        expect(count, 5);
      });

      test('replaceMatches returns default on error', () async {
        final bundle = await _createBundle();
        bundle.webview.throwOn((s) => s.contains('replaceMatches'));
        final count = await bundle.controller.replaceMatches(
          'a',
          'b',
          defaultCount: 0,
        );
        expect(count, 0);
      });
    });

    group('view state', () {
      test('saveViewState returns state map', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult(
          'JSON.stringify(flutterMonaco.saveViewState())',
          '{"cursorState":[{"inSelectionMode":false}],"scrollTop":100}',
        );

        final state = await bundle.controller.saveViewState();
        expect(state.isNotEmpty, true);
        expect(state['scrollTop'], 100);
      });

      test('saveViewState returns empty map on error', () async {
        final bundle = await _createBundle();
        bundle.webview.throwOn((s) => s.contains('saveViewState'));
        final state = await bundle.controller.saveViewState();
        expect(state, isEmpty);
      });

      test('restoreViewState skips empty state', () async {
        final bundle = await _createBundle();
        final before = bundle.webview.executed.length;
        await bundle.controller.restoreViewState({});
        expect(bundle.webview.executed.length, before);
      });

      test('restoreViewState passes state to JS', () async {
        final bundle = await _createBundle();
        await bundle.controller.restoreViewState({'scrollTop': 50});
        expect(
          bundle.webview.executed.join('\n'),
          contains('restoreViewState'),
        );
      });
    });

    group('multi-model', () {
      test('createModel returns URI', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (script) {
          if (script.contains('createModel')) return 'file:///model1';
          return null;
        };

        final uri = await bundle.controller.createModel('content');
        expect(uri.toString(), 'file:///model1');
      });

      test('createModel uses defaultUri on null result', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (_) => null;

        final fallback = Uri.parse('file:///fallback');
        final uri = await bundle.controller.createModel(
          'content',
          defaultUri: fallback,
        );
        expect(uri, fallback);
      });

      test('setModel calls JS with URI', () async {
        final bundle = await _createBundle();
        await bundle.controller.setModel(Uri.parse('file:///test'));
        expect(bundle.webview.executed.join('\n'), contains('setModel'));
      });

      test('disposeModel calls JS with URI', () async {
        final bundle = await _createBundle();
        await bundle.controller.disposeModel(Uri.parse('file:///test'));
        expect(bundle.webview.executed.join('\n'), contains('disposeModel'));
      });

      test('listModels returns URI list', () async {
        final bundle = await _createBundle();
        bundle.webview.resultResolver = (script) {
          if (script.contains('listModels')) {
            return ['file:///m1', 'file:///m2', 'invalid'];
          }
          return null;
        };

        final list = await bundle.controller.listModels();
        expect(list.length, 3);
        expect(list[0].toString(), 'file:///m1');
      });
    });

    group('dirty tracking and cursor', () {
      test('hasUnsavedChanges returns boolean', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult('flutterMonaco.hasUnsavedChanges()', true);
        final dirty = await bundle.controller.hasUnsavedChanges();
        expect(dirty, true);
      });

      test('markSaved calls JS', () async {
        final bundle = await _createBundle();
        await bundle.controller.markSaved();
        expect(bundle.webview.executed.join('\n'), contains('markSaved'));
      });

      test('getCursorPosition parses JSON', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult(
          'JSON.stringify(flutterMonaco.getCursorPosition())',
          '{"lineNumber":5,"column":10}',
        );

        final pos = await bundle.controller.getCursorPosition();
        expect(pos, isNotNull);
        expect(pos!.line, 5);
        expect(pos.column, 10);
      });

      test('setCursorPosition calls JS with coordinates', () async {
        final bundle = await _createBundle();
        await bundle.controller.setCursorPosition(
          const Position(line: 3, column: 7),
        );
        expect(
          bundle.webview.executed.join('\n'),
          contains('setCursorPosition(3, 7)'),
        );
      });

      test('setCursorPositionZeroBased converts to 1-based', () async {
        final bundle = await _createBundle();
        await bundle.controller.setCursorPositionZeroBased(0, 0);
        expect(
          bundle.webview.executed.join('\n'),
          contains('setCursorPosition(1, 1)'),
        );
      });

      test('getWordAtPosition returns word', () async {
        final bundle = await _createBundle();
        bundle.webview.enqueueResult(
          'flutterMonaco.getWordAtPosition(1, 1)',
          'hello',
        );
        final word = await bundle.controller.getWordAtPosition(
          const Position(line: 1, column: 1),
        );
        expect(word, 'hello');
      });
    });

    group('action helpers', () {
      test('format calls formatDocument action', () async {
        final bundle = await _createBundle();
        await bundle.controller.format();
        expect(
          bundle.webview.executed.join('\n'),
          contains('formatDocument'),
        );
      });

      test('find calls find action', () async {
        final bundle = await _createBundle();
        await bundle.controller.find();
        expect(bundle.webview.executed.join('\n'), contains('actions.find'));
      });

      test('replace calls startFindReplaceAction', () async {
        final bundle = await _createBundle();
        await bundle.controller.replace();
        expect(
          bundle.webview.executed.join('\n'),
          contains('startFindReplaceAction'),
        );
      });

      test('toggleWordWrap calls action', () async {
        final bundle = await _createBundle();
        await bundle.controller.toggleWordWrap();
        expect(
          bundle.webview.executed.join('\n'),
          contains('toggleWordWrap'),
        );
      });

      test('undo/redo call correct actions', () async {
        final bundle = await _createBundle();
        await bundle.controller.undo();
        await bundle.controller.redo();
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('"undo"'));
        expect(joined, contains('"redo"'));
      });

      test('clipboard actions call correct IDs', () async {
        final bundle = await _createBundle();
        await bundle.controller.cut();
        await bundle.controller.copy();
        await bundle.controller.paste();
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('clipboardCutAction'));
        expect(joined, contains('clipboardCopyAction'));
        expect(joined, contains('clipboardPasteAction'));
      });
    });

    group('focus and scroll', () {
      test('focus calls forceFocus', () async {
        final bundle = await _createBundle();
        await bundle.controller.focus();
        expect(bundle.webview.executed.join('\n'), contains('forceFocus'));
      });

      test('ensureEditorFocus retries multiple times', () async {
        final bundle = await _createBundle();
        await bundle.controller.ensureEditorFocus(
          attempts: 3,
          interval: Duration.zero,
        );
        final count = bundle.webview.executed
            .where((s) => s.contains('forceFocus'))
            .length;
        expect(count, 3);
      });

      test('layout calls layout', () async {
        final bundle = await _createBundle();
        await bundle.controller.layout();
        expect(bundle.webview.executed.join('\n'), contains('layout'));
      });

      test('scrollToTop sets scroll position', () async {
        final bundle = await _createBundle();
        await bundle.controller.scrollToTop();
        final joined = bundle.webview.executed.join('\n');
        expect(joined, contains('setScrollPosition'));
        expect(joined, contains('scrollTop: 0'));
      });

      test('scrollToBottom reveals last line', () async {
        final bundle = await _createBundle();
        await bundle.controller.scrollToBottom();
        expect(
          bundle.webview.executed.join('\n'),
          contains('revealLineInCenterIfOutsideViewport'),
        );
      });
    });

    group('batch operations', () {
      test('executeBatch runs operations sequentially', () async {
        final bundle = await _createBundle();
        final order = <int>[];

        await bundle.controller.executeBatch([
          () async {
            order.add(1);
            await bundle.controller.focus();
          },
          () async {
            order.add(2);
            await bundle.controller.layout();
          },
        ]);

        expect(order, [1, 2]);
      });

      test('getEditorState aggregates state', () async {
        final bundle = await _createBundle();

        // Set up responses
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'content');
        bundle.webview.enqueueResult(
          'JSON.stringify(flutterMonaco.getSelection())',
          '{"startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":5}',
        );
        bundle.webview.enqueueResult(
          'JSON.stringify(flutterMonaco.getCursorPosition())',
          '{"lineNumber":1,"column":3}',
        );
        bundle.webview.enqueueResult('flutterMonaco.getLineCount()', 5);
        bundle.webview
            .enqueueResult('flutterMonaco.hasUnsavedChanges()', false);

        final state = await bundle.controller.getEditorState();

        expect(state.content, 'content');
        expect(state.selection?.endColumn, 5);
        expect(state.cursorPosition?.column, 3);
        expect(state.lineCount, 5);
        expect(state.hasUnsavedChanges, false);
      });
    });

    group('event streams', () {
      test('onContentChanged delivers flush flag', () async {
        final bundle = await _createBundle();
        final events = <bool>[];
        final sub = bundle.controller.onContentChanged.listen(events.add);

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":false}',
        );

        await pumpEventQueue();
        expect(events, [true, false]);
        await sub.cancel();
      });

      test('onSelectionChanged delivers Range', () async {
        final bundle = await _createBundle();
        final events = <Range?>[];
        final sub = bundle.controller.onSelectionChanged.listen(events.add);

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"selectionChanged","selection":{"startLineNumber":1,"startColumn":1,"endLineNumber":2,"endColumn":3}}',
        );

        await pumpEventQueue();
        expect(events.length, 1);
        expect(events.first?.endLine, 2);
        await sub.cancel();
      });

      test('onFocus/onBlur deliver events', () async {
        final bundle = await _createBundle();
        var focusCount = 0;
        var blurCount = 0;
        final subs = [
          bundle.controller.onFocus.listen((_) => focusCount++),
          bundle.controller.onBlur.listen((_) => blurCount++),
        ];

        bundle.webview.emitToChannel('flutterChannel', '{"event":"focus"}');
        bundle.webview.emitToChannel('flutterChannel', '{"event":"blur"}');

        await pumpEventQueue();
        expect(focusCount, 1);
        expect(blurCount, 1);

        for (final sub in subs) {
          await sub.cancel();
        }
      });
    });

    group('getStatistics', () {
      test('returns current liveStats value', () async {
        final bundle = await _createBundle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"stats","lineCount":10,"charCount":50}',
        );
        await pumpEventQueue();

        final stats = bundle.controller.getStatistics();
        expect(stats.lineCount.value, 10);
        expect(stats.charCount.value, 50);
      });
    });
  });
}
