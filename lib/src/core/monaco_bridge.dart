import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_helper_utils/flutter_helper_utils.dart';
import 'package:flutter_monaco/src/models/monaco_types.dart';
import 'package:flutter_monaco/src/platform/platform_webview.dart';

/// A communication bridge between Flutter and the Monaco Editor in a WebView.
class MonacoBridge extends ChangeNotifier {
  /// Creates a Monaco bridge and guards against unhandled readiness errors.
  MonacoBridge() {
    // Prevent unhandled async errors when disposed before readiness.
    onReady.future.catchError((_) {});
  }

  PlatformWebViewController? _webViewController;

  /// A completer that notifies when the Monaco editor is initialized and ready.
  final Completer<void> onReady = Completer<void>();

  /// A [ValueNotifier] that provides real-time statistics from the editor.
  final ValueNotifier<LiveStats> liveStats =
      ValueNotifier(LiveStats.defaults());

  final List<void Function(Map<String, dynamic>)> _rawListeners = [];
  bool _disposed = false;

  /// Returns true if this bridge has been disposed.
  bool get isDisposed => _disposed;

  /// Attaches the underlying [PlatformWebViewController] to this bridge.
  void attachWebView(PlatformWebViewController controller) {
    if (_disposed) {
      throw StateError('Cannot attach WebView to disposed bridge');
    }
    if (_webViewController != null && _webViewController != controller) {
      debugPrint(
        '[MonacoBridge] Replacing previously attached WebView controller.',
      );
    }
    _webViewController = controller;
    debugPrint('[MonacoBridge] WebView controller attached.');
  }

  /// Handles incoming messages from the JavaScript side of the editor.
  void handleJavaScriptMessage(dynamic message) {
    if (_disposed) return;

    final String msg;
    if (message is String) {
      msg = message;
    } else if (message is Map || message is List) {
      msg = jsonEncode(message);
    } else if (message != null) {
      msg = message.toString();
    } else {
      msg = '';
    }
    _handleJavaScriptMessage(msg);
  }

  /// Add a raw listener for all JS events.
  void addRawListener(void Function(Map<String, dynamic>) listener) {
    if (_disposed) return;
    _rawListeners.add(listener);
  }

  /// Remove a raw listener.
  void removeRawListener(void Function(Map<String, dynamic>) listener) {
    _rawListeners.remove(listener);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;

    debugPrint('[MonacoBridge] Disposing bridge.');
    if (!onReady.isCompleted) {
      onReady.completeError(
        StateError('Bridge disposed before the editor became ready.'),
      );
    }
    _rawListeners.clear();
    liveStats.dispose();
    _webViewController = null;
    super.dispose();
  }

  void _handleJavaScriptMessage(String message) {
    if (_disposed) return;

    if (message.startsWith('log:')) {
      debugPrint('[Monaco JS] ${message.substring(4)}');
      return;
    }

    Map<String, dynamic> json;
    try {
      json = ConvertObject.toMap(message);
    } catch (e) {
      debugPrint('[MonacoBridge] Failed to parse message: $message');
      return;
    }

    _routeEvent(json);
    _notifyRawListeners(json);
  }

  void _routeEvent(Map<String, dynamic> json) {
    final event = json['event'];
    if (event == null) {
      debugPrint('[MonacoBridge] Message missing event field');
      return;
    }

    switch (event) {
      case 'onEditorReady':
        if (!onReady.isCompleted) {
          debugPrint('[MonacoBridge] ✅ "onEditorReady" event received.');
          onReady.complete();
        }
        break;

      case 'stats':
        try {
          liveStats.value = LiveStats.fromJson(json);
        } catch (e) {
          debugPrint('[MonacoBridge] Failed to parse stats: $e');
        }
        break;

      case 'error':
        final message = json['message'] ?? 'Unknown error';
        debugPrint('❌ [Monaco JS Error] $message');
        break;

      case 'contentChanged':
      case 'selectionChanged':
      case 'focus':
      case 'blur':
      case 'completionRequest':
        // Handled by controller's raw listener
        break;

      default:
        debugPrint('[MonacoBridge] Unhandled JS event type: "$event"');
    }
  }

  void _notifyRawListeners(Map<String, dynamic> json) {
    if (_disposed) return;

    // Create a copy to avoid concurrent modification
    final listeners =
        List<void Function(Map<String, dynamic>)>.of(_rawListeners);
    for (final listener in listeners) {
      try {
        listener(json);
      } catch (e, st) {
        debugPrint('[MonacoBridge] Error in raw listener: $e\n$st');
      }
    }
  }
}
