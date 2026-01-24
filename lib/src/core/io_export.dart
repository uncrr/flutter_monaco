/// Conditional export that provides `dart:io` types on native platforms
/// and stub implementations on web.
///
/// This abstraction allows [MonacoAssets] to use `File` and `Directory` types
/// in its API without breaking web compilation. On web, the stubs in
/// [io_web.dart] are used instead - these are never actually called at runtime
/// because web code paths are guarded by `kIsWeb` checks.
///
/// See also:
/// - [io_web.dart] for the stub implementations used on web.
/// - [MonacoAssets] which uses these types for asset extraction.
library;

export 'dart:io' if (dart.library.html) 'io_web.dart';
