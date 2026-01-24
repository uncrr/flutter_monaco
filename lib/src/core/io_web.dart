/// Stub implementations of `dart:io` classes for web platform compatibility.
///
/// These classes mirror the inheritance hierarchy of `dart:io`:
/// - [FileSystemEntity] is the base class
/// - [File] implements [FileSystemEntity]
/// - [Directory] implements [FileSystemEntity]
///
/// This structure ensures type narrowing works correctly (e.g., `if (entity is File)`
/// narrows to `File`) during compilation, even though these stubs are never
/// actually invoked at runtime.
///
/// **Important:** All code paths that use these types are guarded by `kIsWeb`
/// checks in [MonacoAssets]. If any method is called on web, it indicates a
/// missing guard in the calling code.
///
/// **Maintainers:** These stubs must mirror the `dart:io` hierarchy. Reference:
/// - `{FLUTTER_SDK}/bin/cache/dart-sdk/lib/io/file_system_entity.dart`
/// - `{FLUTTER_SDK}/bin/cache/dart-sdk/lib/io/file.dart`
/// - `{FLUTTER_SDK}/bin/cache/dart-sdk/lib/io/directory.dart`
///
/// See also:
/// - [io_export.dart] for the conditional export mechanism.
/// - [MonacoAssets] for the actual usage of these types.
library;

/// Stub for `dart:io` [FileSystemEntity] - base class for [File] and [Directory].
///
/// Mirrors the `dart:io` hierarchy so type narrowing works during compilation.
class FileSystemEntity {
  /// The entity path (unused on web).
  final String path;

  /// Creates a stub file system entity reference.
  FileSystemEntity(this.path);
}

/// Stub for `dart:io` [File] - implements [FileSystemEntity].
///
/// All methods return safe defaults but should never be called in production.
class File implements FileSystemEntity {
  @override
  final String path;

  /// Creates a stub file reference.
  File(this.path);

  /// Always returns `false` on web.
  Future<bool> exists() async => false;

  /// Always returns `false` on web.
  bool existsSync() => false;

  /// Always returns an empty string on web.
  Future<String> readAsString() async => '';

  /// No-op on web.
  Future<void> writeAsString(String contents) async {}

  /// No-op on web.
  Future<void> writeAsBytes(List<int> bytes) async {}

  /// Always returns `0` on web.
  Future<int> length() async => 0;

  /// Returns a stub [Directory] on web.
  Directory get parent => Directory('');
}

/// Stub for `dart:io` [Directory] - implements [FileSystemEntity].
///
/// All methods return safe defaults but should never be called in production.
class Directory implements FileSystemEntity {
  @override
  final String path;

  /// Creates a stub directory reference.
  Directory(this.path);

  /// Always returns `false` on web.
  Future<bool> exists() async => false;

  /// Always returns `false` on web.
  bool existsSync() => false;

  /// No-op on web.
  Future<void> create({bool recursive = false}) async {}

  /// No-op on web.
  Future<void> delete({bool recursive = false}) async {}

  /// Yields nothing on web.
  Stream<FileSystemEntity> list({bool recursive = false}) async* {}

  /// Returns a stub [File] on web.
  File childFile(String name) => File('$path/$name');
}
