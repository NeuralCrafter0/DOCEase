import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// Why [AttachmentScanIncomplete] was thrown. Carries no paths or data.
enum AttachmentScanFailure {
  /// No database is open (closed, never opened, or still opening).
  noDatabase,

  /// The last open failed (`DbFailed`); nothing can be read.
  openFailed,

  /// A patient row's `history` is not a JSON list of objects.
  unreadableRow,

  /// A visit's `attachmentPaths` is not a list of strings.
  unreadableAttachmentList,

  /// The `doctor_profile` setting is not a JSON object, or its
  /// `profileImageUrl` is not a string.
  unreadableDoctorProfile,

  /// A stored local path does not map to a key in the open owner's folders
  /// (legacy picker path, another owner's folder, `..`, unknown format).
  /// Only from [AttachmentRefs.referencedKeys] /
  /// `LocalDatabase.referencedAttachmentKeys`.
  unrecognisedPath,

  /// The database read itself failed.
  readFailed,
}

/// The list of referenced attachments could not be built completely. A
/// photo sweep must treat this as "keep everything": never as an empty or
/// partial list. [toString] names only the [reason], never a path, id or
/// patient data.
class AttachmentScanIncomplete implements Exception {
  const AttachmentScanIncomplete(this.reason);
  final AttachmentScanFailure reason;

  @override
  String toString() => 'AttachmentScanIncomplete(${reason.name})';
}

/// Pure helpers shared by the DB scan and the photo sweep, so both sides
/// compare photos the same way. No I/O.
abstract final class AttachmentRefs {
  /// Folder kinds, as in the backend's `LocalPhotoStore`:
  /// `<support>/attachments/<ownerFolder>/<file>` (visit photos) and
  /// `<support>/profile/<ownerFolder>/<file>` (the doctor's photo).
  static const attachmentsFolder = 'attachments';
  static const profileFolder = 'profile';

  /// Setting holding the doctor profile JSON (backend `DoctorProvider`), and
  /// the field in it that references the doctor's photo.
  static const doctorProfileSettingKey = 'doctor_profile';
  static const doctorProfilePhotoField = 'profileImageUrl';

  /// Storage object prefixes the app writes (`AttachmentPolicy`):
  /// `clinical_attachments/{uid}/{patientId}/{file}` and
  /// `doctor_profiles/{uid}/{file}`.
  static const storagePrefixes = ['clinical_attachments', 'doctor_profiles'];

  static final RegExp _ownerHash = RegExp(r'^[0-9a-f]{32}$');
  static final RegExp _scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.\-]*):');

  /// Owner folder name: `sha256(utf8(owner))` hex, first 32 characters.
  /// Same as `LocalPhotoStore.ownerFolderName` and the hash in
  /// `DatabaseHelper.dbFileNameFor`.
  static String ownerFolderNameFor(String owner) =>
      sha256.convert(utf8.encode(owner)).toString().substring(0, 32);

  /// The owner-relative key of a stored photo reference, or null if it is
  /// not inside [ownerFolderName]'s photo folders.
  ///
  /// The key is the folder kind plus the path below the owner folder, e.g.
  /// `attachments/3f2c….jpg` or `profile/avatar_9a1e….png`. It is worked out
  /// from path segments only (the part before `attachments|profile/<owner>`
  /// is ignored), so `/data/user/0/<pkg>/…` and `/data/data/<pkg>/…`, a
  /// symlinked and a resolved app dir, and a relative
  /// `attachments/<owner>/x.jpg` all give the same key.
  ///
  /// `file://` URIs (host empty or `localhost`) are parsed into a path first.
  /// Returns null for: any other URI scheme, `..` or `.` segments (also when
  /// percent-encoded), NUL or backslash, another owner's folder, more than one
  /// `attachments|profile/<32-hex>` pair (ambiguous), or nothing below the
  /// owner folder. The sweep treats null as "not mine, never delete".
  ///
  /// Throws [ArgumentError] if [ownerFolderName] is not 32 lowercase hex
  /// characters (use [ownerFolderNameFor]).
  static String? attachmentKey(String storedPath,
      {required String ownerFolderName}) {
    if (!_ownerHash.hasMatch(ownerFolderName)) {
      throw ArgumentError.value(ownerFolderName, 'ownerFolderName',
          'must be 32 lowercase hex characters (ownerFolderNameFor)');
    }
    var path = storedPath;
    if (path.isEmpty) return null;
    final scheme = _scheme.firstMatch(path)?.group(1)?.toLowerCase();
    if (scheme != null) {
      if (scheme != 'file') return null;
      // Uri.parse removes dot segments, which would hide a `..`: check the
      // raw text first (also percent-encoded dots).
      if (_hasDotSegment(path)) return null;
      final uri = Uri.tryParse(path);
      if (uri == null ||
          (uri.host.isNotEmpty && uri.host != 'localhost') ||
          uri.hasPort ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        return null;
      }
      try {
        // toFilePath refuses an authority, so drop the (empty/localhost) host.
        path = Uri(scheme: 'file', path: uri.path).toFilePath(windows: false);
      } on UnsupportedError {
        return null;
      }
    }
    if (path.contains('\u0000') || path.contains(r'\')) return null;
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.any((s) => s == '..' || s == '.')) return null;
    int? at;
    for (var i = 0; i + 1 < segs.length; i++) {
      if ((segs[i] == attachmentsFolder || segs[i] == profileFolder) &&
          _ownerHash.hasMatch(segs[i + 1])) {
        if (at != null) return null; // ambiguous: never guess
        at = i;
      }
    }
    if (at == null || segs[at + 1] != ownerFolderName || at + 2 >= segs.length) {
      return null;
    }
    return [segs[at], ...segs.sublist(at + 2)].join('/');
  }

  static bool _hasDotSegment(String uriText) {
    var rest = uriText;
    final q = rest.indexOf(RegExp(r'[?#]'));
    if (q >= 0) rest = rest.substring(0, q);
    for (final seg in rest.split('/')) {
      final d = seg.replaceAll(RegExp('%2[eE]'), '.');
      if (d == '.' || d == '..') return true;
    }
    return false;
  }

  /// True only for references that are explicitly not local files:
  /// `http://` / `https://` links and `gs://` URIs with a host, and relative
  /// Firebase Storage object paths under [storagePrefixes] (no `.`/`..`/empty
  /// segments, nothing after the object name). Everything else is treated as
  /// a local path.
  static bool isNonLocalRef(String entry) {
    final scheme = _scheme.firstMatch(entry)?.group(1)?.toLowerCase();
    if (scheme != null) {
      if (scheme != 'http' && scheme != 'https' && scheme != 'gs') return false;
      final uri = Uri.tryParse(entry);
      return uri != null && uri.host.isNotEmpty;
    }
    if (entry.startsWith('/') || entry.contains('\u0000') || entry.contains(r'\')) {
      return false;
    }
    final segs = entry.split('/');
    return segs.length >= 2 &&
        storagePrefixes.contains(segs.first) &&
        !segs.any((s) => s.isEmpty || s == '.' || s == '..');
  }

  /// Every attachment/photo reference, exactly as stored, from patient
  /// `history` column values and the raw `doctor_profile` setting value.
  /// Throws [AttachmentScanIncomplete] instead of skipping anything that
  /// cannot be read. A SQL NULL `history` means no visits (as in
  /// `fetchPatients`). Other visit fields (dates, vitals) are not checked:
  /// they cannot hide a path.
  static Set<String> collectReferencedPaths({
    required Iterable<Object?> historyValues,
    Object? doctorProfileValue,
  }) {
    const row = AttachmentScanIncomplete(AttachmentScanFailure.unreadableRow);
    const list =
        AttachmentScanIncomplete(AttachmentScanFailure.unreadableAttachmentList);
    const profile =
        AttachmentScanIncomplete(AttachmentScanFailure.unreadableDoctorProfile);
    final out = <String>{};
    for (final h in historyValues) {
      if (h == null) continue;
      if (h is! String) throw row;
      final Object? decoded;
      try {
        decoded = jsonDecode(h);
      } on FormatException {
        throw row;
      }
      if (decoded is! List) throw row;
      for (final visit in decoded) {
        if (visit is! Map) throw row;
        final paths = visit['attachmentPaths'];
        if (paths == null) continue;
        if (paths is! List) throw list;
        for (final e in paths) {
          if (e is! String) throw list;
          out.add(e);
        }
      }
    }
    if (doctorProfileValue != null) {
      if (doctorProfileValue is! String) throw profile;
      final Object? decoded;
      try {
        decoded = jsonDecode(doctorProfileValue);
      } on FormatException {
        throw profile;
      }
      if (decoded is! Map) throw profile;
      final photo = decoded[doctorProfilePhotoField];
      if (photo != null) {
        if (photo is! String) throw profile;
        out.add(photo);
      }
    }
    return out;
  }

  /// Keys ([attachmentKey]) for [paths]. Empty strings and [isNonLocalRef]
  /// references are skipped; any other path that gives no key throws
  /// [AttachmentScanIncomplete] (`unrecognisedPath`) rather than being
  /// dropped, since dropping it would make its file look unreferenced.
  static Set<String> referencedKeys(Iterable<String> paths,
      {required String ownerFolderName}) {
    final out = <String>{};
    for (final path in paths) {
      if (path.isEmpty || isNonLocalRef(path)) continue;
      final key = attachmentKey(path, ownerFolderName: ownerFolderName);
      if (key == null) {
        throw const AttachmentScanIncomplete(
            AttachmentScanFailure.unrecognisedPath);
      }
      out.add(key);
    }
    return out;
  }

  // --- swapAttachmentPath support (pure; shared by the helper and fakes) --

  /// The uploader's visit-photo object name rule (backend
  /// `AttachmentPolicy`): `[A-Za-z0-9_-]{1,128}` plus jpg/jpeg/png/webp.
  static final RegExp _storageFileName =
      RegExp(r'^[A-Za-z0-9_-]{1,128}\.(jpg|jpeg|png|webp)$');

  /// True for exactly `clinical_attachments/{uid}/{patientId}/{file}`, the
  /// layout the uploader writes (backend `AttachmentPolicy.isStoragePathFor`):
  /// four segments, [uid] and [patientId] matched exactly, a file name the
  /// Storage rules accept. Anything else (`..`, `.`, empty segments, another
  /// uid or patient, `doctor_profiles/`, a scheme) is false.
  static bool isPatientStoragePath(String path,
      {required String uid, required String patientId}) {
    bool okSeg(String s) =>
        s.isNotEmpty && s != '.' && s != '..' && !s.contains('/');
    if (!okSeg(uid) || !okSeg(patientId)) return false;
    final parts = path.split('/');
    return parts.length == 4 &&
        parts[0] == 'clinical_attachments' &&
        parts[1] == uid &&
        parts[2] == patientId &&
        _storageFileName.hasMatch(parts[3]);
  }

  /// Validates swapAttachmentPath's arguments and returns the visit-photo
  /// key (`attachments/<file>`) of [localPath] in [expectedOwner]'s folder.
  /// Throws [ArgumentError] (naming the parameter, never its value) if
  /// [expectedOwner] or [patientId] is empty, [storagePath] is not
  /// [isPatientStoragePath] for them, or [localPath] has no visit-photo key
  /// for [expectedOwner].
  static String swapKeyFor(
      {required String expectedOwner,
      required String patientId,
      required String localPath,
      required String storagePath}) {
    if (expectedOwner.isEmpty) {
      throw ArgumentError('must not be empty', 'expectedOwner');
    }
    if (patientId.isEmpty) throw ArgumentError('must not be empty', 'patientId');
    if (!isPatientStoragePath(storagePath,
        uid: expectedOwner, patientId: patientId)) {
      throw ArgumentError(
          'must be clinical_attachments/<expectedOwner>/<patientId>/<file>',
          'storagePath');
    }
    final key = localPath.isEmpty || isNonLocalRef(localPath)
        ? null
        : attachmentKey(localPath,
            ownerFolderName: ownerFolderNameFor(expectedOwner));
    if (key == null || !key.startsWith('$attachmentsFolder/')) {
      throw ArgumentError(
          "must be a visit photo in the expected owner's attachments folder",
          'localPath');
    }
    return key;
  }

  /// [historyJson] (a stored `history` value) with every attachment entry
  /// whose own [attachmentKey] equals [key] replaced by [storagePath]; every
  /// other entry, visit and field is kept exactly as stored (key order
  /// included). Entries that cannot be keyed are left as they are. Returns
  /// null when no entry matches. Throws [FormatException] (no data in the
  /// message) if the JSON is not a list of objects whose `attachmentPaths`
  /// is absent, null or a list of strings.
  static String? swapInHistoryJson(String historyJson,
      {required String key,
      required String ownerFolderName,
      required String storagePath}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(historyJson);
    } on FormatException {
      throw const FormatException('history is not JSON');
    }
    if (decoded is! List) throw const FormatException('history is not a list');
    var changed = false;
    final out = <Object?>[];
    for (final visit in decoded) {
      if (visit is! Map) throw const FormatException('visit is not an object');
      final paths = visit['attachmentPaths'];
      if (paths == null) {
        out.add(visit);
        continue;
      }
      if (paths is! List) {
        throw const FormatException('attachmentPaths is not a list');
      }
      var hit = false;
      final next = <Object?>[];
      for (final e in paths) {
        if (e is! String) {
          throw const FormatException('attachment entry is not a string');
        }
        final match = e.isNotEmpty &&
            !isNonLocalRef(e) &&
            attachmentKey(e, ownerFolderName: ownerFolderName) == key;
        next.add(match ? storagePath : e);
        hit = hit || match;
      }
      if (hit) {
        changed = true;
        out.add(Map<String, Object?>.from(visit)..['attachmentPaths'] = next);
      } else {
        out.add(visit);
      }
    }
    return changed ? jsonEncode(out) : null;
  }
}
