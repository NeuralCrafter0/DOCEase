import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'attachments.dart';

/// Photos kept on the phone (dev mode: no Storage upload).
///
/// Layout, inside the app support directory (app-private; the same folder
/// PR #8 moves picked visit photos to):
///   `<support>/attachments/<uuid>.<ext>`  visit photos
///   `<support>/profile/avatar_<uuid>.<ext>`  the doctor's photo
///
/// Only files inside those two folders are ever shown from disk or deleted.
class LocalPhotoStore {
  LocalPhotoStore({Future<Directory> Function()? supportDir})
      : _supportDir = supportDir ?? getApplicationSupportDirectory;

  /// The app-wide store (main.dart calls [init] before runApp in dev mode).
  static LocalPhotoStore instance = LocalPhotoStore();

  static const attachmentsFolder = 'attachments';
  static const profileFolder = 'profile';

  final Future<Directory> Function() _supportDir;
  String? _support;

  /// Resolves the support directory (canonical path). Safe to call again.
  Future<void> init() async {
    if (_support != null) return;
    final dir = await _supportDir();
    await dir.create(recursive: true);
    _support = p.normalize(await dir.resolveSymbolicLinks());
  }

  String? get supportPath => _support;

  String? _folder(String name) => _support == null ? null : p.join(_support!, name);

  /// Whether [path] is a file inside one of the photo folders (lexical
  /// check after normalising, so `..` cannot escape). False before [init].
  bool isAppPhoto(String path) {
    if (!p.isAbsolute(path)) return false;
    final n = p.normalize(path);
    for (final f in [_folder(attachmentsFolder), _folder(profileFolder)]) {
      if (f != null && p.isWithin(f, n)) return true;
    }
    return false;
  }

  /// Keeps a picked visit photo: returns [source] if it already is in the
  /// attachments folder, otherwise copies it there under a new name and
  /// returns the copy's path.
  Future<String> keepVisitPhoto(String source, UploadImageType type) =>
      _keep(source, attachmentsFolder, '${const Uuid().v4()}.${type.fileExtension}');

  /// Copies a picked profile photo into the profile folder.
  Future<String> keepAvatar(String source, UploadImageType type) =>
      _keep(source, profileFolder, 'avatar_${const Uuid().v4()}.${type.fileExtension}');

  Future<String> _keep(String source, String folder, String name) async {
    await init();
    final dir = _folder(folder)!;
    if (p.isWithin(dir, p.normalize(source)) && await _realPathWithin(source, dir)) return source;
    await Directory(dir).create(recursive: true);
    final target = p.join(dir, name);
    await File(source).copy(target);
    return target;
  }

  /// Deletes [path] only if it is a file inside a photo folder (also after
  /// resolving symlinks). Returns whether a file was deleted. Never throws.
  Future<bool> deleteAppPhoto(String path) async {
    try {
      await init();
      if (!isAppPhoto(path)) return false;
      final f = File(path);
      if (!await f.exists()) return false;
      final real = p.normalize(await f.resolveSymbolicLinks());
      if (!isAppPhoto(real)) return false;
      await File(real).delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _realPathWithin(String path, String dir) async {
    try {
      return p.isWithin(dir, p.normalize(await File(path).resolveSymbolicLinks()));
    } catch (_) {
      return false;
    }
  }
}
