import 'dart:io';

/// Image types the Storage rules accept (firebase/storage.rules). Anything
/// else is rejected in the app before an upload is attempted.
enum UploadImageType {
  jpeg('image/jpeg', 'jpg'),
  png('image/png', 'png'),
  webp('image/webp', 'webp');

  const UploadImageType(this.contentType, this.fileExtension);

  /// Sent as SettableMetadata.contentType on upload.
  final String contentType;

  /// Extension of the uploaded object's name (follows the content type).
  final String fileExtension;

  /// .jpg and .jpeg map to JPEG, .png to PNG, .webp to WebP (case
  /// insensitive). Returns null for anything else (HEIC, GIF, no extension).
  static UploadImageType? forPath(String path) {
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return null;
    switch (name.substring(dot + 1).toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return UploadImageType.jpeg;
      case 'png':
        return UploadImageType.png;
      case 'webp':
        return UploadImageType.webp;
      default:
        return null;
    }
  }
}

/// Thrown before anything is uploaded or written when a picked file cannot
/// be uploaded. [message] is safe to show to the doctor (it names the file,
/// never patient data).
class UnsupportedAttachmentException implements Exception {
  UnsupportedAttachmentException(this.fileName, this.reason);

  final String fileName;
  final AttachmentRejection reason;

  String get message => switch (reason) {
        AttachmentRejection.unsupportedType =>
          '"$fileName" can\'t be uploaded. Only JPEG, PNG or WebP images are supported.',
        AttachmentRejection.tooLarge =>
          '"$fileName" is too large to upload.',
        AttachmentRejection.empty => '"$fileName" is empty.',
        AttachmentRejection.missing => '"$fileName" could not be found on this device.',
        AttachmentRejection.notAFile =>
          '"$fileName" is not a file picked on this device.',
      };

  @override
  String toString() => 'UnsupportedAttachmentException(${reason.name})';
}

enum AttachmentRejection { unsupportedType, tooLarge, empty, missing, notAFile }

/// What an entry in VisitRecord.attachmentPaths is.
enum AttachmentEntryKind {
  /// `clinical_attachments/{uid}/{patientId}/{file}`: the format written
  /// from now on. Displayed through the Storage SDK, so rules apply.
  storagePath,

  /// Legacy tokenized download URL from this project's bucket pointing into
  /// the same doctor's and patient's folder. Kept and displayed; never
  /// written for new uploads.
  legacyDownloadUrl,

  /// An absolute local file path. Only uploadable when it was picked in the
  /// current session (PatientProvider tracks that); a local path read back
  /// from Firestore or the local DB is never uploaded.
  localFile,

  /// Anything else (foreign URLs, relative paths, `..`, other doctors'
  /// folders). Never uploaded, displayed or written to Firestore.
  invalid,
}

abstract final class AttachmentPolicy {
  static const int maxAttachmentBytes = 10 * 1024 * 1024; // 10 MiB
  static const int maxAvatarBytes = 5 * 1024 * 1024; // 5 MiB

  static const String storageHost = 'firebasestorage.googleapis.com';
  static final RegExp _fileName =
      RegExp(r'^[A-Za-z0-9_-]{1,128}\.(jpg|jpeg|png|webp)$');

  static String attachmentFolder(String uid, String patientId) =>
      'clinical_attachments/$uid/$patientId';

  static String avatarFolder(String uid) => 'doctor_profiles/$uid';

  /// True for exactly `clinical_attachments/{uid}/{patientId}/{file}` with a
  /// file name the Storage rules accept.
  static bool isStoragePathFor(String entry, String uid, String patientId) {
    final parts = entry.split('/');
    return parts.length == 4 &&
        parts[0] == 'clinical_attachments' &&
        parts[1] == uid &&
        parts[2] == patientId &&
        _fileName.hasMatch(parts[3]);
  }

  /// True for `https://firebasestorage.googleapis.com/v0/b/{bucket}/o/<path>`
  /// where `<path>` passes [isStoragePathFor]. When [bucket] is given the
  /// URL must point into that bucket.
  static bool isLegacyDownloadUrlFor(String entry, String uid, String patientId,
      {String? bucket}) {
    final uri = Uri.tryParse(entry);
    if (uri == null || uri.scheme != 'https' || uri.host != storageHost) {
      return false;
    }
    if (uri.hasPort && uri.port != 443) return false;
    final seg = uri.pathSegments; // percent-decoded: %2F becomes '/'
    if (seg.length != 5 || seg[0] != 'v0' || seg[1] != 'b' || seg[3] != 'o') {
      return false;
    }
    if (bucket != null && bucket.isNotEmpty && seg[2] != bucket) return false;
    return isStoragePathFor(seg[4], uid, patientId);
  }

  /// An absolute path with no `..` segments and no URI scheme.
  static bool isLocalFilePath(String entry) {
    if (!entry.startsWith('/') || entry.contains('\u0000')) return false;
    return !entry.split('/').any((s) => s == '..' || s == '.');
  }

  static AttachmentEntryKind classify(String entry, String uid, String patientId,
      {String? bucket}) {
    if (isStoragePathFor(entry, uid, patientId)) return AttachmentEntryKind.storagePath;
    if (isLegacyDownloadUrlFor(entry, uid, patientId, bucket: bucket)) {
      return AttachmentEntryKind.legacyDownloadUrl;
    }
    if (isLocalFilePath(entry)) return AttachmentEntryKind.localFile;
    return AttachmentEntryKind.invalid;
  }

  /// Whether [entry] may be written to Firestore for this doctor and patient.
  static bool isCloudSafe(String entry, String uid, String patientId, {String? bucket}) {
    final kind = classify(entry, uid, patientId, bucket: bucket);
    return kind == AttachmentEntryKind.storagePath ||
        kind == AttachmentEntryKind.legacyDownloadUrl;
  }

  static String displayName(String path) => path.split('/').last;

  /// Checks a freshly picked local file before any upload: supported
  /// extension, exists, not empty, within [maxBytes]. Throws
  /// [UnsupportedAttachmentException] naming the file.
  static Future<UploadImageType> validateLocalImage(String path,
      {required int maxBytes}) async {
    final name = displayName(path);
    if (!isLocalFilePath(path)) {
      throw UnsupportedAttachmentException(name, AttachmentRejection.notAFile);
    }
    final type = UploadImageType.forPath(path);
    if (type == null) {
      throw UnsupportedAttachmentException(name, AttachmentRejection.unsupportedType);
    }
    final file = File(path);
    if (!await file.exists()) {
      throw UnsupportedAttachmentException(name, AttachmentRejection.missing);
    }
    final size = await file.length();
    if (size <= 0) throw UnsupportedAttachmentException(name, AttachmentRejection.empty);
    if (size > maxBytes) {
      throw UnsupportedAttachmentException(name, AttachmentRejection.tooLarge);
    }
    return type;
  }
}
