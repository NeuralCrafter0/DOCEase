// Tests for client-side JPEG re-encoding of clinical photos.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:docease/utils/attachment_processor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

const fx = 'test/fixtures/attachments';

Future<ui.Image> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

Future<List<int>> pixel(ui.Image im, int x, int y) async {
  final d = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final o = (y * im.width + x) * 4;
  return [d.getUint8(o), d.getUint8(o + 1), d.getUint8(o + 2)];
}

bool isJpeg(Uint8List b) => b.length > 4 && b[0] == 0xFF && b[1] == 0xD8 && b[b.length - 2] == 0xFF && b[b.length - 1] == 0xD9;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory out;
  late AttachmentProcessor processor;

  setUp(() {
    out = Directory.systemTemp.createTempSync('docease_att_');
    processor = AttachmentProcessor(outputDirectory: () async => out, maxEdge: 1024);
  });
  tearDown(() => out.deleteSync(recursive: true));

  for (final name in ['rot6.jpg', 'alpha.png', 'img.gif', 'img.webp', 'big.png']) {
    testWidgets('$name is re-encoded to a .jpg JPEG file', (t) async {
      await t.runAsync(() async {
        final path = await processor.toJpegFile(XFile('$fx/$name'));
        expect(path, endsWith('.jpg'));
        expect(File(path).parent.path, out.path);
        final bytes = File(path).readAsBytesSync();
        expect(isJpeg(bytes), isTrue);
        final im = await decode(bytes);
        expect(im.width, greaterThan(0));
      });
    });
  }

  testWidgets('large photos are scaled so the longest side is maxEdge', (t) async {
    await t.runAsync(() async {
      final im = await decode(File(await processor.toJpegFile(XFile('$fx/big.png'))).readAsBytesSync());
      expect([im.width, im.height], [512, 1024]); // fixture is 1500x3000
    });
  });

  testWidgets('transparent areas become white', (t) async {
    await t.runAsync(() async {
      final im = await decode(File(await processor.toJpegFile(XFile('$fx/alpha.png'))).readAsBytesSync());
      final corner = await pixel(im, 2, 2);
      expect(corner.every((c) => c > 240), isTrue, reason: '$corner');
      final body = await pixel(im, 40, 25);
      expect(body[1], inInclusiveRange(185, 215));
    });
  });

  testWidgets('EXIF orientation is applied and EXIF metadata is not carried over', (t) async {
    await t.runAsync(() async {
      final bytes = File(await processor.toJpegFile(XFile('$fx/rot6.jpg'))).readAsBytesSync();
      final im = await decode(bytes);
      // 40x20 source tagged "rotate 90 CW" must come out upright as 20x40.
      expect([im.width, im.height], [20, 40]);
      expect(String.fromCharCodes(bytes).contains('Exif'), isFalse);
      expect(String.fromCharCodes(bytes).contains('SecretCam'), isFalse);
    });
  });

  for (final (name, bytes) in [
    ('a PDF', File('$fx/notes.pdf').readAsBytesSync()),
    ('random bytes', Uint8List.fromList(List.generate(500, (i) => (i * 37) % 256))),
    ('an empty file', Uint8List(0)),
    ('a truncated JPEG header', Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16])),
  ]) {
    testWidgets('$name is rejected as unsupported and writes no file', (t) async {
      await t.runAsync(() async {
        final src = File('${out.path}/../in_${name.hashCode}.bin')..writeAsBytesSync(bytes);
        addTearDown(() => src.existsSync() ? src.deleteSync() : null);
        await expectLater(processor.toJpegFile(XFile(src.path)),
            throwsA(isA<AttachmentException>().having((e) => e.error, 'error', AttachmentError.unsupported)));
        expect(out.listSync(), isEmpty);
      });
    });
  }

  testWidgets('a missing file is reported as unreadable', (t) async {
    await t.runAsync(() async {
      await expectLater(processor.toJpegFile(XFile('${out.path}/nope.heic')),
          throwsA(isA<AttachmentException>().having((e) => e.error, 'error', AttachmentError.unreadable)));
      expect(out.listSync(), isEmpty);
    });
  });

  test('messages say the file was not added', () {
    for (final e in AttachmentError.values) {
      expect(AttachmentException(e).message, contains("wasn't added"));
    }
  });
}
