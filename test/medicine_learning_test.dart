// Regression tests for prescription learning and dosage chips
// (QA feature pass F-MED-02..05).
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/utils/prescription_lines.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Saves complete only when the test says so; until then nothing is stored.
class HeldSavePatientProvider extends PatientProvider {
  Completer<void>? pending;
  final saved = <VisitRecord>[];
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
  @override
  Future<void> addRecord(String patientId, VisitRecord record) async {
    pending = Completer<void>();
    await pending!.future;
    saved.add(record);
  }
}

class LearningMedicineProvider extends MedicineProvider {
  final learned = <String>[];
  @override
  List<String> get frequentMedicines => learned;
  @override
  Future<void> addMedicineIfNew(String med) async {
    if (!learned.contains(med)) learned.add(med);
  }
}

const rxHint = 'Type medicine name...';
Finder get rx => find.widgetWithText(TextField, rxHint);
String rxText(WidgetTester t) => t.widget<TextField>(rx).controller!.text;

Future<(HeldSavePatientProvider, LearningMedicineProvider)> openNote(WidgetTester t) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  final patients = HeldSavePatientProvider();
  final meds = LearningMedicineProvider();
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: patients),
      ChangeNotifierProvider<MedicineProvider>.value(value: meds),
    ],
    child: const MaterialApp(home: AddRecordScreen(patientId: 'p1')),
  ));
  await t.pumpAndSettle();
  return (patients, meds);
}

Future<void> typeInto(WidgetTester t, Finder f, String text) async {
  await t.enterText(f, text);
  await t.pump(const Duration(milliseconds: 600));
  await t.pumpAndSettle();
}

Future<void> tapChip(WidgetTester t, String label) async {
  // Close the type-ahead box first; it sits over the chips while typing.
  FocusManager.instance.primaryFocus?.unfocus();
  await t.pumpAndSettle();
  final chip = find.widgetWithText(ActionChip, label);
  await t.ensureVisible(chip);
  await t.tap(chip);
  await t.pumpAndSettle();
}

/// Fills a diagnosis (required on the form-validation branch) and saves.
Future<void> save(WidgetTester t) async {
  final diagnosis = find.widgetWithText(TextFormField, 'Diagnosis');
  if (diagnosis.evaluate().isNotEmpty) await typeInto(t, diagnosis, 'Bronchitis');
  final button = find.widgetWithText(ElevatedButton, 'Save Clinical Record');
  await t.ensureVisible(button);
  await t.tap(button);
  await t.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  final templates = MedicineProvider().dosageTemplates;
  final od = templates.first;

  group('PrescriptionLines.medicineNames', () {
    test('every line, without its dosage, no repeats or blanks', () {
      expect(
        PrescriptionLines.medicineNames(
          'Azithromycin 500mg - $od\n\nParacetamol 650mg\n  Azithromycin 500mg - BD (1-0-1)  \n',
          dosages: templates,
        ),
        ['Azithromycin 500mg', 'Paracetamol 650mg'],
      );
    });
    test('dosage-only lines are not medicines', () {
      expect(PrescriptionLines.medicineNames('$od\n - BD (1-0-1)\nCetirizine 10mg', dosages: templates),
          ['Cetirizine 10mg']);
    });
    test('hyphenated names are kept whole', () {
      expect(PrescriptionLines.medicineNames('Amoxicillin-Clavulanate 625mg - $od'), ['Amoxicillin-Clavulanate 625mg']);
    });
    // Security review (#6, Low): the learned list is doctor-wide and synced,
    // so free-text instructions must never be learned.
    test('instruction lines are never learned', () {
      expect(
        PrescriptionLines.medicineNames(
          'Azithromycin 500mg - $od\nreview with sugar report Monday\nReview with sugar report on Monday.\n'
          'Review on Monday\nTake after food\nCome back if fever persists, call us\nDrink plenty of water\n'
          'Avoid oily food - $od\nRepeat CBC in 2 weeks\nPan-D (Pantoprazole+Domperidone)',
          dosages: templates,
        ),
        ['Azithromycin 500mg', 'Pan-D (Pantoprazole+Domperidone)'],
      );
    });
    test('drug-name shape', () {
      for (final ok in ['Azithromycin 500mg', 'Tab. Dolo 650', 'Inj. Ceftriaxone 1g', 'Syp. Ambroxol',
          'Vitamin D3 60000 IU', 'Paracetamol', 'Metformin SR 500 mg', 'पैरासिटामोल 500']) {
        expect(PrescriptionLines.looksLikeMedicine(ok), isTrue, reason: ok);
      }
      for (final bad in ['review with sugar report Monday', 'Review on Monday', 'BP check tomorrow', 'ok.',
          'Rest for three days', 'Is it better?', '2 tablets daily', 'Follow up', 'x' * 61,
          'Metformin 500 mg twice daily after meals please']) {
        expect(PrescriptionLines.looksLikeMedicine(bad), isFalse, reason: bad);
      }
    });
    test('a line picked from the suggestions is kept even if it does not look like a drug name', () {
      expect(PrescriptionLines.medicineNames('Dr Special Mix for kids', known: ['Dr Special Mix for kids']),
          ['Dr Special Mix for kids']);
      expect(PrescriptionLines.medicineNames('Dr Special Mix for kids'), isEmpty);
    });
  });

  group('PrescriptionLines.applyDosage', () {
    test('adds the dosage to the last medicine and starts a new line', () {
      final r = PrescriptionLines.applyDosage('Azithromycin 500mg', od);
      expect(r.text, 'Azithromycin 500mg - $od\n');
      expect(r.selection.extentOffset, r.text.length);
    });
    test('an empty prescription never starts with " - "', () {
      expect(PrescriptionLines.applyDosage('', od).text, '$od\n');
      expect(PrescriptionLines.applyDosage('  \n', od).text, '$od\n');
    });
    test('a second chip replaces the dosage instead of adding an empty line', () {
      final once = PrescriptionLines.applyDosage('Azithromycin 500mg', od).text;
      expect(PrescriptionLines.applyDosage(once, 'BD (1-0-1)').text, 'Azithromycin 500mg - BD (1-0-1)\n');
    });
    test('earlier lines are kept', () {
      expect(PrescriptionLines.applyDosage('Cetirizine 10mg - HS (Bedtime)\nPantoprazole 40mg', 'AC (Before Food)').text,
          'Cetirizine 10mg - HS (Bedtime)\nPantoprazole 40mg - AC (Before Food)\n');
    });
  });

  group('visit form', () {
    testWidgets('every prescription line is learned, not only the first', (t) async {
      final (patients, meds) = await openNote(t);
      await typeInto(t, rx, 'Azithromycin 500mg\nParacetamol 650mg');
      await save(t);
      patients.pending!.complete();
      await t.pumpAndSettle();
      expect(patients.saved, hasLength(1));
      expect(meds.learned, ['Azithromycin 500mg', 'Paracetamol 650mg']);
    });

    testWidgets('a dosage chip is not learned as part of the name', (t) async {
      final (patients, meds) = await openNote(t);
      await typeInto(t, rx, 'Azithromycin 500mg');
      await tapChip(t, od);
      expect(rxText(t), 'Azithromycin 500mg - $od\n');
      await save(t);
      patients.pending!.complete();
      await t.pumpAndSettle();
      expect(meds.learned, ['Azithromycin 500mg']);
    });

    testWidgets('an instruction line in the prescription is not learned', (t) async {
      final (patients, meds) = await openNote(t);
      await typeInto(t, rx, 'Azithromycin 500mg\nreview with sugar report Monday');
      await save(t);
      patients.pending!.complete();
      await t.pumpAndSettle();
      expect(patients.saved, hasLength(1));
      expect(meds.learned, ['Azithromycin 500mg']);
    });

    testWidgets('a dosage chip on an empty prescription does not start with " - "', (t) async {
      await openNote(t);
      await tapChip(t, od);
      expect(rxText(t), '$od\n');
    });

    testWidgets('nothing is learned until the save has succeeded', (t) async {
      final (patients, meds) = await openNote(t);
      await typeInto(t, rx, 'Refusedmycin 1mg');
      await save(t);
      expect(patients.pending, isNotNull, reason: 'save started');
      await t.pump(const Duration(seconds: 1));
      expect(meds.learned, isEmpty, reason: 'learned before the save completed');
      patients.pending!.complete();
      await t.pumpAndSettle();
      expect(meds.learned, ['Refusedmycin 1mg']);
    });
  });
}
