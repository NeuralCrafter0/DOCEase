import '../providers/local_database.dart';
import 'local_photo_store.dart';

/// Seam for the DB engineer's attachment-key API (PR #10, security's #8
/// review). Photo cleanup compares owner-relative keys, never raw paths, so
/// `/data/user/0/…` and `/data/data/…` (or an iOS container that moved after
/// an update) name the same photo.
///
/// #10 adds:
///
/// ```dart
/// // pure helper
/// String? attachmentKey(String storedPath, {required String ownerFolderName});
/// // on LocalDatabase; fails closed (typed exception, never a partial set)
/// Future<Set<String>> referencedAttachmentKeys();
/// ```
///
/// Until that lands, [AttachmentKeys.forDatabase] wires the interim versions
/// below. Swapping is one line each: `attachmentKey: attachmentKey` and
/// `referencedKeys: db.referencedAttachmentKeys`.
typedef AttachmentKeyFn = String? Function(String storedPath, {required String ownerFolderName});

/// Every key the open owner's database references (patients and visits,
/// dirty rows included). Throws, never returns a partial set, when no
/// database is open or any row fails to parse.
typedef ReferencedKeysFn = Future<Set<String>> Function();

/// Thrown by [AttachmentKeys.interimReferencedKeys]. Carries a code only.
class AttachmentReferencesUnavailable implements Exception {
  const AttachmentReferencesUnavailable(this.code);

  /// `no_open_db`, `owner_changed`, `parse_error` or `unkeyable_path`.
  final String code;

  @override
  String toString() => 'AttachmentReferencesUnavailable($code)';
}

abstract final class AttachmentKeys {
  /// The pair the app uses for the open [db].
  /// TODO(#10): `(attachmentKey, db.referencedAttachmentKeys)` once #10 lands.
  static (AttachmentKeyFn, ReferencedKeysFn) forDatabase(LocalDatabase db) =>
      (interimAttachmentKey, () => interimReferencedKeys(db, interimAttachmentKey));

  /// Interim stand-in for #10's `attachmentKey`, same contract: the
  /// owner-relative key `<root>/<file>` (root `attachments` or `profile`) of
  /// a path whose last segments are `<root>/<ownerFolderName>/<file>`, built
  /// from path segments only (no file-system access). Null for `.` or `..`
  /// segments and anything outside that owner's folders: null means "not
  /// this owner's photo, never delete".
  static String? interimAttachmentKey(String storedPath, {required String ownerFolderName}) {
    final path = _localPath(storedPath);
    if (path == null || path.isEmpty || ownerFolderName.isEmpty || path.contains('\\')) return null;
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.any((s) => s == '.' || s == '..')) return null;
    if (segs.length < 3) return null;
    final root = segs[segs.length - 3];
    if (segs[segs.length - 2] != ownerFolderName) return null;
    if (root != LocalPhotoStore.attachmentsFolder && root != LocalPhotoStore.profileFolder) return null;
    return '$root/${segs.last}';
  }

  /// A `file://` URI as a path; other entries unchanged. Null if the URI
  /// cannot be parsed.
  static String? _localPath(String entry) {
    if (!entry.startsWith('file://')) return entry;
    try {
      return Uri.parse(entry).toFilePath(windows: false);
    } catch (_) {
      return null;
    }
  }

  /// Entries that are not files on the phone: web links and Firebase
  /// Storage paths (`clinical_attachments/…`, `gs://…`). Skipped, not keyed.
  static bool isRemoteEntry(String entry) {
    final e = entry.toLowerCase();
    return e.startsWith('http://') ||
        e.startsWith('https://') ||
        e.startsWith('gs://') ||
        entry.startsWith('clinical_attachments/');
  }

  /// Interim stand-in for #10's `referencedAttachmentKeys()`, built on
  /// [LocalDatabase.fetchPatients] (which returns every row, dirty ones
  /// included). Fails closed like #10's: throws
  /// [AttachmentReferencesUnavailable] when no database is open, the open
  /// owner changed during the read, any patient or visit failed to parse,
  /// or any non-empty local path cannot be keyed (another owner's folder,
  /// a picker temp file, `..`). Only web links and Storage paths are
  /// skipped.
  static Future<Set<String>> interimReferencedKeys(LocalDatabase db, AttachmentKeyFn key) async {
    final owner = db.openUid;
    if (owner == null) throw const AttachmentReferencesUnavailable('no_open_db');
    final patients = await db.fetchPatients();
    if (db.openUid != owner) throw const AttachmentReferencesUnavailable('owner_changed');
    final folder = LocalPhotoStore.ownerFolderName(owner);
    final keys = <String>{};
    for (final patient in patients) {
      if (patient.hasParseErrors) throw const AttachmentReferencesUnavailable('parse_error');
      for (final r in patient.history) {
        for (final entry in r.attachmentPaths) {
          if (entry.trim().isEmpty || isRemoteEntry(entry)) continue;
          final k = key(entry, ownerFolderName: folder);
          if (k == null) throw const AttachmentReferencesUnavailable('unkeyable_path');
          keys.add(k);
        }
      }
    }
    return keys;
  }
}
