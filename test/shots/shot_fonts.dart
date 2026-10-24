import 'dart:io';

import 'package:flutter/services.dart';

/// Loads Figtree and the Material icon font so screenshots show real text
/// and icons instead of test boxes.
Future<void> loadShotFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final l = FontLoader(family);
    for (final p in paths) {
      final bytes = File(p).readAsBytesSync();
      l.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await l.load();
  }

  await load('Figtree', [for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) 'assets/fonts/Figtree-$w.ttf']);
  await load('MaterialIcons', ['/opt/flutter-3.41.2/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf']);
}
