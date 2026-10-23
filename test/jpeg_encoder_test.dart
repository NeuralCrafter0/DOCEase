// Round-trip tests for the in-app JPEG encoder (decoded by the engine).
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:docease/utils/jpeg_encoder.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List gradient(int w, int h) {
  final px = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      px[o] = x * 255 ~/ (w - 1);
      px[o + 1] = y * 255 ~/ (h - 1);
      px[o + 2] = 90;
      px[o + 3] = 255;
    }
  }
  return px;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (w, h) in [(64, 48), (37, 23), (8, 8), (1, 1), (300, 7)]) {
    testWidgets('${w}x$h round-trips with small error', (t) async {
      await t.runAsync(() async {
        final src = gradient(w > 1 ? w : 2, h > 1 ? h : 2).sublist(0, w * h * 4);
        final jpg = JpegEncoder(quality: 90).encode(src, w, h);
        expect(jpg.sublist(0, 2), [0xFF, 0xD8]);
        expect(jpg.sublist(jpg.length - 2), [0xFF, 0xD9]);
        final im = (await (await ui.instantiateImageCodec(jpg)).getNextFrame()).image;
        expect([im.width, im.height], [w, h]);
        final got = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
        var err = 0;
        for (var i = 0; i < src.length; i++) {
          if (i % 4 != 3) err += (got[i] - src[i]).abs();
        }
        expect(err / (w * h * 3), lessThan(4.0));
      });
    });
  }

  test('rejects bad sizes', () {
    expect(() => JpegEncoder().encode(Uint8List(0), 0, 10), throwsArgumentError);
    expect(() => JpegEncoder().encode(Uint8List(4), 2, 2), throwsArgumentError);
  });
}
