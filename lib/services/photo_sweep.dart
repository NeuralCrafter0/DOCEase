import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../providers/database_helper.dart' show DatabaseHelper;
import '../providers/local_database.dart';
import 'attachment_keys.dart';
import 'local_photo_store.dart';
import 'log_codes.dart';

/// Outcome of one sweep (counts only; also what is logged).
class PhotoSweepResult {
  const PhotoSweepResult.skipped(this.reason)
      : ran = false, scanned = 0, removed = 0, referenced = 0, recent = 0, other = 0;
  const PhotoSweepResult({
    required this.scanned,
    required this.removed,
    required this.referenced,
    required this.recent,
    required this.other,
  })  : ran = true,
        reason = null;

  final bool ran;

  /// Why nothing was swept (a code, never a path), e.g. `no_open_db`.
  final String? reason;
  final int scanned;
  final int removed;
  final int referenced;
  final int recent;

  /// Not deleted for any other reason: not a regular file (directory,
  /// symlink), no key for this owner, or a refused delete.
  final int other;
}

/// Startup sweep: deletes visit photos in the open owner's
/// `attachments/<ownerHash>/` folder that no visit references any more
/// (security's #8 review: deleted patients/visits must not leave photos on
/// disk, also after a crash between the DB delete and the file delete).
///
/// Rules (all fail closed):
/// 1. Only for the owner whose database is open (checked before, after
///    reading the references and before every delete). The references come
///    from `referencedAttachmentKeys()` (#10), which throws instead of
///    returning a partial set when no DB is open, any row fails to parse or
///    any local path cannot be keyed; then the whole sweep is skipped.
///    Dirty (unsynced) rows count as referenced.
/// 2. Only `attachments/<ownerHash>/` of that owner; never `profile/`,
///    another owner's folder, or anything below a sub-directory. Only
///    regular files (`followLinks: false`); symlinks and directories are
///    never followed or deleted. Each walked file goes through the same
///    `attachmentKey` as the stored paths: null means "not mine, never
///    delete". The delete itself re-checks the resolved path
///    ([LocalPhotoStore.deleteOwnedVisitFile]).
/// 3. Files changed in the last [grace] are kept, so a photo picked and
///    copied but not yet saved is not eaten. The newer of the modified and
///    status-change times counts (a copy can keep the source's mtime).
/// 4. Logs carry counts and codes only, never a path or file name.
class PhotoSweep {
  PhotoSweep({
    required LocalDatabase db,
    required ReferencedKeysFn referencedKeys,
    required AttachmentKeyFn attachmentKey,
    LocalPhotoStore? photos,
    this.grace = defaultGrace,
    DateTime Function()? now,
  })  : _db = db,
        _referencedKeys = referencedKeys,
        _attachmentKey = attachmentKey,
        _photosOverride = photos,
        _now = now ?? DateTime.now;

  /// The app's sweep: [DatabaseHelper.instance], [LocalPhotoStore.instance]
  /// and the attachment keys from [AttachmentKeys.forDatabase].
  factory PhotoSweep.forApp() {
    final db = DatabaseHelper.instance;
    final (key, referenced) = AttachmentKeys.forDatabase(db);
    return PhotoSweep(db: db, referencedKeys: referenced, attachmentKey: key);
  }

  static const hookName = 'photo_sweep';
  static const defaultGrace = Duration(minutes: 10);

  /// Registers the app's sweep with [StartupHooks] (main.dart, before the
  /// start-mode checks, so dev mode and normal mode both run it).
  static Future<void> startupHook() => PhotoSweep.forApp().runWhenOpen();

  final LocalDatabase _db;
  final ReferencedKeysFn _referencedKeys;
  final AttachmentKeyFn _attachmentKey;
  final LocalPhotoStore? _photosOverride;
  LocalPhotoStore get _photos => _photosOverride ?? LocalPhotoStore.instance;
  final Duration grace;
  final DateTime Function() _now;

  /// Waits for the first database to be ready (dev mode: `local`; normal
  /// mode: after sign-in), then sweeps that owner once.
  Future<PhotoSweepResult> runWhenOpen() async {
    final ready = await _db.states.firstWhere((s) => s is DbReady, orElse: () => const DbClosed());
    final owner = ready.uid;
    if (owner == null) return const PhotoSweepResult.skipped('no_open_db');
    return sweep(owner);
  }

  /// Sweeps [owner]'s visit folder. Never throws.
  Future<PhotoSweepResult> sweep(String owner) async {
    try {
      return _log(await _sweep(owner));
    } catch (e) {
      return _log(PhotoSweepResult.skipped(errorCode(e)));
    }
  }

  Future<PhotoSweepResult> _sweep(String owner) async {
    if (_db.openUid != owner) return const PhotoSweepResult.skipped('no_open_db');
    final Set<String> referenced;
    try {
      referenced = await _referencedKeys();
    } catch (e) {
      // TODO(#10): catch #10's typed exception by name once it is posted;
      // until then any exception skips the whole sweep.
      return PhotoSweepResult.skipped('references_${e is AttachmentReferencesUnavailable ? e.code : errorCode(e)}');
    }
    if (_db.openUid != owner) return const PhotoSweepResult.skipped('owner_changed');

    await _photos.init();
    final dir = _photos.visitFolderFor(owner);
    if (dir == null) return const PhotoSweepResult.skipped('no_folder');
    final dirType = await FileSystemEntity.type(dir, followLinks: false);
    if (dirType == FileSystemEntityType.notFound) {
      return const PhotoSweepResult(scanned: 0, removed: 0, referenced: 0, recent: 0, other: 0);
    }
    // A symlinked owner folder is never listed through.
    if (dirType != FileSystemEntityType.directory) return const PhotoSweepResult.skipped('folder_not_directory');

    final folder = LocalPhotoStore.ownerFolderName(owner);
    final cutoff = _now().subtract(grace);
    var scanned = 0, removed = 0, kept = 0, recent = 0, other = 0;
    await for (final entity in Directory(dir).list(followLinks: false)) {
      scanned++;
      final path = entity.path;
      if (await FileSystemEntity.type(path, followLinks: false) != FileSystemEntityType.file) {
        other++;
        continue;
      }
      final key = _attachmentKey(path, ownerFolderName: folder);
      if (key == null || !key.startsWith('${LocalPhotoStore.attachmentsFolder}/')) {
        other++; // not mine: never delete
        continue;
      }
      if (referenced.contains(key)) {
        kept++;
        continue;
      }
      final stat = await FileStat.stat(path);
      final changed = stat.modified.isAfter(stat.changed) ? stat.modified : stat.changed;
      if (changed.isAfter(cutoff)) {
        recent++;
        continue;
      }
      if (_db.openUid != owner) {
        return PhotoSweepResult(scanned: scanned, removed: removed, referenced: kept, recent: recent, other: other);
      }
      if (await _photos.deleteOwnedVisitFile(path, owner: owner)) {
        removed++;
      } else {
        other++;
      }
    }
    return PhotoSweepResult(scanned: scanned, removed: removed, referenced: kept, recent: recent, other: other);
  }

  static PhotoSweepResult _log(PhotoSweepResult r) {
    if (!r.ran) {
      debugPrint('Photos: sweep skipped (${r.reason})');
    } else {
      debugPrint('Photos: sweep removed ${r.removed} of ${r.scanned} '
          '(kept ${r.referenced} referenced, ${r.recent} recent, ${r.other} other)');
    }
    return r;
  }
}
