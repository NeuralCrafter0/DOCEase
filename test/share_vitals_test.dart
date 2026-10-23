// Regression tests: the shared visit summary carries every recorded vital,
// not only BP and Temp (QA feature pass F-SHR-03, F-SUG-04).
import 'package:docease/models/patient.dart';
import 'package:docease/utils/visit_share_text.dart';
import 'package:flutter_test/flutter_test.dart';

Patient asha() => Patient(id: 'p1', name: 'Asha', age: '34', gender: 'Female', phone: '+919999999999');

VisitRecord visit({String? bp, String? temp, String? pulse, String? weight, String? sugar}) => VisitRecord(
    id: 'r1', date: DateTime(2026, 10, 1), visitType: 'Routine', symptoms: 's', diagnosis: 'd', prescription: 'rx',
    bp: bp, temp: temp, pulse: pulse, weight: weight, sugar: sugar);

String share(VisitRecord r) => VisitShareText.build(patient: asha(), record: r, fields: {ShareField.vitals});

void main() {
  test('F-SHR-03 pulse and weight go out with BP and Temp', () {
    final text = share(visit(bp: '130/85', temp: '98.6', pulse: '88', weight: '62'));
    expect(text, contains('*Vitals:* BP: 130/85, Temp: 98.6, Pulse: 88, Weight: 62'));
  });

  test('F-SUG-04 blood sugar goes out', () {
    expect(share(visit(bp: '120/80', sugar: '182')), contains('Sugar: 182'));
  });

  test('vitals that were not recorded are left out; BP and Temp keep N/A', () {
    final text = share(visit(pulse: '', weight: '  '));
    expect(text, contains('*Vitals:* BP: N/A, Temp: N/A'));
    expect(text, isNot(contains('Pulse')));
    expect(text, isNot(contains('Weight')));
    expect(text, isNot(contains('Sugar')));
  });

  test('vitals stay out when the doctor unticks them', () {
    final text = VisitShareText.build(patient: asha(), record: visit(pulse: '88', sugar: '182'), fields: {ShareField.diagnosis});
    expect(text, isNot(contains('88')));
    expect(text, isNot(contains('182')));
  });
}
