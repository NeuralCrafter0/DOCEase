// Regression tests for the prescription type-ahead (QA case UI-05).
// ignore_for_file: depend_on_referenced_packages
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

class FakePatientProvider extends PatientProvider {
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
}

class FakeMedicineProvider extends MedicineProvider {
  final List<String> meds;
  FakeMedicineProvider(this.meds);
  @override
  List<String> get frequentMedicines => meds;
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

TextEditingValue v(String text, [int? caret]) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: caret ?? text.length));

Future<Finder> openNote(WidgetTester t, List<String> meds) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: FakePatientProvider()),
      ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider(meds)),
    ],
    child: const MaterialApp(home: AddRecordScreen(patientId: 'p1')),
  ));
  await t.pumpAndSettle();
  return find.widgetWithText(TextField, 'Type medicine name...');
}

Future<void> type(WidgetTester t, Finder rx, String text) async {
  await t.tap(rx);
  await t.enterText(rx, text);
  await t.pump(const Duration(milliseconds: 600));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('PrescriptionLines', () {
    const meds = ['Paracetamol 500mg', 'Pantoprazole 40mg', 'Amoxicillin 250mg'];

    test('queries only the line under the caret', () {
      expect(PrescriptionLines.currentQuery(v('Amoxicillin - BD\nPara')), 'Para');
      expect(PrescriptionLines.currentQuery(v('Amox\nPara', 2)), 'Amox');
      expect(PrescriptionLines.currentQuery(v('Amox\n')), '');
      expect(PrescriptionLines.suggestionsFor(v('Amoxicillin - BD\npan'), meds), ['Pantoprazole 40mg']);
      expect(PrescriptionLines.suggestionsFor(v('Amoxicillin - BD\n'), meds), isEmpty);
    });

    test('completes the current line and keeps the others', () {
      final r = PrescriptionLines.applySuggestion(v('Amoxicillin 250mg - BD\nPara'), 'Paracetamol 500mg');
      expect(r.text, 'Amoxicillin 250mg - BD\nParacetamol 500mg');
      expect(r.selection.extentOffset, r.text.length);

      final mid = PrescriptionLines.applySuggestion(v('Line one\nPan\nLine three', 12), 'Pantoprazole 40mg');
      expect(mid.text, 'Line one\nPantoprazole 40mg\nLine three');
      expect(mid.selection.extentOffset, 'Line one\nPantoprazole 40mg'.length);

      expect(PrescriptionLines.applySuggestion(v('Pa'), 'Pantoprazole 40mg').text, 'Pantoprazole 40mg');
    });
  });

  testWidgets('UI-05 suggestions appear for the 2nd medicine line', (t) async {
    final rx = await openNote(t, ['Paracetamol 500mg']);
    await type(t, rx, 'Amoxicillin 250mg - BD (1-0-1)\nPara');
    expect(find.text('Paracetamol 500mg'), findsOneWidget);
  });

  testWidgets('UI-05 picking a suggestion completes only the current line', (t) async {
    final rx = await openNote(t, ['Paracetamol 500mg']);
    await type(t, rx, 'Amoxicillin 250mg - BD (1-0-1)\nPara');
    await t.tap(find.text('Paracetamol 500mg'));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(rx).controller!.text, 'Amoxicillin 250mg - BD (1-0-1)\nParacetamol 500mg');
  });

  testWidgets('first line still completes as before', (t) async {
    final rx = await openNote(t, ['Paracetamol 500mg', 'Pantoprazole 40mg']);
    await type(t, rx, 'Pa');
    await t.tap(find.text('Pantoprazole 40mg'));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(rx).controller!.text, 'Pantoprazole 40mg');
  });
}
