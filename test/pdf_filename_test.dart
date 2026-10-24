// Regression test for the non-identifying PDF file name (security review C6).
import 'package:docease/models/patient.dart';
import 'package:docease/utils/pdf_export.dart';
import 'package:flutter_test/flutter_test.dart';

Patient p(String id, String name) => Patient(id: id, name: name, age: '34', gender: 'Female', phone: '+919999999999');

void main() {
  final day = DateTime(2026, 10, 23, 21, 5);

  test('C6 file name is report_<shortId>_<yyyymmdd>.pdf with no patient name', () {
    final name = PdfExport.reportFileName(p('3f2a9c1e-77b0-4d1e-9a52-0c1d2e3f4a5b', 'Asha Rao'), day);
    expect(name, 'report_3f2a9c1e_20261023.pdf');
    expect(name.toLowerCase(), isNot(contains('asha')));
    expect(name.toLowerCase(), isNot(contains('rao')));
  });

  test('short or odd ids are cleaned', () {
    expect(PdfExport.reportFileName(p('ab-1', 'X'), day), 'report_ab1_20261023.pdf');
    expect(PdfExport.reportFileName(p('../', 'X'), day), 'report_patient_20261023.pdf');
  });
}
