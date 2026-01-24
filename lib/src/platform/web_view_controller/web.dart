import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:flutter_monaco/src/core/monaco_assets.dart';
import 'package:flutter_monaco/src/platform/platform_webview.dart';
import 'package:web/web.dart' as web;

/// WebView implementation for Flutter Web using an iframe.
///
/// On web platforms, native WebViews aren't available, so Monaco is hosted
/// in an iframe element. This approach provides:
///
/// - **Isolation:** Monaco runs in a separate browsing context
/// - **Security:** Content-Security-Policy can be applied per-iframe
/// - **Compatibility:** Works across all modern browsers
///
/// ### Communication
///
/// The iframe communicates with Flutter via `postMessage`:
/// - **Monaco to Flutter:** `window.parent.postMessage(msg, '*')`
/// - **Flutter to Monaco:** `iframe.contentWindow.eval(script)`
///
/// The HTML defines `window.flutterChannel.postMessage` which calls
/// `window.parent.postMessage`, maintaining API consistency with native.
///
/// ### HTML Loading
///
/// Monaco HTML is generated as a blob URL to avoid CORS issues with
/// `file://` or asset paths. The blob URL is revoked after Monaco
/// reports ready to free memory.
///
/// ### Focus Handling
///
/// Web focus is tricky because the iframe is a separate browsing context.
/// When Monaco reports focus events, this controller unfocuses Flutter
/// widgets and uses `forceFocus()` to ensure Monaco retains keyboard input.
///
/// See also:
/// - [MonacoAssets.generateIndexHtml] for HTML generation with web-specific
///   worker shims.
/// - [native.dart] for native platform implementations.
class WebViewController implements PlatformWebViewController {
  final Map<String, void Function(String)> _channels = {};
  bool _disposed = false;

  final Completer<void> _readyCompleter = Completer<void>();
  bool _isReady = false;

  web.HTMLIFrameElement? _iframe;
  JSFunction? _messageHandler;
  String? _viewId;
  late final String _messageToken;

  final _widgetKey = GlobalKey();
  Widget? _cachedWidget;

  @override
  Widget get widget =>
      _cachedWidget ??= HtmlElementView(key: _widgetKey, viewType: _viewId!);

  @override
  Future<void> initialize() async {
    _viewId = 'monaco-iframe-${DateTime.now().millisecondsSinceEpoch}';
    debugPrint('[WebViewController] Initializing iframe approach');
    _messageToken = 'monaco-${DateTime.now().microsecondsSinceEpoch}-$_viewId';

    // Create iframe for Monaco.
    _iframe = web.HTMLIFrameElement()
      ..id = _viewId!
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.border = 'none'
      ..allow = 'clipboard-read; clipboard-write';

    // Register the view factory.
    ui_web.platformViewRegistry.registerViewFactory(_viewId!, (_) => _iframe!);

    // Listen for messages from the iframe.
    final handler = _handleIframeMessage.toJS;
    _messageHandler = handler;
    web.window.addEventListener('message', handler);

    debugPrint('[WebViewController] View factory registered with ID: $_viewId');
  }

  void _handleIframeMessage(web.MessageEvent event) {
    // Only accept messages from our iframe
    if (_iframe?.contentWindow != event.source) return;

    final data = event.data;
    String message;
    Map<String, dynamic>? json;

    try {
      // Try to convert as string first
      message = (data as JSString).toDart;
    } catch (_) {
      // If not a string, try to convert as object
      try {
        message = jsonEncode((data as JSObject).dartify());
      } catch (_) {
        message = data.toString();
      }
    }

    if (message.startsWith('{')) {
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map<String, dynamic>) {
          json = decoded;
        }
      } catch (_) {}
    }

    if (json != null) {
      final token = json['_flutterToken'];
      if (token != _messageToken) return;
    } else if (message != 'ready') {
      return;
    }

    // Only log non-stats messages to reduce noise (stats fire on every keystroke/selection)
    final isStatsMessage = message.contains('"event":"stats"') ||
        message.contains('"event": "stats"');
    if (!isStatsMessage) {
      debugPrint('[WebViewController] Received iframe message: $message');
    }

    // Check if this is the ready event
    if (message == 'ready' ||
        message.contains('"event":"onEditorReady"') ||
        message.contains('"event": "onEditorReady"')) {
      _isReady = true;
      if (!_readyCompleter.isCompleted) {
        _readyCompleter.complete();
      }
      debugPrint('[WebViewController] Monaco ready!');
    }

    // When Monaco reports focus, unfocus Flutter widgets and ensure Monaco keeps focus.
    if (message.contains('"event":"focus"') ||
        message.contains('"event": "focus"')) {
      // Unfocus any Flutter widget
      FocusManager.instance.primaryFocus?.unfocus();
      // Use Monaco's forceFocus to ensure editor keeps focus
      _iframe?.contentWindow?.callMethod(
        'eval'.toJS,
        'window.flutterMonaco && window.flutterMonaco.forceFocus()'.toJS,
      );
    }

    // Forward to all channels
    for (final handler in _channels.values) {
      handler(message);
    }
  }

  Future<void> _ensureReady() async {
    if (!_isReady) {
      await _readyCompleter.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () {
          throw TimeoutException('Monaco editor failed to initialize');
        },
      );
    }
  }

  @override
  Future<void> setBackgroundColor(Color color) async {
    final r = (color.r * 255).round();
    final g = (color.g * 255).round();
    final b = (color.b * 255).round();
    _iframe?.style.backgroundColor = 'rgba($r, $g, $b, ${color.a})';
  }

  @override
  Future<void> enableJavaScript() async {}

  @override
  Future<Object?> runJavaScript(String script) async {
    if (_disposed) return null;

    try {
      _iframe?.contentWindow?.callMethod('eval'.toJS, script.toJS);
      return null;
    } catch (e) {
      debugPrint('[WebViewController] JS execution error: $e');
      rethrow;
    }
  }

  @override
  Future<Object?> runJavaScriptReturningResult(String script) async {
    if (_disposed) return null;

    try {
      final result =
          _iframe?.contentWindow?.callMethod('eval'.toJS, script.toJS);
      return result?.dartify();
    } catch (e) {
      debugPrint('[WebViewController] JS result error: $e');
      rethrow;
    }
  }

  @override
  Future<Object?> addJavaScriptChannel(
    String name,
    void Function(String) onMessage,
  ) async {
    debugPrint('[WebViewController] Adding JS channel: $name');
    _channels[name] = onMessage;
    return null;
  }

  @override
  Future<Object?> removeJavaScriptChannel(String name) async {
    _channels.remove(name);
    return null;
  }

  @override
  Future<void> load({String? customCss, bool allowCdnFonts = false}) async {
    debugPrint('[WebViewController] Loading Monaco in iframe');

    // Resolve path against base URI to support subpaths
    final vsPath = Uri.base
        .resolve('assets/${MonacoAssets.assetBaseDir}/min/vs')
        .toString();

    final html = MonacoAssets.generateIndexHtml(
      vsPath,
      isWindows: false,
      isIosOrMacOS: false,
      isWeb: true,
      messageToken: _messageToken,
      customCss: customCss,
      allowCdnFonts: allowCdnFonts,
    );

    // Create a blob URL for the HTML content
    final blobUrl = web.URL.createObjectURL(web.Blob(
      [html.toJS].toJS,
      web.BlobPropertyBag(type: 'text/html'),
    ));
    _iframe!.src = blobUrl;

    await _ensureReady();

    // Clean up blob URL after Monaco is ready
    web.URL.revokeObjectURL(blobUrl);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    debugPrint('[WebViewController] Disposing...');
    if (_messageHandler != null) {
      web.window.removeEventListener('message', _messageHandler!);
      _messageHandler = null;
    }
    _channels.clear();
    _cachedWidget = null;
    _iframe?.remove();
    _iframe = null;
  }
}
