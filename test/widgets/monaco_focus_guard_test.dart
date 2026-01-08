import 'package:flutter/material.dart';
import 'package:flutter_monaco/flutter_monaco.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/fake_platform_webview_controller.dart';

Future<MonacoController> _controller(FakePlatformWebViewController webview) {
  return MonacoController.createForTesting(
    webViewController: webview,
    markReady: true,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MonacoFocusGuard', () {
    testWidgets('resumed triggers ensureEditorFocus', (tester) async {
      final webview = FakePlatformWebViewController();
      final controller = await _controller(webview);
      await tester.pumpWidget(_wrap(MonacoFocusGuard(
        controller: controller,
        ensureAttempts: 1,
      )));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(webview.executed.join('\n').contains('forceFocus'), true);
    });

    testWidgets('didPopNext triggers ensureEditorFocus', (tester) async {
      final webview = FakePlatformWebViewController();
      final controller = await _controller(webview);
      final observer = RouteObserver<PageRoute<dynamic>>();

      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Column(
                children: [
                  MonacoFocusGuard(
                    controller: controller,
                    routeObserver: observer,
                    ensureAttempts: 1,
                  ),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(body: Text('next')),
                        ),
                      );
                    },
                    child: const Text('push'),
                  ),
                ],
              ),
            );
          },
        ),
      ));

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();
      webview.executed.clear();

      Navigator.of(tester.element(find.text('next'))).pop();
      await tester.pumpAndSettle();
      expect(webview.executed.join('\n').contains('forceFocus'), true);
    });
  });
}
