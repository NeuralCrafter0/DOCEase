import 'dart:io';

import 'package:flutter/widgets.dart';

import '../services/local_photo_store.dart';

/// Image for a stored doctor photo reference: an https download URL
/// (cloud), or in dev mode a file in the app's photo folders. Anything else
/// (or a missing file) gives null, so the placeholder icon shows.
ImageProvider? avatarImageFor(String? ref, {LocalPhotoStore? photos}) {
  if (ref == null || ref.isEmpty) return null;
  if (ref.startsWith('https://')) return NetworkImage(ref); // never plain http
  if ((photos ?? LocalPhotoStore.instance).isAppPhoto(ref)) {
    final f = File(ref);
    if (f.existsSync()) return FileImage(f);
  }
  return null;
}
