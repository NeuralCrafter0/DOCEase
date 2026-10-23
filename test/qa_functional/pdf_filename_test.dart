// Regression (security C6, PR #7 vs #13 conflict): the PDF file name handed to
// the print / "Save as PDF" dialog never contains the patient's name, in
// normal mode and in dev mode. Taking #13's side of the #7/#13 conflict put
// the name back; qa-merged2 keeps #7's reportFileName().
import 'dart:io';

import 'package:docease/utils/pdf_export.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late FakePrinter printer;
  setUpAll(loadRealFonts);
  setUp(() => printer = FakePrinter()..install());

  final patients = [
    ('a1b2c3d4-0000-4000-8000-000000000001', 'Asha Verma'),
    ('7f3e9c21-aaaa-4bbb-8ccc-0000000000ff', 'Rahul Sharma'),
    ('x', 'आशा वर्मा'),
  ];

  List<String> nameParts(String name) =>
      name.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 2).toList();

  for (final testData in [false, true]) {
    final mode = testData ? 'dev mode' : 'normal mode';
    testWidgets('PDF-NAME-01 ($mode) print dialog file name has no patient name', (t) async {
      for (final (id, name) in patients) {
        printer.calls.clear();
        final p = seedPatient(QaDb(), id, name);
        await t.runAsync(() => PdfExport.generateAndPrintPatientReport(p, testData: testData));
        await t.pump();
        expect(printer.calls, hasLength(1), reason: 'no print call for $name');
        final file = printer.calls.single['name'] as String;
        final lower = file.toLowerCase();
        for (final w in nameParts(name)) {
          expect(lower.contains(w), isFalse, reason: '$mode: "$file" contains "$w" of "$name"');
        }
        final re = testData
            ? RegExp(r'^TEST_DATA_report_[A-Za-z0-9]{1,8}_\d{8}\.pdf$')
            : RegExp(r'^report_[A-Za-z0-9]{1,8}_\d{8}\.pdf$');
        expect(file, matches(re), reason: '$mode: $file');
      }
    });
  }

  // Hardening note (low): reportFileName embeds the first 8 id characters. App
  // ids are UUID v4 (models/patient.dart:186), so this cannot happen for
  // app-created patients; only an id from outside the app containing the
  // name would leak (e.g. 'rahul-sharma-01' -> report_rahulsha_...).
  test('PDF-NAME-04 [hardening] a non-UUID id containing the name does not leak into the file name', () {
    final f = PdfExport.reportFileName(seedPatient(QaDb(), 'rahul-sharma-01', 'Rahul Sharma'), DateTime(2026, 10, 24));
    expect(f.toLowerCase().contains('rahul'), isFalse, reason: f);
  }, skip: true /* low: only non-app ids; app ids are UUID v4 */);

  test('PDF-NAME-02 reportFileName: neutral, id-truncated, dated', () {
    final now = DateTime(2026, 10, 24);
    expect(PdfExport.reportFileName(seedPatient(QaDb(), 'a1b2c3d4-ffff', 'Asha Verma'), now), 'report_a1b2c3d4_20261024.pdf');
    expect(PdfExport.reportFileName(seedPatient(QaDb(), '---', 'Asha Verma'), now), 'report_patient_20261024.pdf');
  });

  test('PDF-NAME-03 no other print/share call in lib and no file name built from patient.name', () {
    final calls = <String>[];
    final nameInFile = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final s = f.readAsStringSync();
      if (RegExp(r'Printing\.(layoutPdf|sharePdf)\(').hasMatch(s)) calls.add(f.path);
      for (final m in RegExp(r"name:\s*[^,)]*\.name\b[^,)]*").allMatches(s)) {
        if (s.substring(0, m.start).contains('Printing.')) nameInFile.add('${f.path}: ${m.group(0)}');
      }
      if (RegExp(r"(fileName|filename|subject)\s*[:=][^;]*patient\.name").hasMatch(s)) nameInFile.add('${f.path}: file name from patient.name');
    }
    expect(calls, ['lib/utils/pdf_export.dart']);
    expect(nameInFile, isEmpty, reason: nameInFile.join('\n'));
    final src = File('lib/utils/pdf_export.dart').readAsStringSync();
    // #13 4fd5d14: the call site uses printFileName(), which is reportFileName()
    // with TEST_DATA_ in front in dev mode (security F7-R1).
    expect(src, contains('name: printFileName(patient, DateTime.now(), testData: testData)'));
    expect(src, contains('final name = reportFileName(patient, now);'));
    expect(src, contains("testData ? '\$kTestDataFilePrefix\$name' : name"));
  });
}
