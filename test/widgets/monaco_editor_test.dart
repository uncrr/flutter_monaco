import 'package:flutter/material.dart';
import 'package:flutter_monaco/flutter_monaco.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_platform_webview_controller.dart';

class _TestBundle {
  _TestBundle(this.controller, this.webview);

  final MonacoController controller;
  final FakePlatformWebViewController webview;
}

Future<_TestBundle> _createBundle({bool ready = true}) async {
  final webview = FakePlatformWebViewController(
    widget: const SizedBox(key: Key('webview')),
  );
  final controller = await MonacoController.createForTesting(
    webViewController: webview,
    markReady: ready,
  );
  return _TestBundle(controller, webview);
}

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MonacoEditor widget', () {
    group('initialization states', () {
      testWidgets('shows loading while controller not ready', (tester) async {
        final bundle = await _createBundle(ready: false);
        await tester.pumpWidget(
          _wrap(MonacoEditor(controller: bundle.controller)),
        );
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });

      testWidgets('custom loadingBuilder is used', (tester) async {
        final bundle = await _createBundle(ready: false);
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          loadingBuilder: (context) => const Text('Custom Loading'),
        )));
        expect(find.text('Custom Loading'), findsOneWidget);
      });

      testWidgets('transitions to ready state and fires onReady',
          (tester) async {
        final bundle = await _createBundle(ready: false);
        MonacoController? receivedController;
        var readyCount = 0;

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          onReady: (c) {
            receivedController = c;
            readyCount++;
          },
        )));

        bundle.controller.completeReadyForTesting();
        await tester.pump();

        expect(find.byKey(const Key('webview')), findsOneWidget);
        expect(readyCount, 1);
        expect(receivedController, bundle.controller);
      });

      testWidgets('error state shows error and retry only when owned',
          (tester) async {
        final bundle = await _createBundle();
        bundle.webview.throwOnContains('setValue');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          initialValue: 'trigger error',
        )));
        await tester.pump();

        expect(find.text('Failed to Initialize Editor'), findsOneWidget);
        expect(find.text('Retry'), findsNothing); // Not owned
      });

      testWidgets('owned controller disposed when bootstrap fails',
          (tester) async {
        FakePlatformWebViewController? failingWebview;

        Future<MonacoController> factory() async {
          failingWebview = FakePlatformWebViewController(
            widget: const SizedBox(key: Key('webview')),
          );
          failingWebview!.throwOnContains('setValue');
          return MonacoController.createForTesting(
            webViewController: failingWebview!,
            markReady: true,
          );
        }

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
          initialValue: 'boom',
        )));
        await tester.pump();

        expect(find.text('Failed to Initialize Editor'), findsOneWidget);
        expect(failingWebview, isNotNull);
        expect(failingWebview!.disposed, true);
      });

      testWidgets('error state shows retry when widget owns controller',
          (tester) async {
        var factoryCalls = 0;
        Future<MonacoController> factory() async {
          factoryCalls++;
          if (factoryCalls == 1) {
            throw StateError('Initialization failed');
          }
          final webview = FakePlatformWebViewController(
            widget: const SizedBox(key: Key('webview')),
          );
          return MonacoController.createForTesting(
            webViewController: webview,
            markReady: true,
          );
        }

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
        )));
        await tester.pump();

        expect(find.text('Failed to Initialize Editor'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);

        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();

        expect(find.byKey(const Key('webview')), findsOneWidget);
        expect(factoryCalls, 2);
      });

      testWidgets('custom errorBuilder is used', (tester) async {
        final bundle = await _createBundle();
        bundle.webview.throwOnContains('setValue');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          initialValue: 'trigger',
          errorBuilder: (context, error, st) => Text('Custom Error: $error'),
        )));
        await tester.pump();

        expect(find.textContaining('Custom Error'), findsOneWidget);
      });
    });

    group('initial values', () {
      testWidgets('initialValue applied once', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          initialValue: 'initial content',
        )));
        await tester.pump();

        bundle.webview.assertExecuted('setValue("initial content")');

        // Update widget with different initialValue
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          initialValue: 'new content',
        )));
        await tester.pump();

        // Should NOT set the new value
        bundle.webview.assertNotExecuted('setValue("new content")');
      });

      testWidgets('initialSelection applied after initialValue',
          (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          initialValue: 'content',
          initialSelection: const Range(
            startLine: 1,
            startColumn: 1,
            endLine: 1,
            endColumn: 5,
          ),
        )));
        await tester.pump();

        final scripts = bundle.webview.executed;
        final valueIndex = scripts.indexWhere((s) => s.contains('setValue'));
        final selIndex = scripts.indexWhere((s) => s.contains('setSelection'));

        expect(valueIndex, greaterThanOrEqualTo(0));
        expect(selIndex, greaterThan(valueIndex));
      });
    });

    group('options updates', () {
      testWidgets('options change triggers updateOptions/theme/language',
          (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          options: const EditorOptions(
            language: MonacoLanguage.dart,
            theme: MonacoTheme.vsDark,
          ),
        )));
        await tester.pumpAndSettle();

        bundle.webview.clearExecuted();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          options: const EditorOptions(
            language: MonacoLanguage.python,
            theme: MonacoTheme.vs,
            fontSize: 16,
          ),
        )));
        await tester.pumpAndSettle();

        bundle.webview.assertExecuted('updateOptions');
        bundle.webview.assertExecuted('setTheme');
        bundle.webview.assertExecuted('setLanguage');
      });

      testWidgets('same options do not trigger updates', (tester) async {
        final bundle = await _createBundle();
        const options = EditorOptions(
          language: MonacoLanguage.dart,
          theme: MonacoTheme.vsDark,
        );

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          options: options,
        )));
        await tester.pumpAndSettle();

        bundle.webview.clearExecuted();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          options: options, // Same options
        )));
        await tester.pumpAndSettle();

        bundle.webview.assertNotExecuted('updateOptions');
      });
    });

    group('autofocus', () {
      testWidgets('autofocus triggers ensureEditorFocus', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          autofocus: true,
        )));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();

        bundle.webview.assertExecuted('forceFocus');
      });

      testWidgets('autofocus false does not trigger focus', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          autofocus: false,
        )));
        await tester.pumpAndSettle();

        bundle.webview.assertNotExecuted('forceFocus');
      });
    });

    group('content change callbacks', () {
      testWidgets('onContentChanged debounces non-flush events',
          (tester) async {
        final bundle = await _createBundle();
        final calls = <String>[];
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'A');
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'B');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          contentDebounce: const Duration(milliseconds: 30),
          onContentChanged: calls.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":false}',
        );
        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":false}',
        );

        // Before debounce completes
        await tester.pump(const Duration(milliseconds: 10));
        expect(calls.length, 0);

        // After debounce
        await tester.pump(const Duration(milliseconds: 40));
        expect(calls.length, 1);
      });

      testWidgets('flush event bypasses debounce', (tester) async {
        final bundle = await _createBundle();
        final calls = <String>[];
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'flushed');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          contentDebounce: const Duration(milliseconds: 200),
          onContentChanged: calls.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();

        expect(calls.length, 1);
        expect(calls.first, 'flushed');
      });

      testWidgets('fullTextOnFlushOnly blocks non-flush updates',
          (tester) async {
        final bundle = await _createBundle();
        final calls = <String>[];
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'content');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          fullTextOnFlushOnly: true,
          onContentChanged: calls.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":false}',
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(calls.length, 0);

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();
        expect(calls.length, 1);
      });

      testWidgets('onRawContentChanged receives flush flag', (tester) async {
        final bundle = await _createBundle();
        final flags = <bool>[];

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          onRawContentChanged: flags.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":false}',
        );
        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();

        expect(flags, [false, true]);
      });

      testWidgets('rewires listener when callback changes', (tester) async {
        final bundle = await _createBundle();
        final calls1 = <String>[];
        final calls2 = <String>[];
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'v1');
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'v2');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          contentDebounce: Duration.zero,
          onContentChanged: calls1.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();
        expect(calls1.length, 1);

        // Change callback
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          contentDebounce: Duration.zero,
          onContentChanged: calls2.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();

        expect(calls1.length, 1); // Original not called again
        expect(calls2.length, 1); // New callback called
      });
    });

    group('other callbacks', () {
      testWidgets('selection/focus/blur callbacks wired', (tester) async {
        final bundle = await _createBundle();
        var selectionCount = 0;
        var focusCount = 0;
        var blurCount = 0;

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          onSelectionChanged: (_) => selectionCount++,
          onFocus: () => focusCount++,
          onBlur: () => blurCount++,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"selectionChanged","selection":{"startLineNumber":1,"startColumn":1,"endLineNumber":1,"endColumn":2}}',
        );
        bundle.webview.emitToChannel('flutterChannel', '{"event":"focus"}');
        bundle.webview.emitToChannel('flutterChannel', '{"event":"blur"}');
        await tester.pump();

        expect(selectionCount, 1);
        expect(focusCount, 1);
        expect(blurCount, 1);
      });

      testWidgets('onLiveStats receives updates', (tester) async {
        final bundle = await _createBundle();
        final stats = <LiveStats>[];

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          onLiveStats: stats.add,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"stats","lineCount":10,"charCount":50}',
        );
        await tester.pump();

        expect(stats.length, 1);
        expect(stats.first.lineCount.value, 10);
      });
    });

    group('status bar', () {
      testWidgets('status bar renders stats', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          showStatusBar: true,
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"stats","lineCount":25,"charCount":100,"cursorLine":5,"cursorColumn":10}',
        );
        await tester.pump();

        expect(find.text('Ln 5:10'), findsOneWidget);
        expect(find.text('Ch 100'), findsOneWidget);
      });

      testWidgets('custom statusBarBuilder used', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          statusBarBuilder: (context, stats) => Text(
            'Lines: ${stats.lineCount.value}',
          ),
        )));
        await tester.pumpAndSettle();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"stats","lineCount":42}',
        );
        await tester.pump();

        expect(find.text('Lines: 42'), findsOneWidget);
      });

      testWidgets('status bar hidden when showStatusBar false', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          showStatusBar: false,
        )));
        await tester.pumpAndSettle();

        expect(find.text('Ln'), findsNothing);
        expect(find.text('Ch'), findsNothing);
      });
    });

    group('controller swapping', () {
      testWidgets('swapping controllers rewires listeners', (tester) async {
        final bundleA = await _createBundle();
        final bundleB = await _createBundle();
        final calls = <String>[];
        bundleA.webview.enqueueResult('flutterMonaco.getValue()', 'A');
        bundleB.webview.enqueueResult('flutterMonaco.getValue()', 'B');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundleA.controller,
          contentDebounce: Duration.zero,
          onContentChanged: calls.add,
        )));
        await tester.pumpAndSettle();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundleB.controller,
          contentDebounce: Duration.zero,
          onContentChanged: calls.add,
        )));
        await tester.pumpAndSettle();

        // Old controller event should not trigger callback
        bundleA.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();
        expect(calls.length, 0);

        // New controller event should trigger
        bundleB.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":true}',
        );
        await tester.pump();
        expect(calls.length, 1);
        expect(calls.first, 'B');
      });
    });

    group('customCss handling', () {
      testWidgets('customCss change does not rebuild when not owned',
          (tester) async {
        final bundle = await _createBundle();
        var readyCount = 0;

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          onReady: (_) => readyCount++,
          customCss: null,
        )));
        await tester.pump();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          onReady: (_) => readyCount++,
          customCss: 'body { background: red; }',
        )));
        await tester.pump();

        expect(readyCount, 1); // Not rebuilt
      });

      testWidgets('customCss change rebuilds when owned', (tester) async {
        var factoryCalls = 0;
        final webviews = <FakePlatformWebViewController>[];

        Future<MonacoController> factory() async {
          factoryCalls++;
          final webview = FakePlatformWebViewController(
            widget: const SizedBox(key: Key('webview')),
          );
          webviews.add(webview);
          return MonacoController.createForTesting(
            webViewController: webview,
            markReady: true,
          );
        }

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
          customCss: null,
        )));
        await tester.pump();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
          customCss: 'body { background: red; }',
        )));
        await tester.pump();

        expect(factoryCalls, 2);
        expect(webviews.first.disposed, true);
      });

      testWidgets('stale bootstrap ignores late readiness', (tester) async {
        final controllers = <MonacoController>[];
        var readyCount = 0;
        var callIndex = 0;

        Future<MonacoController> factory() async {
          callIndex++;
          final ready = callIndex > 1;
          final webview = FakePlatformWebViewController(
            widget: SizedBox(key: Key('webview_$callIndex')),
          );
          final controller = await MonacoController.createForTesting(
            webViewController: webview,
            markReady: ready,
          );
          controllers.add(controller);
          return controller;
        }

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
          customCss: null,
          onReady: (_) => readyCount++,
        )));
        await tester.pump();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
          customCss: 'body { background: red; }',
          onReady: (_) => readyCount++,
        )));
        await tester.pump();

        expect(controllers.length, 2);
        expect(readyCount, 1);

        controllers.first.completeReadyForTesting();
        await tester.pump();

        expect(readyCount, 1);
      });
    });

    group('disposal', () {
      testWidgets('dispose cancels debounce timers', (tester) async {
        final bundle = await _createBundle();
        final calls = <String>[];
        bundle.webview.enqueueResult('flutterMonaco.getValue()', 'A');

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          contentDebounce: const Duration(milliseconds: 100),
          onContentChanged: calls.add,
        )));
        await tester.pump();

        bundle.webview.emitToChannel(
          'flutterChannel',
          '{"event":"contentChanged","isFlush":false}',
        );

        // Dispose before debounce completes
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 200));

        expect(calls.length, 0); // Timer cancelled
      });

      testWidgets('owned controller disposed on unmount', (tester) async {
        final webviews = <FakePlatformWebViewController>[];

        Future<MonacoController> factory() async {
          final webview = FakePlatformWebViewController(
            widget: const SizedBox(key: Key('webview')),
          );
          webviews.add(webview);
          return MonacoController.createForTesting(
            webViewController: webview,
            markReady: true,
          );
        }

        await tester.pumpWidget(_wrap(MonacoEditor(
          controllerFactory: factory,
        )));
        await tester.pump();

        expect(webviews.length, 1);
        expect(webviews.first.disposed, false);

        await tester.pumpWidget(const SizedBox.shrink());

        expect(webviews.first.disposed, true);
      });

      testWidgets('external controller not disposed on unmount',
          (tester) async {
        final bundle = await _createBundle();

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
        )));
        await tester.pump();

        await tester.pumpWidget(const SizedBox.shrink());

        expect(bundle.webview.disposed, false);
      });
    });

    group('styling', () {
      testWidgets('backgroundColor applied', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          backgroundColor: Colors.red,
        )));
        await tester.pump();

        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.byKey(const Key('webview')),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(container.color, Colors.red);
        expect(
          bundle.webview.executed
              .any((s) => s.startsWith('SET_BACKGROUND_COLOR')),
          true,
        );
      });

      testWidgets('padding applied', (tester) async {
        final bundle = await _createBundle();
        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          padding: const EdgeInsets.all(16),
        )));
        await tester.pump();

        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.byKey(const Key('webview')),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(container.padding, const EdgeInsets.all(16));
      });

      testWidgets('constraints applied', (tester) async {
        final bundle = await _createBundle();
        const constraints = BoxConstraints(maxHeight: 300);

        await tester.pumpWidget(_wrap(MonacoEditor(
          controller: bundle.controller,
          constraints: constraints,
        )));
        await tester.pump();

        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.byKey(const Key('webview')),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(container.constraints, constraints);
      });
    });
  });
}
