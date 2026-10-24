import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Removes the copies image_picker leaves in the app's temp folders. They
/// hold the original bytes, EXIF (often GPS) and sometimes a revealing file
/// name, which the JPEG re-encoding is meant to get rid of.
///
/// Where the plugins put them (image_picker_android 0.8.13, _ios 0.8.13):
/// - Android gallery: `cacheDir/<uuid>/<original name>`
/// - Android camera: `cacheDir/<uuid><digits>.jpg`
/// - Android resize (maxWidth/maxHeight; DOCEase no longer asks for it):
///   `cacheDir/scaled_<name>`
/// - iOS: `NSTemporaryDirectory()/image_picker_<uuid>.<ext>`
///
/// Only files under the temp roots are ever deleted, so a real gallery file
/// or anything the app keeps is never touched.
class PickerHygiene {
  PickerHygiene({Future<List<Directory>> Function()? temporaryRoots}) : _temporaryRoots = temporaryRoots ?? defaultTemporaryRoots;

  final Future<List<Directory>> Function() _temporaryRoots;

  /// path_provider's temp dir (Android cacheDir, iOS Library/Caches) and the
  /// process temp dir (iOS tmp/, where the picker writes).
  static Future<List<Directory>> defaultTemporaryRoots() async {
    final roots = <Directory>[Directory.systemTemp];
    try {
      roots.add(await getTemporaryDirectory());
    } catch (_) {}
    return roots;
  }

  static final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
  static final RegExp _uuidDir = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  Future<List<String>> _realRoots() async {
    final out = <String>[];
    for (final d in await _temporaryRoots()) {
      try {
        if (await d.exists()) out.add(p.normalize(await d.resolveSymbolicLinks()));
      } catch (_) {}
    }
    return out;
  }

  /// The temp root [path] is inside, or null. Checked after resolving
  /// symlinks so a link out of the temp folder is not followed.
  Future<String?> _rootOf(String path, List<String> roots) async {
    if (!p.isAbsolute(path)) return null;
    final f = File(path);
    if (!await f.exists()) return null;
    final real = p.normalize(await f.resolveSymbolicLinks());
    for (final r in roots) {
      if (p.isWithin(r, real)) return r;
    }
    return null;
  }

  /// Deletes the picker's copy at [path] once its bytes have been read, but
  /// only if it is inside a temp root. Also removes the now-empty
  /// `<uuid>/` folder the Android picker made for it. Never throws.
  /// Returns whether the file was deleted.
  Future<bool> discardPickedSource(String path) async {
    try {
      final roots = await _realRoots();
      final root = await _rootOf(path, roots);
      if (root == null) return false;
      final real = File(p.normalize(await File(path).resolveSymbolicLinks()));
      await real.delete();
      final parent = real.parent;
      if (p.normalize(parent.path) != root &&
          p.isWithin(root, parent.path) &&
          _uuidDir.hasMatch(p.basename(parent.path)) &&
          await parent.list().isEmpty) {
        await parent.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Leftovers from a pick the app was killed or crashed during. Deletes
  /// top-level picker files and Android's `<uuid>/` copy folders in the temp
  /// roots. Run at startup, before any pick. Never throws. Returns the
  /// number of entries removed.
  Future<int> sweepLeftovers() async {
    var removed = 0;
    for (final root in await _realRoots()) {
      try {
        await for (final e in Directory(root).list(followLinks: false)) {
          final name = p.basename(e.path);
          try {
            if (e is Directory && _uuidDir.hasMatch(name)) {
              await e.delete(recursive: true);
              removed++;
            } else if (e is File && _isPickerFile(name)) {
              await e.delete();
              removed++;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return removed;
  }

  static bool _isPickerFile(String name) {
    final lower = name.toLowerCase();
    if (lower.startsWith('image_picker_') || lower.startsWith('scaled_')) return true;
    // Android camera: File.createTempFile(uuid, ".jpg") -> <uuid><digits>.jpg
    return _uuid.hasMatch(name) && RegExp(r'^[0-9a-fA-F-]{36}-?\d*\.jpg$').hasMatch(name);
  }

  /// Startup: switches Android to the system Photo Picker, drops photos
  /// from an interrupted pick (they were never attached to a visit) and
  /// sweeps the picker's leftovers. Never throws.
  static Future<void> atStartup({ImagePicker? picker, PickerHygiene? hygiene}) async {
    useSystemPhotoPickerOnAndroid();
    final h = hygiene ?? PickerHygiene();
    try {
      final lost = await (picker ?? ImagePicker()).retrieveLostData();
      for (final f in lost.files ?? const <XFile>[]) {
        await h.discardPickedSource(f.path);
      }
    } catch (_) {
      // iOS and web have no lost data; nothing to recover anyway.
    }
    final n = await h.sweepLeftovers();
    if (n > 0) debugPrint('Attachments: removed $n picker leftover(s)');
  }

  /// Android 13+: the images-only system Photo Picker instead of the generic
  /// document picker (older versions fall back automatically).
  static void useSystemPhotoPickerOnAndroid() {
    final platform = ImagePickerPlatform.instance;
    if (platform is ImagePickerAndroid) platform.useAndroidPhotoPicker = true;
  }
}
