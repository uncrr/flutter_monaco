import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_monaco/src/core/io_export.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages Monaco Editor assets across all platforms.
///
/// This class is the single source of truth for Monaco asset locations, versions,
/// and extraction. It handles:
///
/// - **Asset extraction:** Copies bundled Monaco files to app support directory
///   on native platforms for WebView access.
/// - **Version management:** Tracks Monaco version and re-extracts on updates.
/// - **HTML generation:** Creates platform-specific HTML with correct paths
///   and Content-Security-Policy headers.
/// - **Caching:** Avoids redundant extraction and HTML generation.
///
/// ### Platform Behavior
///
/// - **Native (Android/iOS/macOS/Windows):** Assets are extracted from the app
///   bundle to the application support directory on first use. A sentinel file
///   tracks the version to detect when re-extraction is needed.
/// - **Web:** Assets are served directly from the `assets/` directory. No
///   extraction is needed.
///
/// ### Usage
///
/// ```dart
/// // Ensure assets are ready before using Monaco
/// await MonacoAssets.ensureReady();
///
/// // Get the HTML file path for a specific configuration
/// final htmlPath = await MonacoAssets.indexHtmlPath(cacheKey: options.hashCode);
/// ```
///
/// See also:
/// - [MonacoController] which calls [ensureReady] during initialization.
/// - [generateIndexHtml] for HTML generation details.
class MonacoAssets {
  /// The Flutter asset path where Monaco Editor files are bundled.
  ///
  /// This path is relative to the package root and used for both web asset
  /// serving and native asset extraction.
  static const String assetBaseDir = 'packages/flutter_monaco/assets/monaco';

  /// Subdirectory name within application support for extracted assets.
  static const String _cacheSubDir = 'monaco_editor_cache';

  static const String _htmlFileName = 'index.html';

  /// The Monaco Editor version bundled with this package.
  ///
  /// When this version changes, [ensureReady] will re-extract assets on
  /// native platforms to ensure the correct version is used.
  static const String monacoVersion = '0.54.0';

  static Completer<void>? _initCompleter;

  // HTML cache to avoid regenerating the same HTML multiple times
  static final Map<int, String> _htmlCache = {};

  /// Ensures Monaco assets are extracted and ready for use on native platforms.
  ///
  /// This method performs the following checks and operations:
  ///
  /// 1. **Existence check:** Verifies `loader.js` exists in the target directory
  /// 2. **Version check:** Compares sentinel file content with [monacoVersion]
  /// 3. **Extraction:** Copies all assets from the bundle if missing or outdated
  ///
  /// ### Thread Safety
  ///
  /// This method is idempotent and thread-safe. Multiple concurrent calls
  /// will share the same [Completer], ensuring extraction happens only once.
  /// Subsequent calls return immediately if assets are already ready.
  ///
  /// ### Web Platform
  ///
  /// On web, this method completes immediately without any file operations,
  /// as assets are served directly from the web server.
  ///
  /// ### Error Handling
  ///
  /// Throws [StateError] if asset extraction fails (e.g., insufficient disk
  /// space or permission issues). The error includes details about which
  /// files failed to copy.
  ///
  /// ### Example
  ///
  /// ```dart
  /// // Call before creating MonacoController
  /// await MonacoAssets.ensureReady();
  /// final controller = await MonacoController.create();
  /// ```
  static Future<void> ensureReady() async {
    if (_initCompleter != null) return _initCompleter!.future;

    final completer = _initCompleter = Completer<void>();

    if (!kIsWeb) {
      try {
        final targetDir = await _getTargetDir();
        final loader = File(p.join(targetDir, 'min', 'vs', 'loader.js'));
        final sentinel = File(p.join(targetDir, '.monaco_complete'));

        final ok = loader.existsSync() &&
            sentinel.existsSync() &&
            (await sentinel.readAsString()).trim() == monacoVersion;

        if (!ok) {
          debugPrint(
              '[MonacoAssets] Monaco not found or incomplete, copying assets...');
          await _copyAllAssets(targetDir);
        } else {
          debugPrint(
              '[MonacoAssets] Monaco already extracted at: $targetDir (version $monacoVersion)');
        }

        completer.complete();
      } catch (e, st) {
        _initCompleter = null;
        completer.completeError(e, st);
      }
    }

    if (!completer.isCompleted && kIsWeb) {
      completer.complete();
    }

    return completer.future;
  }

  /// Returns the path to the Monaco HTML file for a given configuration.
  ///
  /// The [cacheKey] should be derived from configuration options that affect
  /// HTML generation (e.g., `Object.hash(customCss, allowCdnFonts)`). This
  /// enables caching multiple HTML variants for different configurations.
  ///
  /// ### Native Platforms
  ///
  /// Ensures assets are extracted via [ensureReady], then returns a path
  /// like: `{appSupport}/monaco_editor_cache/monaco-{version}/monaco_{key}.html`
  ///
  /// The actual HTML file is created lazily by the WebView controller when
  /// it calls [generateIndexHtml].
  ///
  /// ### Web Platform
  ///
  /// Returns the static asset path directly:
  /// `assets/packages/flutter_monaco/assets/monaco/index.html`
  ///
  /// Note that on web, the [cacheKey] is ignored since HTML is generated
  /// dynamically as a blob URL rather than loaded from this path.
  static Future<String> indexHtmlPath({required int cacheKey}) async {
    if (kIsWeb) {
      return 'assets/packages/flutter_monaco/assets/monaco/index.html';
    }

    await ensureReady();
    final targetDir = await _getTargetDir();

    // Check if we already have this HTML cached
    if (_htmlCache.containsKey(cacheKey)) {
      return _htmlCache[cacheKey]!;
    }

    // Cache and return the path
    return _htmlCache[cacheKey] = p.join(targetDir, 'monaco_$cacheKey.html');
  }

  /// Returns diagnostic information about extracted Monaco assets.
  ///
  /// This method is useful for debugging asset extraction issues or
  /// displaying version information in an about dialog.
  ///
  /// ### Returned Fields
  ///
  /// - `exists` (bool): Whether the asset directory exists
  /// - `path` (String): Absolute path to the asset directory
  /// - `version` (String): The [monacoVersion] constant
  /// - `fileCount` (int): Number of files in the directory (if exists)
  /// - `totalSize` (int): Total size in bytes (if exists)
  /// - `totalSizeMB` (String): Formatted size in megabytes (if exists)
  /// - `generatedHtmlCount` (int): Number of generated HTML files found
  ///
  /// ### Web Platform
  ///
  /// On web, assets are served directly from the web server, so this returns
  /// limited information without file system access.
  ///
  /// ### Example
  ///
  /// ```dart
  /// final info = await MonacoAssets.assetInfo();
  /// print('Monaco ${info['version']} - ${info['totalSizeMB']} MB');
  /// ```
  static Future<Map<String, dynamic>> assetInfo() async {
    // Web platform doesn't use extracted assets
    if (kIsWeb) {
      return {
        'exists': true,
        'path': 'assets/$assetBaseDir',
        'version': monacoVersion,
        'platform': 'web',
        'note': 'Assets served directly from web server, no extraction needed.',
      };
    }

    final targetDir = await _getTargetDir();
    final directory = Directory(targetDir);

    if (!directory.existsSync()) {
      return {
        'exists': false,
        'path': targetDir,
        'version': monacoVersion,
      };
    }

    // Count files and calculate size
    int fileCount = 0;
    int totalSize = 0;
    int generatedHtmlCount = 0;

    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) {
        fileCount++;
        totalSize += await entity.length();

        // Count generated HTML files (monaco_*.html pattern)
        final fileName = p.basename(entity.path);
        if (fileName.startsWith('monaco_') && fileName.endsWith('.html')) {
          generatedHtmlCount++;
        }
      }
    }

    return {
      'exists': true,
      'path': targetDir,
      'version': monacoVersion,
      'fileCount': fileCount,
      'totalSize': totalSize,
      'totalSizeMB': (totalSize / 1024 / 1024).toStringAsFixed(2),
      'generatedHtmlCount': generatedHtmlCount,
    };
  }

  /// Deletes all extracted Monaco assets and resets initialization state.
  ///
  /// This method:
  /// 1. Recursively deletes the Monaco asset directory
  /// 2. Clears the in-memory HTML cache
  /// 3. Resets [_initCompleter] so [ensureReady] will re-extract
  ///
  /// ### Use Cases
  ///
  /// - **Corruption recovery:** If Monaco fails to load, clearing and
  ///   re-extracting may fix the issue.
  /// - **Storage cleanup:** Frees ~5-10MB of disk space.
  /// - **Development:** Forces fresh extraction after updating Monaco assets.
  ///
  /// ### Web Platform
  ///
  /// On web, this method only clears the in-memory HTML cache since assets
  /// are served directly from the web server and cannot be deleted.
  ///
  /// ### Example
  ///
  /// ```dart
  /// // Clear corrupted assets and re-extract
  /// await MonacoAssets.clearCache();
  /// await MonacoAssets.ensureReady();
  /// ```
  ///
  /// **Note:** Any existing [MonacoController] instances will become invalid
  /// after clearing. Dispose and recreate them after calling this method.
  static Future<void> clearCache() async {
    // On web, only clear in-memory caches (no file system access)
    if (kIsWeb) {
      _initCompleter = null;
      _htmlCache.clear();
      debugPrint('[MonacoAssets] Web cache cleared (in-memory only)');
      return;
    }

    final targetDir = await _getTargetDir();
    final directory = Directory(targetDir);

    if (directory.existsSync()) {
      await directory.delete(recursive: true);
      debugPrint('[MonacoAssets] Monaco assets cleaned');
    }

    // Reset the init completer and HTML cache
    _initCompleter = null;
    _htmlCache.clear();
  }

  // --- Private Helpers ---

  static Future<String> _getTargetDir() async {
    return p.join(
      (await getApplicationSupportDirectory()).path,
      _cacheSubDir,
      'monaco-$monacoVersion',
    );
  }

  static Future<void> _copyAllAssets(String targetDir) async {
    final stopwatch = Stopwatch()..start();
    final failures = <String>[];

    // Clean and create target directory
    final directory = Directory(targetDir);
    if (directory.existsSync()) {
      await directory.delete(recursive: true);
    }
    await directory.create(recursive: true);

    // Get all assets from the manifest
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final monacoAssets = manifest
        .listAssets()
        .where((key) => key.startsWith(
            '$assetBaseDir/')) // Trailing slash prevents matching similar prefixes
        .where((key) => !key.endsWith('.DS_Store')) // Skip macOS metadata files
        .where((key) => !key
            .endsWith('/$_htmlFileName')) // Exclude index.html from copy list
        .toList();

    debugPrint(
      '[MonacoAssets] Found ${monacoAssets.length} Monaco assets to copy',
    );

    // Copy each asset maintaining directory structure
    var copiedCount = 0;
    for (final assetKey in monacoAssets) {
      try {
        // Calculate relative path within the monaco directory
        final relativePath = assetKey.substring('$assetBaseDir/'.length);
        if (relativePath.isEmpty) continue;

        // Create target file path
        final targetFile = File(p.join(targetDir, relativePath));

        // Ensure parent directory exists
        await targetFile.parent.create(recursive: true);

        // Load and write asset
        final bytes = await rootBundle.load(assetKey);
        await targetFile.writeAsBytes(bytes.buffer.asUint8List());

        copiedCount++;

        // Log progress every 100 files
        if (copiedCount % 100 == 0) {
          debugPrint(
            '[MonacoAssets] Progress: $copiedCount/${monacoAssets.length} files copied',
          );
        }
      } catch (e) {
        debugPrint('[MonacoAssets] Error copying $assetKey: $e');
        failures.add('$assetKey: $e');
      }
    }

    stopwatch.stop();
    debugPrint(
      '[MonacoAssets] Completed: $copiedCount files copied in ${stopwatch.elapsedMilliseconds}ms',
    );

    if (copiedCount != monacoAssets.length || failures.isNotEmpty) {
      throw StateError(
        '[MonacoAssets] Copy incomplete ($copiedCount/${monacoAssets.length}). '
        'Failures: ${failures.length}',
      );
    }

    // Write sentinel file to mark successful completion
    final sentinelFile = File(p.join(targetDir, '.monaco_complete'));
    await sentinelFile.writeAsString(monacoVersion);
    debugPrint(
        '[MonacoAssets] Sentinel file written for version $monacoVersion');
  }

  /// Generates the HTML document that hosts the Monaco Editor.
  ///
  /// This method creates a complete HTML page with:
  /// - Monaco loader and editor initialization
  /// - Platform-specific worker shims (blob URLs for WKWebView, etc.)
  /// - JavaScript bridge (`window.flutterMonaco`) for Flutter communication
  /// - Content-Security-Policy headers for security
  /// - Optional custom CSS injection
  ///
  /// ### Parameters
  ///
  /// - [vsPath]: The path to the Monaco `vs/` directory. This varies by platform:
  ///   - **Windows:** Absolute `file://` URL (e.g., `file:///C:/path/min/vs`)
  ///   - **macOS/iOS:** Relative path (e.g., `min/vs`)
  ///   - **Web:** Full URL resolved from base (e.g., `http://host/assets/.../min/vs`)
  ///
  /// - [isWindows]: Set `true` for Windows to configure WebView2 communication
  ///   via `chrome.webview.postMessage`.
  ///
  /// - [isIosOrMacOS]: Set `true` for Apple platforms to enable blob URL worker
  ///   shims required by WKWebView's `file://` restrictions.
  ///
  /// - [isWeb]: Set `true` for web platform to use iframe `postMessage` and
  ///   dynamic loader script injection.
  ///
  /// - [customCss]: Optional CSS string injected into a `<style>` tag. Use for
  ///   custom fonts (`@font-face`), theme overrides, or UI tweaks.
  ///
  /// - [allowCdnFonts]: If `true`, relaxes CSP to allow `https:` in `style-src`
  ///   and `font-src`, enabling CDN-hosted fonts. **Security note:** This allows
  ///   network requests from the editor.
  ///
  /// ### The `flutterMonaco` Bridge
  ///
  /// The generated HTML defines `window.flutterMonaco` with methods like:
  /// - `getValue()`, `setValue(v)` - Content management
  /// - `setTheme(t)`, `setLanguage(l)` - Editor configuration
  /// - `getSelection()`, `setSelection(r)` - Selection handling
  /// - `findMatches(q, opts)`, `replaceMatches(q, r, opts)` - Search
  /// - `registerCompletionSource(cfg)` - Autocompletion
  ///
  /// Events are sent to Flutter via `flutterChannel.postMessage(json)`.
  ///
  /// See also:
  /// - [MonacoController] which calls the `flutterMonaco` methods.
  /// - [MonacoBridge] which receives events from the HTML.
  static String generateIndexHtml(
    String vsPath, {
    bool isWindows = false,
    bool isIosOrMacOS = false,
    bool isWeb = false,
    String? messageToken,
    String? customCss,
    bool allowCdnFonts = false,
  }) {
    // Platform-specific initialization scripts
    String platformScript = '';

    if (isWeb) {
      platformScript = '''
<script>
  console.log('[Web Init] Setting up for iframe mode');
  self.MonacoEnvironment = {
    baseUrl: '$vsPath/../',
    getWorkerUrl: function(moduleId, label) {
      var workerSrc = "self.MonacoEnvironment = { baseUrl: '$vsPath/../' }; importScripts('$vsPath/base/worker/workerMain.js');";
      return URL.createObjectURL(new Blob([workerSrc], { type: 'application/javascript' }));
    }
  };
  window.flutterChannel = {
    postMessage: function(msg) {
      window.parent.postMessage(msg, '*');
    }
  };
  window.flutterMonacoToken = '${messageToken ?? ''}';
  window.flutterMonacoPostMessage = function(message) {
    var token = window.flutterMonacoToken;
    if (typeof message !== 'string') {
      if (token && message && typeof message === 'object') {
        message._flutterToken = token;
      }
      message = JSON.stringify(message);
    } else {
      try {
        var parsed = JSON.parse(message);
        if (parsed && typeof parsed === 'object') {
          if (token) parsed._flutterToken = token;
          message = JSON.stringify(parsed);
        }
      } catch (_) {}
    }
    if (window.flutterChannel && window.flutterChannel.postMessage) {
      window.flutterChannel.postMessage(message);
    }
  };
  console.log('[Web Init] flutterChannel created successfully');
</script>
''';
    } else if (isWindows) {
      platformScript = '''
<script>
  // Windows: Create flutterChannel immediately when document is created
  console.log('[Windows Init] Creating flutterChannel on document creation');
  window.flutterChannel = {
    postMessage: function(msg) {
      console.log('[flutterChannel] Posting message:', msg);
      if (window.chrome && window.chrome.webview) {
        window.chrome.webview.postMessage(msg);
      } else {
        console.error('[flutterChannel] WebView2 API not available!');
      }
    }
  };
  console.log('[Windows Init] flutterChannel created successfully');
</script>
''';
    } else if (isIosOrMacOS) {
      // iOS and macOS need blob worker shim for WKWebView + file:// protocol
      platformScript = '''
<script>
  (function () {
    console.log('[Init] Setting up worker shim for WKWebView');
    const vsRel = '$vsPath'; // e.g., "min/vs"
    let absVs;
    try { absVs = new URL(vsRel, window.location.href).toString(); }
    catch (_) { absVs = vsRel; }

    // Ensure baseUrl points to the ".../min/" folder (not ".../min/vs")
    const idx = absVs.lastIndexOf('/vs');
    const baseUrl = idx >= 0 ? absVs.substring(0, idx + 1) : absVs; // e.g., ".../min/"

    // Set baseUrl so Monaco can resolve URLs before workers start
    self.MonacoEnvironment = {
      baseUrl: baseUrl,
      getWorkerUrl: function (moduleId, label) {
        // Include the label for better worker resolution and debugging
        const src =
          "self.MonacoEnvironment = { baseUrl: '" + baseUrl + "' };\n" +
          "self.monacoLabel = '" + label + "';\n" +
          "importScripts('" + absVs + "/base/worker/workerMain.js');\n";
        return URL.createObjectURL(new Blob([src], { type: 'application/javascript' }));
      }
    };
    console.log('[Init] Worker shim configured. baseUrl=' + baseUrl);
  })();
</script>
''';
    } else {
      // Linux and other platforms: just set baseUrl
      final baseUrl = vsPath.replaceAll('/vs', '/');
      platformScript = '''
<script>
  // Linux/Other: Set base URL for worker resolution
  console.log('[Init] Setting Monaco base URL');
  self.MonacoEnvironment = { baseUrl: '$baseUrl' };
</script>
''';
    }

    const jsEscapePattern = r'[.*+?^${}()|[\]\\]';

    return '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta http-equiv="X-UA-Compatible" content="IE=edge" />
    <meta
      http-equiv="Content-Security-Policy"
      content="default-src 'self' file: 'unsafe-inline' 'unsafe-eval'; script-src 'self' file: 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'${allowCdnFonts ? ' https:' : ''}; font-src 'self' file: data:${allowCdnFonts ? ' https:' : ''}; img-src 'self' data: blob: file:; worker-src 'self' blob:; connect-src 'self' blob:;"
    />
    <!-- NOTE: connect-src intentionally limits in-page requests to self/blob.
         If you need the embedded JS to call remote APIs directly, add https: to connect-src. -->
    <style>
      html, body, #editor-container {
        width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden;
      }
      
      /* Enable font ligatures in Monaco editor if supported by the font */
      .monaco-editor {
        font-variant-ligatures: contextual;
        -webkit-font-feature-settings: "liga" on, "calt" on;
        font-feature-settings: "liga" on, "calt" on;
      }
    </style>
    ${customCss != null ? '<style id="flutter-monaco-custom">\n$customCss\n</style>' : ''}
    $platformScript
  </head>
  <body>
    <div id="editor-container"></div>

    <script>
      var require = { paths: { vs: '$vsPath' } };
      console.log('[Monaco HTML] Require config set. VS_PATH is: ' + '$vsPath');
    </script>

    ${isWeb ? '''
    <script>
      // Web: Load loader.js dynamically to ensure proper timing in blob URL context
      var loaderScript = document.createElement('script');
      loaderScript.src = '$vsPath/loader.js';
      loaderScript.onload = function() {
        console.log('[Monaco HTML] loader.js dynamically loaded.');
        window._monacoLoaderReady = true;
        if (window._initMonacoWhenReady) window._initMonacoWhenReady();
      };
      loaderScript.onerror = function() {
        console.error('[Monaco HTML] FATAL: loader.js FAILED TO LOAD.');
        if (window.flutterMonacoPostMessage) {
          window.flutterMonacoPostMessage({ event: 'error', message: 'Failed to load Monaco loader.js' });
        } else if (window.flutterChannel) {
          window.flutterChannel.postMessage(JSON.stringify({ event: 'error', message: 'Failed to load Monaco loader.js' }));
        }
      };
      document.head.appendChild(loaderScript);
    </script>
    ''' : '''
    <script src="$vsPath/loader.js"
            onload="console.log('[Monaco HTML] loader.js successfully loaded.')"
            onerror="console.error('[Monaco HTML] FATAL: loader.js FAILED TO LOAD.')"
    ></script>
    '''}

    <script>
      ${isWeb ? '''
      // Web: Wait for loader.js to be ready
      function _initMonaco() {
        if (!window._monacoLoaderReady) {
          window._initMonacoWhenReady = _initMonaco;
          return;
        }
      ''' : '''
      (function _initMonaco() {
      '''}
      console.log('[Monaco HTML] Attempting to require editor.main...');
      try {
        require(
          ['vs/editor/editor.main'],
          function () {
            console.log('[Monaco] SUCCESS: editor.main.js has loaded. Initializing editor...');

            function postMessageToFlutter(message) {
              if (window.flutterMonacoPostMessage) {
                window.flutterMonacoPostMessage(message);
                return;
              }
              if (typeof message !== 'string') {
                message = JSON.stringify(message);
              }
              if (window.flutterChannel && window.flutterChannel.postMessage) {
                window.flutterChannel.postMessage(message);
              } else {
                console.error('[Monaco] Flutter communication channel is not available.');
              }
            }

            monaco.editor.onDidCreateEditor(function (editor) {
              window.editor = editor;

              // Send live statistics updates
              const sendStats = () => {
                if (!editor.getModel() || !editor.getSelection()) return;
                const model = editor.getModel(), selection = editor.getSelection(), selections = editor.getSelections() || [];
                const position = editor.getPosition();
                postMessageToFlutter({
                  event: 'stats',
                  lineCount: model.getLineCount(),
                  charCount: model.getValueLength(),
                  selLines: selection.isEmpty() ? 0 : (selection.endLineNumber - selection.startLineNumber + 1),
                  selChars: selection.isEmpty() ? 0 : model.getValueInRange(selection).length,
                  caretCount: selections.length,
                  language: model.getLanguageId ? model.getLanguageId() : monaco.editor.getModelLanguage(model),
                  cursorLine: position?.lineNumber,
                  cursorColumn: position?.column,
                });
              };
              editor.onDidChangeModelContent(sendStats);
              editor.onDidChangeCursorSelection(sendStats);
              sendStats();

              postMessageToFlutter({ event: 'onEditorReady' });
              console.log('[Monaco] Editor is ready and has sent the onEditorReady event.');
              
              // Set up typed API
              (function () {
                const E = () => window.editor;
                const serialize = (obj) => JSON.stringify(obj);
                

                // Events -> Flutter
                const post = (event, payload) =>
                  postMessageToFlutter({ event, ...payload });

                E().onDidChangeModelContent(e => post('contentChanged', { isFlush: e.isFlush }));
                E().onDidChangeCursorSelection(e => post('selectionChanged', {
                  selection: e.selection && {
                    startLineNumber: e.selection.startLineNumber,
                    startColumn: e.selection.startColumn,
                    endLineNumber: e.selection.endLineNumber,
                    endColumn: e.selection.endColumn
                  }
                }));
                E().onDidFocusEditorWidget(() => post('focus', {}));
                E().onDidBlurEditorWidget(() => post('blur', {}));

                // Typed helpers Flutter will call
                const escapeRegExp = (value) =>
                  (value ?? '').replace(/$jsEscapePattern/g, '\\\\\$&');

                window.flutterMonaco = {

                  // Basic editor operations
                  focus: () => E().focus(),
                  layout: () => { try { E().layout(); } catch (_) {} },
                  // Force focus robustly: wait for visibility, layout, focus editor and hidden textarea
                  forceFocus: () => {
                    try {
                      const ed = E();
                      if (!ed) return;
                      const node = (ed.getDomNode && ed.getDomNode()) || (ed.getContainerDomNode && ed.getContainerDomNode());
                      if (!node) return;
                      const attempt = () => {
                        const rect = node.getBoundingClientRect();
                        if (!rect.width || !rect.height) {
                          // Defer until container has size
                          return requestAnimationFrame(attempt);
                        }
                        // Try to ensure the page/window is active (helps WKWebView on macOS)
                        try { window.focus && window.focus(); } catch (_) {}
                        try {
                          if (document.body && !document.body.hasAttribute('tabindex')) {
                            document.body.setAttribute('tabindex', '-1');
                          }
                          document.body?.focus?.();
                        } catch (_) {}
                        try { ed.layout && ed.layout(); } catch (_) {}
                        try { ed.focus && ed.focus(); } catch (_) {}
                        // Ensure the hidden textarea owns focus for keyboard input
                        try {
                          const ta = node.querySelector('textarea.inputarea');
                          if (ta && document.activeElement !== ta) {
                            ta.focus({ preventScroll: true });
                            // One more tick for WKWebView
                            setTimeout(() => { try { ta.focus({ preventScroll: true }); } catch (_) {} }, 16);
                          }
                        } catch (_) {}
                      };
                      // Defer past any mousedown handlers
                      setTimeout(() => requestAnimationFrame(attempt), 0);
                    } catch (_) {}
                  },
                  getValue: () => E().getValue(),
                  setValue: (v) => E().setValue(v || ''),
                  setTheme: (theme) => monaco.editor.setTheme(theme),
                  setLanguage: (lang) => monaco.editor.setModelLanguage(E().getModel(), lang),
                  updateOptions: (opts) => E().updateOptions(opts),
                  executeAction: (actionId, args) => {
                    const ed = E();
                    const action = ed?.getAction ? ed.getAction(actionId) : null;
                    if (action && typeof action.run === 'function') {
                      try {
                        return action.run(args);
                      } catch (_) {}
                    }
                    return ed.trigger('flutter-bridge', actionId, args);
                  },
                  
                  // Selection
                  getSelection: () => {
                    const s = E().getSelection();
                    return s ? {
                      startLineNumber: s.startLineNumber, startColumn: s.startColumn,
                      endLineNumber: s.endLineNumber, endColumn: s.endColumn
                    } : null;
                  },
                  setSelection: (r) => E().setSelection(r),
                  
                  // Cursor
                  getCursorPosition: () => {
                    const p = E().getPosition();
                    return p ? { lineNumber: p.lineNumber, column: p.column } : null;
                  },
                  setCursorPosition: (line, column) => {
                    E().setPosition({ lineNumber: line, column: column });
                  },
                  
                  // Navigation
                  revealLine: (ln, center) =>
                    center ? E().revealLineInCenter(ln) : E().revealLine(ln),
                  revealRange: (r, center) =>
                    center ? E().revealRangeInCenter(r) : E().revealRange(r),

                  // Line operations
                  getLineCount: () => E().getModel().getLineCount(),
                  getLineContent: (ln) => E().getModel().getLineContent(ln),
                  
                  // Word lookup
                  getWordAtPosition: (line, column) => {
                    const m = E().getModel();
                    if (!m) return null;
                    const w = m.getWordAtPosition(new monaco.Position(line, column));
                    return w ? w.word : null;
                  },

                  // Edits
                  applyEdits: (edits, opts) =>
                    E().getModel().applyEdits(edits || [], opts || {}),

                  // Decorations
                  deltaDecorations: (oldIds, newDecos) =>
                    E().deltaDecorations(oldIds || [], newDecos || []),

                  // Markers (diagnostics)
                  setModelMarkers: (owner, markers) =>
                    monaco.editor.setModelMarkers(E().getModel(), owner || 'flutter', markers || []),

                  // Find & replace (programmatic)
                  findMatches: (q, options, limit) => {
                    const m = E().getModel();
                    if (!m) return [];
                    const isRegex = !!(options && options.isRegex);
                    const matchCase = !!(options && options.matchCase);
                    const wholeWord = !!(options && options.wholeWord);

                    let search = q ?? '';
                    let useRegex = isRegex;
                    if (wholeWord && !isRegex) {
                      search = '\\\\b' + escapeRegExp(String(q ?? '')) + '\\\\b';
                      useRegex = true;
                    }

                    const matches = m.findMatches(
                      search,
                      null,                 // searchScope: null = whole model (FIX: was 'false')
                      useRegex,
                      matchCase,
                      null,
                      false,                // captureMatches
                      limit || 9999
                    );
                    return matches.map(mm => ({ range: mm.range, match: m.getValueInRange(mm.range) }));
                  },

                  replaceMatches: (q, repl, options) => {
                    const m = E().getModel();
                    if (!m) return 0;
                    const isRegex = !!(options && options.isRegex);
                    const matchCase = !!(options && options.matchCase);
                    const wholeWord = !!(options && options.wholeWord);

                    let search = q ?? '';
                    let useRegex = isRegex;
                    if (wholeWord && !isRegex) {
                      search = '\\\\b' + escapeRegExp(String(q ?? '')) + '\\\\b';
                      useRegex = true;
                    }

                    const matches = m.findMatches(
                      search,
                      null,                 // searchScope: null = whole model (FIX: was 'false')
                      useRegex,
                      matchCase,
                      null,
                      false,                // captureMatches
                      9999
                    );
                    const edits = matches.map(mm => ({ range: mm.range, text: repl }));
                    m.pushEditOperations([], edits, () => null);
                    return edits.length;
                  },

                  // View state
                  saveViewState: () => E().saveViewState(),
                  restoreViewState: (s) => E().restoreViewState(s),

                  // Stats
                  getStatistics: () => {
                    const e = E(), m = e.getModel(), s = e.getSelection();
                    const position = e.getPosition(); // FIX: Define position in this scope
                    const selections = e.getSelections() || [];
                    return {
                      lineCount: m ? m.getLineCount() : 0,
                      charCount: m ? m.getValueLength() : 0,
                      selLines: (s && !s.isEmpty()) ? (s.endLineNumber - s.startLineNumber + 1) : 0, // FIX: Return 0 for empty selection
                      selChars: (m && s && !s.isEmpty()) ? m.getValueInRange(s).length : 0,
                      caretCount: selections.length,
                      language: m ? (m.getLanguageId ? m.getLanguageId() : monaco.editor.getModelLanguage(m)) : undefined,
                      cursorLine: position?.lineNumber,
                      cursorColumn: position?.column,
                    };
                  },
                  
                  // Dirty tracking (per-model baselines keyed by URI)
                  _baselines: new Map(),
                  _markBaseline(model) {
                    const m = model || E().getModel();
                    if (m && m.uri) {
                      this._baselines.set(m.uri.toString(), m.getAlternativeVersionId());
                    }
                  },
                  hasUnsavedChanges: () => {
                    const m = E().getModel();
                    if (!m || !m.uri) return false;
                    const uri = m.uri.toString();
                    if (!window.flutterMonaco._baselines.has(uri)) {
                      window.flutterMonaco._markBaseline(m);
                    }
                    return m.getAlternativeVersionId() !== window.flutterMonaco._baselines.get(uri);
                  },
                  markSaved: () => window.flutterMonaco._markBaseline(),

                  // Models
                  createModel: (value, language, uri) =>
                    monaco.editor.createModel(value || '', language || 'plaintext', 
                      uri ? monaco.Uri.parse(uri) : undefined).uri.toString(),
                  setModel: (uri) => {
                    const m = monaco.editor.getModel(monaco.Uri.parse(uri));
                    if (m) E().setModel(m);
                  },
                  disposeModel: (uri) => {
                    const m = monaco.editor.getModel(monaco.Uri.parse(uri));
                    if (m) m.dispose();
                  },
                  listModels: () => monaco.editor.getModels().map(m => m.uri.toString()),
                };

                // Completion bridge: JS stays dumb, Flutter drives the data
                (function () {
                  const completion = {
                    resolvers: Object.create(null),
                    providers: Object.create(null),
                    nextId: 1,
                  };

                  function toIRange(r) {
                    if (!r) return undefined;
                    const sL = r.startLineNumber ?? r.startLine ?? r.from_line ?? r.start ?? 1;
                    const sC = r.startColumn ?? r.startCol ?? r.sc ?? 1;
                    const eL = r.endLineNumber ?? r.endLine ?? r.to_line ?? r.end ?? sL;
                    const eC = r.endColumn ?? r.endCol ?? r.ec ?? sC;
                    return {
                      startLineNumber: sL,
                      startColumn: sC,
                      endLineNumber: eL,
                      endColumn: eC,
                    };
                  }

                  // cfg: { id?: string, languages: string[]|string, triggerCharacters?: string[] }
                  window.flutterMonaco.registerCompletionSource = function (cfg) {
                    const id = cfg?.id || 'flutter_' + completion.nextId++;
                    const langs = Array.isArray(cfg?.languages)
                      ? cfg.languages
                      : [cfg?.languages ?? 'plaintext'];
                    const triggerCharacters = cfg?.triggerCharacters || [];

                    const provider = {
                      triggerCharacters,
                      provideCompletionItems: (model, position, context, token) =>
                        new Promise((resolve) => {
                          const reqId =
                            id + ':' + Date.now() + ':' + Math.random().toString(36).slice(2);
                          completion.resolvers[reqId] = resolve;

                          const lang =
                            (model.getLanguageId && model.getLanguageId()) ||
                            monaco.editor.getModelLanguage(model);
                          const word = model.getWordUntilPosition(position);
                          const defaultRange = {
                            startLineNumber: position.lineNumber,
                            startColumn: word.startColumn,
                            endLineNumber: position.lineNumber,
                            endColumn: word.endColumn,
                          };

                          const payload = {
                            event: 'completionRequest',
                            providerId: id,
                            requestId: reqId,
                            language: lang,
                            uri: model.uri?.toString(),
                            position: {
                              lineNumber: position.lineNumber,
                              column: position.column,
                            },
                            defaultRange,
                            lineText: model.getLineContent(position.lineNumber),
                            triggerKind: context?.triggerKind ?? null,
                            triggerCharacter: context?.triggerCharacter ?? null,
                          };
                          postMessageToFlutter(payload);

                          token?.onCancellationRequested?.(() => {
                            delete completion.resolvers[reqId];
                            try {
                              resolve({ suggestions: [] });
                            } catch (_) {}
                          });
                        }),
                    };

                    const disposables = langs.map((l) =>
                      monaco.languages.registerCompletionItemProvider(l, provider),
                    );
                    completion.providers[id] = { disposables };
                    return id;
                  };

                  window.flutterMonaco.unregisterCompletionSource = function (id) {
                    const p = completion.providers[id];
                    if (p?.disposables) {
                      for (const d of p.disposables) {
                        try {
                          d.dispose();
                        } catch (_) {}
                      }
                    }
                    delete completion.providers[id];
                  };

                  // Flutter -> JS: deliver completion results
                  window.flutterMonaco.complete = function (requestId, payload) {
                    const resolve = completion.resolvers[requestId];
                    if (!resolve) return;
                    try {
                      const items = (payload && payload.suggestions) || [];
                      const mapped = items.map((it) => {
                        let kind = it.kind;
                        if (typeof kind === 'string') {
                          kind = monaco.languages.CompletionItemKind[kind] ??
                            monaco.languages.CompletionItemKind.Text;
                        }
                        let insertTextRules = it.insertTextRules;
                        if (Array.isArray(insertTextRules)) {
                          insertTextRules = insertTextRules.reduce((mask, rule) => {
                            const value = monaco.languages.CompletionItemInsertTextRule[rule];
                            return typeof value === 'number' ? (mask | value) : mask;
                          }, 0);
                        }
                        return {
                          label: it.label,
                          insertText: it.insertText || it.label,
                          kind: kind || monaco.languages.CompletionItemKind.Text,
                          detail: it.detail,
                          documentation: it.documentation,
                          sortText: it.sortText,
                          filterText: it.filterText,
                          commitCharacters: it.commitCharacters,
                          insertTextRules: insertTextRules || undefined,
                          range: toIRange(it.range) || toIRange(payload?.defaultRange),
                        };
                      });
                      resolve({
                        suggestions: mapped,
                        incomplete: !!payload?.isIncomplete,
                      });
                    } finally {
                      delete completion.resolvers[requestId];
                    }
                  };
                })();
              })();
            });

            monaco.editor.create(document.getElementById('editor-container'), {
              value: '// Monaco Editor is ready',
              language: 'markdown',
              theme: 'vs-dark',
              automaticLayout: true,
              wordWrap: 'on',
              padding: { top: 10 },
              minimap: { enabled: false }
            });
          },
          function (error) {
            console.error('[Monaco] FATAL: require() failed to load editor.main.js. Error:', error);
            ${isWeb ? "if (window.flutterMonacoPostMessage) window.flutterMonacoPostMessage({ event: 'error', message: 'Failed to load editor.main: ' + error });" : ''}
          }
        );
      } catch (e) {
        console.error('[Monaco] FATAL: A critical error occurred trying to call require(). Error:', e);
      }
      ${isWeb ? '}; _initMonaco();' : '})();'}
    </script>
  </body>
</html>
''';
  }
}
