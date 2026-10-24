// Security review (#7, Info): the "Vitals" box now also sends blood sugar,
// so the share sheet spells out what it includes.
import 'package:docease/models/patient.dart';
import 'package:docease/utils/visit_share_text.dart';
import 'package:docease/widgets/share_confirm_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const vitalsDetail = 'BP, temperature, pulse, weight, blood sugar';

Future<void> pumpSheet(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: ShareConfirmSheet(patientName: 'Asha')))));
  await t.pump();
}

void main() {
  testWidgets('the Vitals box lists BP, temperature, pulse, weight and blood sugar', (t) async {
    await pumpSheet(t);
    expect(
      find.descendant(of: find.byKey(const ValueKey('share-field-vitals')), matching: find.text(vitalsDetail)),
      findsOneWidget,
    );
  });

  testWidgets('the other boxes have no subtitle', (t) async {
    await pumpSheet(t);
    for (final f in ShareField.values.where((f) => f != ShareField.vitals)) {
      final tile = t.widget<CheckboxListTile>(find.byKey(ValueKey('share-field-${f.name}')));
      expect(tile.subtitle, isNull, reason: f.name);
    }
  });

  test('the subtitle matches what the Vitals line actually sends', () {
    final text = VisitShareText.build(
      patient: Patient(id: 'p1', name: 'Asha', age: '34', gender: 'Female', phone: '+919999999999'),
      record: VisitRecord(id: 'r1', date: DateTime(2026, 10, 1), visitType: 'Routine', symptoms: 's', diagnosis: 'd',
          prescription: 'rx', bp: '120/80', temp: '98.6', pulse: '72', weight: '60', sugar: '110'),
      fields: {ShareField.vitals},
    );
    for (final label in ['BP', 'Temp', 'Pulse', 'Weight', 'Sugar']) {
      expect(text, contains(label), reason: label);
    }
    expect(ShareField.vitals.detail, vitalsDetail);
  });
}
