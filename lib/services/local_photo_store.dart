import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../providers/database_helper.dart' show BackupExcluder, PlatformBackupExcluder;
import 'attachments.dart';
import 'log_codes.dart';

/// Photos kept on the phone (dev mode: no Storage upload).
///
/// Layout, inside the app support directory (app-private), one folder per
/// DB owner so dev (`local`) and real-account photos never share a folder:
///   `<support>/attachments/<ownerHash>/<uuid>.<ext>`        visit photos
///   `<support>/profile/<ownerHash>/avatar_<uuid>.<ext>`     the doctor's photo
///
/// `<ownerHash>` is the same `sha256(owner)[:32]` as the owner's encrypted DB
/// file name (`DatabaseHelper.dbFileNameFor`), so the uid itself is not on disk.
///
/// Files are only kept, shown or deleted inside those folders; deleting is
/// further limited to the given owner's own folders.
///
/// iOS: each owner folder is excluded from iCloud and computer backups when
/// it is first used in a run, through #10's [PlatformBackupExcluder] (the
/// `docease/backup_exclusion` channel in ios/Runner/AppDelegate.swift, which
/// also covers the encrypted DB). It does nothing on Android, where backups
/// are off in the manifest. A failure is logged as a code and retried on the
/// next photo; the photo is still kept.
class LocalPhotoStore {
  LocalPhotoStore({Future<Directory> Function()? supportDir, BackupExcluder? backupExcluder})
      : _supportDir = supportDir ?? getApplicationSupportDirectory,
        _backupExcluder = backupExcluder ?? const PlatformBackupExcluder();

  /// The app-wide store (dev mode calls [init] before runApp).
  static LocalPhotoStore instance = LocalPhotoStore();

  static const attachmentsFolder = 'attachments';
  static const profileFolder = 'profile';

  /// Folder name for [owner]: `sha256(owner)` hex, first 32 characters.
  static String ownerFolderName(String owner) =>
      sha256.convert(utf8.encode(owner)).toString().substring(0, 32);

  static final _ownerHash = RegExp(r'^[0-9a-f]{32}$');

  final Future<Directory> Function() _supportDir;
  final BackupExcluder _backupExcluder;
  String? _support;

  /// Owner folders already excluded from backup in this run (the attribute
  /// stays on the folder, so once per run is enough).
  final Set<String> _excluded = {};

  Future<void> _excludeFromBackup(String dir) async {
    if (_excluded.contains(dir)) return;
    try {
      await _backupExcluder.exclude(dir);
      _excluded.add(dir);
    } catch (e) {
      debugPrint('Photos: backup exclusion failed (${errorCode(e)})');
    }
  }

  /// Resolves the support directory (canonical path). Safe to call again.
  Future<void> init() async {
    if (_support != null) return;
    final dir = await _supportDir();
    await dir.create(recursive: true);
    _support = p.normalize(await dir.resolveSymbolicLinks());
  }

  String? get supportPath => _support;

  /// `<support>/attachments/<ownerHash>`; null before [init].
  String? visitFolderFor(String owner) => _ownerDir(attachmentsFolder, owner);

  /// `<support>/profile/<ownerHash>`; null before [init].
  String? profileFolderFor(String owner) => _ownerDir(profileFolder, owner);

  String? _ownerDir(String root, String owner) {
    if (_support == null || owner.isEmpty) return null;
    return p.join(_support!, root, ownerFolderName(owner));
  }

  List<String> _ownerDirs(String owner) =>
      [visitFolderFor(owner), profileFolderFor(owner)].whereType<String>().toList();

  /// Whether [path] is a file inside a photo folder: [owner]'s folders when
  /// given, otherwise any owner's (`<root>/<ownerHash>/…`). Lexical check
  /// after normalising, so `..` cannot escape. False before [init].
  bool isAppPhoto(String path, {String? owner}) {
    if (!p.isAbsolute(path) || _support == null) return false;
    final n = p.normalize(path);
    if (owner != null) return _ownerDirs(owner).any((d) => p.isWithin(d, n));
    for (final root in [attachmentsFolder, profileFolder]) {
      final r = p.join(_support!, root);
      if (!p.isWithin(r, n)) continue;
      // Must sit in an owner sub-folder, not directly in the root.
      final rel = p.split(p.relative(n, from: r));
      if (rel.length >= 2 && _ownerHash.hasMatch(rel.first)) return true;
    }
    return false;
  }

  /// Keeps a picked visit photo for [owner]: returns [source] if it already
  /// is in the owner's visit folder, otherwise copies it there under a new
  /// name and returns the copy's path.
  Future<String> keepVisitPhoto(String owner, String source, UploadImageType type) =>
      _keep(owner, source, attachmentsFolder, '${const Uuid().v4()}.${type.fileExtension}');

  /// Copies a picked profile photo into [owner]'s profile folder.
  Future<String> keepAvatar(String owner, String source, UploadImageType type) =>
      _keep(owner, source, profileFolder, 'avatar_${const Uuid().v4()}.${type.fileExtension}');

  Future<String> _keep(String owner, String source, String root, String name) async {
    await init();
    final dir = _ownerDir(root, owner);
    if (dir == null) throw ArgumentError('owner must not be empty');
    await Directory(dir).create(recursive: true);
    await _excludeFromBackup(dir);
    if (p.isWithin(dir, p.normalize(source)) && await _realPathWithin(source, dir)) return source;
    final target = p.join(dir, name);
    await File(source).copy(target);
    return target;
  }

  /// Deletes [path] only if it is a file inside [owner]'s photo folders
  /// (also after resolving symlinks). Returns whether a file was deleted.
  /// Never throws.
  Future<bool> deleteAppPhoto(String path, {required String owner}) async {
    try {
      await init();
      if (!isAppPhoto(path, owner: owner)) return false;
      final f = File(path);
      if (!await f.exists()) return false;
      final real = p.normalize(await f.resolveSymbolicLinks());
      if (!isAppPhoto(real, owner: owner)) return false;
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
