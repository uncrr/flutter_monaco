import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:flutter_monaco/src/platform/platform_webview.dart';

/// Matcher function type for determining if a script should trigger an action.
typedef ScriptMatcher = bool Function(String script);

/// Resolver function type for returning results for scripts.
typedef ScriptResultResolver = Object? Function(String script);

/// A fake implementation of [PlatformWebViewController] for testing.
///
/// This fake allows tests to:
/// - Track executed JavaScript scripts
/// - Enqueue specific results for scripts
/// - Simulate errors
/// - Emit messages to channels
/// - Verify channel registration
class FakePlatformWebViewController implements PlatformWebViewController {
  /// Creates a fake WebView controller.
  ///
  /// [widget] - Optional widget to return from [widget] getter.
  FakePlatformWebViewController({Widget? widget})
      : _widget = widget ?? const SizedBox.shrink();

  /// All executed JavaScript scripts in order.
  final List<String> executed = [];

  /// Registered channels and their handlers.
  final Map<String, void Function(String)> _channels = {};

  final Widget _widget;

  /// Whether [initialize] was called.
  bool initialized = false;

  /// Whether [enableJavaScript] was called.
  bool jsEnabled = false;

  /// Whether [dispose] was called.
  bool disposed = false;

  /// Queue of results to return for specific scripts.
  final Map<String, Queue<Object?>> _resultsQueue = {};

  /// Dynamic result resolver called when no queued result exists.
  ScriptResultResolver? resultResolver;

  /// Matchers for scripts that should throw errors.
  final List<ScriptMatcher> _throwMatchers = [];

  /// Loaded file paths.
  final List<String> loadedFiles = [];

  @override
  Future<void> initialize() async {
    if (disposed) {
      throw StateError('Cannot initialize disposed controller');
    }
    initialized = true;
  }

  @override
  Future<void> enableJavaScript() async {
    if (disposed) {
      throw StateError('Cannot enable JS on disposed controller');
    }
    jsEnabled = true;
  }

  @override
  Future<void> addJavaScriptChannel(
    String name,
    void Function(String) onMessage,
  ) async {
    if (disposed) {
      throw StateError('Cannot add channel to disposed controller');
    }
    _channels[name] = onMessage;
  }

  @override
  Future<void> removeJavaScriptChannel(String name) async {
    _channels.remove(name);
  }

  @override
  Future<void> loadFile(String path) async {
    if (disposed) {
      throw StateError('Cannot load file on disposed controller');
    }
    loadedFiles.add(path);
    executed.add('LOAD_FILE:$path');
  }

  @override
  Future<void> setBackgroundColor(Color color) async {
    if (disposed) {
      throw StateError('Cannot set background color on disposed controller');
    }
    executed.add('SET_BACKGROUND_COLOR:$color');
  }

  @override
  Future<void> runJavaScript(String script) async {
    if (disposed) {
      throw StateError('Cannot run JS on disposed controller');
    }
    if (_shouldThrow(script)) {
      throw StateError('Fake runJavaScript error for: $script');
    }
    executed.add(script);
  }

  @override
  Future<Object?> runJavaScriptReturningResult(String script) async {
    if (disposed) {
      throw StateError('Cannot run JS on disposed controller');
    }
    if (_shouldThrow(script)) {
      throw StateError('Fake runJavaScriptReturningResult error for: $script');
    }
    executed.add(script);
    return _getResult(script);
  }

  @override
  Widget get widget => _widget;

  @override
  void dispose() {
    disposed = true;
  }

  // Test utilities

  /// Returns true if a channel with [name] is registered.
  bool hasChannel(String name) => _channels.containsKey(name);

  /// Returns a list of all registered channel names.
  List<String> get channelNames => _channels.keys.toList();

  /// Enqueues a result to return for a specific [script].
  ///
  /// Results are returned in FIFO order for each script key.
  void enqueueResult(String script, Object? result) {
    _resultsQueue.putIfAbsent(script, () => Queue<Object?>()).add(result);
  }

  /// Enqueues multiple results for a script.
  void enqueueResults(String script, List<Object?> results) {
    for (final result in results) {
      enqueueResult(script, result);
    }
  }

  /// Configures scripts matching [matcher] to throw errors.
  void throwOn(ScriptMatcher matcher) {
    _throwMatchers.add(matcher);
  }

  /// Configures scripts containing [substring] to throw errors.
  void throwOnContains(String substring) {
    throwOn((script) => script.contains(substring));
  }

  /// Clears all throw matchers.
  void clearThrowMatchers() {
    _throwMatchers.clear();
  }

  /// Emits a message to a registered channel.
  ///
  /// Throws if the channel is not registered.
  void emitToChannel(String name, String message) {
    final handler = _channels[name];
    if (handler == null) {
      throw StateError('No channel registered for $name');
    }
    handler(message);
  }

  /// Tries to emit a message, returning false if channel doesn't exist.
  bool tryEmitToChannel(String name, String message) {
    final handler = _channels[name];
    if (handler == null) return false;
    handler(message);
    return true;
  }

  /// Clears all executed scripts.
  void clearExecuted() {
    executed.clear();
  }

  /// Clears all state (executed, queues, matchers, channels).
  void reset() {
    executed.clear();
    _resultsQueue.clear();
    _throwMatchers.clear();
    _channels.clear();
    resultResolver = null;
    initialized = false;
    jsEnabled = false;
    disposed = false;
    loadedFiles.clear();
  }

  /// Returns scripts containing [substring].
  List<String> scriptsContaining(String substring) {
    return executed.where((s) => s.contains(substring)).toList();
  }

  /// Returns true if any executed script contains [substring].
  bool hasExecuted(String substring) {
    return executed.any((s) => s.contains(substring));
  }

  /// Returns the count of scripts containing [substring].
  int executionCount(String substring) {
    return executed.where((s) => s.contains(substring)).length;
  }

  bool _shouldThrow(String script) {
    return _throwMatchers.any((matcher) => matcher(script));
  }

  Object? _getResult(String script) {
    // Check queued results first
    final queued = _resultsQueue[script];
    if (queued != null && queued.isNotEmpty) {
      return queued.removeFirst();
    }

    // Fall back to resolver
    return resultResolver?.call(script);
  }
}

/// Extension methods for easier test assertions.
extension FakePlatformWebViewControllerAssertions
    on FakePlatformWebViewController {
  /// Asserts that a script containing [substring] was executed.
  void assertExecuted(String substring) {
    if (!hasExecuted(substring)) {
      throw TestFailure(
        'Expected script containing "$substring" to be executed.\n'
        'Executed scripts:\n${executed.map((s) => '  - $s').join('\n')}',
      );
    }
  }

  /// Asserts that no script containing [substring] was executed.
  void assertNotExecuted(String substring) {
    if (hasExecuted(substring)) {
      final matching = scriptsContaining(substring);
      throw TestFailure(
        'Expected no script containing "$substring" to be executed.\n'
        'Found ${matching.length} matching scripts:\n${matching.map((s) => '  - $s').join('\n')}',
      );
    }
  }

  /// Asserts the exact execution count for scripts containing [substring].
  void assertExecutionCount(String substring, int expected) {
    final actual = executionCount(substring);
    if (actual != expected) {
      throw TestFailure(
        'Expected $expected executions of scripts containing "$substring", '
        'but found $actual.',
      );
    }
  }
}

/// A simple test failure exception for assertions.
class TestFailure implements Exception {
  TestFailure(this.message);
  final String message;

  @override
  String toString() => message;
}
