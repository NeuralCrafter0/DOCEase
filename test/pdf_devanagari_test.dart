// Regression test: a Hindi (Devanagari) patient name is in the PDF's text
// layer, not dropped (QA feature pass F-PDF-02). Needs pdftotext
// (poppler-utils), as QA's suite does.
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/utils/pdf_export.dart';
import 'package:docease/utils/pdf_fonts.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake 'net.nfet.printing': asks the Dart side for the bytes via onLayout,
/// like the real plugin, and keeps them.
class FakePrinter {
  Uint8List? lastPdf;
  void install() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('net.nfet.printing'), (call) async {
      if (call.method == 'printingInfo') {
        return {'canPrint': true, 'canShare': true, 'canRaster': true, 'canListPrinters': false, 'directPrint': false, 'dynamicLayout': true};
      }
      if (call.method != 'printPdf') return null;
      final job = (call.arguments as Map)['job'];
      scheduleMicrotask(() async {
        const codec = StandardMethodCodec();
        final reply = Completer<ByteData?>();
        await m.handlePlatformMessage('net.nfet.printing', codec.encodeMethodCall(MethodCall('onLayout', {
          'job': job, 'width': 595.0, 'height': 842.0,
          'marginLeft': 0.0, 'marginTop': 0.0, 'marginRight': 0.0, 'marginBottom': 0.0,
        })), reply.complete);
        final data = await reply.future;
        if (data != null) lastPdf = codec.decodeEnvelope(data) as Uint8List;
        await m.handlePlatformMessage('net.nfet.printing',
            codec.encodeMethodCall(MethodCall('onCompleted', {'job': job, 'completed': true, 'error': null})), (_) {});
      });
      return 1;
    });
  }
}

Future<String> exportText(Patient p) async {
  final printer = FakePrinter()..install();
  await PdfExport.generateAndPrintPatientReport(p);
  for (var i = 0; i < 100 && printer.lastPdf == null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(printer.lastPdf, isNotNull, reason: 'export must not fail');
  final dir = Directory.systemTemp.createTempSync('docease_pdf_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final f = File('${dir.path}/out.pdf')..writeAsBytesSync(printer.lastPdf!);
  final r = await Process.run('pdftotext', ['-layout', f.path, '-']);
  return '${r.stdout}';
}

Patient named(String name) => Patient(id: 'a1b2c3d4-e5f6', name: name, age: '52', gender: 'Male', phone: '+919811111111', history: [
      VisitRecord(id: 'v1', date: DateTime(2026, 3, 1), visitType: 'Routine', symptoms: 'खांसी', diagnosis: 'Acute bronchitis', prescription: 'Azithromycin 500mg'),
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(PdfFonts.reset);

  test('F-PDF-02 a Hindi patient name is in the PDF text', () async {
    final text = await exportText(named('राम शर्मा'));
    expect(text, contains('राम'), reason: text.substring(0, text.length.clamp(0, 300)));
    expect(text, contains('खांसी'), reason: 'Devanagari in visit notes too');
    expect(text, contains('Acute bronchitis'), reason: 'Latin text unaffected');
  });

  test('a Latin name still prints as before', () async {
    final text = await exportText(named('Asha Verma'));
    expect(text, contains('Asha Verma'));
  });

  test('the font is a bundled asset, loaded once', () async {
    await PdfFonts.ensureLoaded();
    final theme = PdfFonts.theme;
    expect(theme, isNotNull);
    expect(theme!.defaultTextStyle.fontFallback, hasLength(1));
    await PdfFonts.ensureLoaded();
    expect(identical(PdfFonts.theme, theme), isTrue);
  });
}
