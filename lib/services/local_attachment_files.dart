import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'log_codes.dart';

/// Deletes the on-device copies of picked visit photos (PHI that lives
/// outside the encrypted DB) without ever touching anything else.
///
/// A file is deleted only when, after resolving symlinks, it is a regular
/// file (not a link or directory) strictly inside one of the app's own
/// directories:
///  - the temporary/cache directory,
///  - the application support directory,
///  - the picked-photo directory `<app documents>/attachments`, where the
///    photo picker (AttachmentProcessor.toJpegFile, PR #8) writes its
///    `<uuid>.jpg` copies. Only that subfolder, not the whole documents
///    directory.
/// Anything else (gallery originals, shared storage, other app folders,
/// relative paths, URLs) is never deleted.
class LocalAttachmentFiles {
  LocalAttachmentFiles({
    Future<List<Directory>> Function()? appRoots,
    Future<Directory?> Function()? pickedPhotoDirectory,
  })  : _appRoots = appRoots ?? _defaultAppRoots,
        _pickedPhotoDirectory = pickedPhotoDirectory ?? defaultPickedPhotoDirectory;

  /// Subfolder of app documents used by the photo picker (PR #8).
  static const pickedPhotoSubdir = 'attachments';

  final Future<List<Directory>> Function() _appRoots;
  final Future<Directory?> Function() _pickedPhotoDirectory;

  static Future<Directory?> defaultPickedPhotoDirectory() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      return Directory(p.join(docs.path, pickedPhotoSubdir));
    } catch (_) {
      return null; // no path_provider (plain unit tests): nothing allowed
    }
  }

  static Future<List<Directory>> _defaultAppRoots() async {
    final out = <Directory>[];
    for (final get in <Future<Directory> Function()>[
      getTemporaryDirectory,
      getApplicationCacheDirectory,
      getApplicationSupportDirectory,
    ]) {
      try {
        out.add(await get());
      } catch (_) {
        // Not available on this platform: that root is simply not allowed.
      }
    }
    return out;
  }

  /// The canonical (symlink-resolved) allowed directories. Roots that don't
  /// exist or resolve to the filesystem root are dropped.
  Future<List<String>> _allowedRoots() async {
    final dirs = <Directory>[
      ...await _appRoots(),
      if (await _pickedPhotoDirectory() case final Directory d) d,
    ];
    final out = <String>[];
    for (final d in dirs) {
      if (!p.isAbsolute(d.path)) continue;
      try {
        final real = p.normalize(await d.resolveSymbolicLinks());
        if (real == p.rootPrefix(real)) continue; // never "/"
        out.add(real);
      } catch (_) {
        // Doesn't exist yet: nothing in it to delete.
      }
    }
    return out;
  }

  /// Whether [path] may be deleted by this app (see the class doc).
  Future<bool> isAppOwned(String path) async {
    if (path.isEmpty || path.contains('://') || !p.isAbsolute(path)) return false;
    // A link (even one pointing into an allowed dir) is never followed.
    if (FileSystemEntity.typeSync(path, followLinks: false) != FileSystemEntityType.file) {
      return false;
    }
    final String real;
    try {
      real = p.normalize(await File(path).resolveSymbolicLinks());
    } catch (_) {
      return false;
    }
    for (final root in await _allowedRoots()) {
      if (p.isWithin(root, real)) return true;
    }
    return false;
  }

  /// Deletes [path] if [isAppOwned]. Returns true when it was deleted.
  /// Never throws.
  Future<bool> deleteIfAppOwned(String path) async {
    try {
      if (!await isAppOwned(path)) return false;
      await File(path).delete();
      return true;
    } catch (e) {
      debugPrint('Local attachment delete failed: ${errorCode(e)}');
      return false;
    }
  }

  /// Deletes every leftover picked photo (`*.jpg`/`*.jpeg` regular files)
  /// directly inside the picked-photo directory. Used on sign-out and
  /// account switch. Returns the number deleted. Never throws.
  Future<int> purgePickedPhotos() async {
    var deleted = 0;
    try {
      final dir = await _pickedPhotoDirectory();
      if (dir == null || !await dir.exists()) return 0;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final ext = p.extension(e.path).toLowerCase();
        if (ext != '.jpg' && ext != '.jpeg') continue;
        if (await deleteIfAppOwned(e.path)) deleted++;
      }
    } catch (e) {
      debugPrint('Picked-photo cleanup failed: ${errorCode(e)}');
    }
    return deleted;
  }
}
