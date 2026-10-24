// Blood sugar on the visit form, and every filled vital (sugar included)
// shown on the timeline, the visit details and the PDF list.
// Local data only: no Firebase app, no FirebaseAuth.
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/utils/vitals_display.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

Future<void> pumpWith(WidgetTester t, LocalPatientProvider pp, Widget screen) async {
  t.view.physicalSize = const Size(1080, 3200);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: pp),
      ChangeNotifierProvider<MedicineProvider>.value(value: LocalMedicineProvider()),
      ChangeNotifierProvider<DoctorProvider>.value(value: LocalDoctorProvider()),
    ],
    child: MaterialApp(home: screen),
  ));
  await t.pumpAndSettle();
}

Finder vitalField(String label) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
      matching: find.byType(TextField),
    );

void main() {
  group('filledVitals', () {
    test('lists filled vitals in form order, sugar included', () {
      final r = visit('r', DateTime(2026, 1, 1), bp: '130/85', temp: ' 99 F ', pulse: '', weight: null, sugar: '142');
      expect(filledVitals(r).map((v) => '${v.label}=${v.value}'), ['BP=130/85', 'Temp=99 F', 'Sugar=142']);
      expect(vitalsLine(r), 'BP: 130/85 | Temp: 99 F | Sugar: 142');
    });

    test('sugar alone is enough, BP is not required', () {
      final r = visit('r', DateTime(2026, 1, 1), sugar: '110');
      expect(filledVitals(r).single, (label: 'Sugar', value: '110'));
    });

    test('nothing filled gives nothing', () {
      expect(filledVitals(visit('r', DateTime(2026, 1, 1), bp: '  ')), isEmpty);
    });
  });

  group('visit form', () {
    testWidgets('has a Blood Sugar input and saves what is typed', (t) async {
      final pp = LocalPatientProvider([patientWith([])]);
      await pumpWith(t, pp, const AddRecordScreen(patientId: 'p1'));
      expect(find.text('Blood Sugar'), findsOneWidget);
      expect(find.text('mg/dL'), findsOneWidget);

      await t.enterText(find.widgetWithText(TextFormField, 'Diagnosis'), 'Type 2 diabetes');
      await t.enterText(vitalField('Blood Sugar'), '186');
      await t.ensureVisible(find.widgetWithText(ElevatedButton, 'Save Clinical Record'));
      await t.tap(find.widgetWithText(ElevatedButton, 'Save Clinical Record'));
      await t.pumpAndSettle();

      expect(pp.added, hasLength(1));
      expect(pp.added.single.$1, 'p1');
      expect(pp.added.single.$2.sugar, '186');
    });

    testWidgets('editing a visit shows its sugar and keeps a change', (t) async {
      final r = visit('r1', DateTime(2026, 3, 2), sugar: '120');
      final pp = LocalPatientProvider([patientWith([r])]);
      await pumpWith(t, pp, AddRecordScreen(patientId: 'p1', existingRecord: r));
      final field = t.widget<TextField>(vitalField('Blood Sugar'));
      expect(field.controller!.text, '120');

      await t.enterText(vitalField('Blood Sugar'), '98');
      await t.ensureVisible(find.widgetWithText(ElevatedButton, 'Save Clinical Record'));
      await t.tap(find.widgetWithText(ElevatedButton, 'Save Clinical Record'));
      await t.pumpAndSettle();
      expect(pp.updated.single.$2.sugar, '98');
      expect(pp.updated.single.$2.id, 'r1');
    });
  });

  group('patient detail', () {
    testWidgets('timeline shows vitals even when BP is empty, sugar included', (t) async {
      final pp = LocalPatientProvider([
        patientWith([visit('r1', DateTime(2026, 3, 2), pulse: '88', sugar: '210')]),
      ]);
      await pumpWith(t, pp, const PatientDetailScreen(patientId: 'p1'));
      expect(find.text('Pulse: 88'), findsOneWidget);
      expect(find.text('Sugar: 210'), findsOneWidget);
      expect(find.textContaining('BP:'), findsNothing);
    });

    testWidgets('visit details list only the filled vitals', (t) async {
      final pp = LocalPatientProvider([
        patientWith([visit('r1', DateTime(2026, 3, 2), diagnosis: 'Diabetes review', bp: '140/90', sugar: '160')]),
      ]);
      await pumpWith(t, pp, const PatientDetailScreen(patientId: 'p1'));
      await t.tap(find.text('Diabetes review'));
      await t.pumpAndSettle();
      expect(find.text('BP: 140/90 | Sugar: 160'), findsOneWidget);
      expect(find.textContaining('null'), findsNothing);
    });
  });
}
