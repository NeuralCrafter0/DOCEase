import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Marks a directory as excluded from device backups.
typedef BackupExcluder = Future<void> Function(String directoryPath);

/// Where one owner's (one doctor's) processed visit photos are kept:
/// `<base>/attachments/<ownerHash>/<uuid>.jpg`, where `<ownerHash>` is
/// `sha256(ownerId)` hex, first 32 characters, so the uid is not on disk.
///
/// This is the same layout and hash as PR #13's `LocalPhotoStore`
/// (`visitFolderFor(owner)`) and the encrypted DB file name
/// (`DatabaseHelper.dbFileNameFor`), so photos picked here and photos kept
/// by dev mode land in the same folder for the same owner.
///
/// The base defaults to the app support directory, which is app-private and
/// not the backed-up Documents folder. On Android that is `files/`, which
/// the backup rules from PR #2 exclude. On iOS the `attachments` folder is
/// excluded from iCloud and computer backups through the
/// `docease/backup_exclusion` channel (registered by PR #10's AppDelegate).
///
/// Files are only deleted when their visit or patient is deleted (and an
/// unsaved photo when the doctor removes it or leaves without saving).
/// Saving or uploading never deletes them. [deleteOwned] only touches files
/// inside this owner's folder.
class AttachmentStorage {
  AttachmentStorage({
    required this.ownerId,
    Future<Directory> Function()? baseDirectory,
    BackupExcluder? excludeFromBackup,
  })  : _baseDirectory = baseDirectory ?? getApplicationSupportDirectory,
        _excludeFromBackup = excludeFromBackup ?? defaultBackupExcluder {
    if (!isValidOwnerId(ownerId)) {
      throw ArgumentError.value(ownerId, 'ownerId', 'must not be empty');
    }
  }

  static const folder = 'attachments';

  /// Owner of the photos being picked or deleted now. Defaults to the
  /// signed-in Firebase user. Other sign-in modes (for example dev mode)
  /// can replace it without changing this file.
  static String? Function() currentOwnerId = _firebaseUid;

  /// Storage for [currentOwnerId], or null when nobody is signed in.
  static AttachmentStorage? forCurrentOwner() {
    final String? id;
    try {
      id = currentOwnerId();
    } catch (_) {
      return null;
    }
    if (id == null || !isValidOwnerId(id)) return null;
    return AttachmentStorage(ownerId: id);
  }

  /// Any non-empty owner: the folder name is a hash, so it cannot escape.
  static bool isValidOwnerId(String id) => id.isNotEmpty;

  /// Folder name for [owner]: `sha256(owner)` hex, first 32 characters
  /// (as `LocalPhotoStore.ownerFolderName` in PR #13).
  static String ownerFolderName(String owner) => sha256.convert(utf8.encode(owner)).toString().substring(0, 32);

  static String? _firebaseUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid;
    } catch (_) {
      return null;
    }
  }

  static const _backupChannel = MethodChannel('docease/backup_exclusion');

  /// iOS: sets NSURLIsExcludedFromBackupKey on the folder (covers its
  /// contents). Android: nothing to do here (backup rules exclude `files/`).
  static Future<void> defaultBackupExcluder(String directoryPath) async {
    if (!Platform.isIOS) return;
    await _backupChannel.invokeMethod<void>('excludeFromBackup', {'path': directoryPath});
  }

  /// Folders already excluded in this run (the flag persists on disk).
  static final Set<String> _excluded = {};

  @visibleForTesting
  static void resetExclusionCache() => _excluded.clear();

  final String ownerId;
  final Future<Directory> Function() _baseDirectory;
  final BackupExcluder _excludeFromBackup;

  String? _base;

  /// The base folder, created and with symlinks resolved (iOS /var vs
  /// /private/var), as `LocalPhotoStore.init` does.
  Future<String> _rootPath() async {
    if (_base == null) {
      final dir = await _baseDirectory();
      await dir.create(recursive: true);
      _base = p.normalize(await dir.resolveSymbolicLinks());
    }
    return p.join(_base!, folder);
  }

  Future<String> _ownerPath() async => p.join(await _rootPath(), ownerFolderName(ownerId));

  /// This owner's folder, created if needed. Each run asks once for the
  /// `attachments` folder to be excluded from backup. If that fails (for
  /// example a build without the native channel), photos are still kept and
  /// the next call tries again. The log line never contains a path.
  Future<Directory> directory() async {
    final root = await _rootPath();
    final dir = Directory(await _ownerPath());
    await dir.create(recursive: true);
    if (!_excluded.contains(root)) {
      try {
        await _excludeFromBackup(root);
        _excluded.add(root);
      } on MissingPluginException {
        debugPrint('Attachments: backup exclusion is not available in this build');
      } on PlatformException catch (e) {
        debugPrint('Attachments: backup exclusion failed (${e.code})');
      }
    }
    return dir;
  }

  /// Whether [path] is a file inside this owner's folder (lexical check
  /// after normalising, so `..` cannot escape).
  Future<bool> owns(String path) async {
    if (!p.isAbsolute(path)) return false;
    return p.isWithin(await _ownerPath(), p.normalize(path));
  }

  /// Deletes the files in [paths] that are inside this owner's folder, also
  /// after resolving symlinks. Other entries (Storage paths, URLs, other
  /// owners' or outside files) are ignored. Never throws. Returns how many
  /// files were deleted.
  Future<int> deleteOwned(Iterable<String> paths) async {
    var deleted = 0;
    final String dir;
    try {
      dir = await _ownerPath();
    } catch (_) {
      return 0;
    }
    String? realDir;
    for (final path in paths.toSet()) {
      try {
        if (!p.isAbsolute(path) || !p.isWithin(dir, p.normalize(path))) continue;
        final file = File(path);
        if (!await file.exists()) continue;
        realDir ??= await Directory(dir).resolveSymbolicLinks();
        if (!p.isWithin(realDir, await file.resolveSymbolicLinks())) continue;
        await file.delete();
        deleted++;
      } catch (_) {
        // Leave it; nothing else to do from the UI.
      }
    }
    return deleted;
  }
}

/// Local photo files referenced by [paths] (not URLs or Storage paths).
Iterable<String> localAttachmentPaths(Iterable<String> paths) => paths.where((e) => p.isAbsolute(e) && !e.contains('://'));

/// Runs [delete] (a visit or patient delete) and then, only if it finished
/// without an error, deletes the local photo files among [attachmentPaths]
/// that are in the current owner's folder. [attachmentPaths] is copied
/// before [delete] starts, since deleting changes the patient's history.
Future<void> deleteWithLocalAttachments(
  Iterable<String> attachmentPaths,
  Future<void> Function() delete, {
  AttachmentStorage? storage,
}) async {
  final local = localAttachmentPaths(attachmentPaths).toList();
  await delete();
  if (local.isEmpty) return;
  await (storage ?? AttachmentStorage.forCurrentOwner())?.deleteOwned(local);
}
