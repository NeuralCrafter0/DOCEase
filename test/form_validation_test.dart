// Regression tests for patient-form and clinical-note validation
// (QA cases UI-01, UI-02, UI-03).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/patient.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_patient_screen.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class FakePatientProvider extends PatientProvider {
  final List<Patient> added = [];
  final List<VisitRecord> records = [];
  Patient? fixture;
  @override
  Future<void> addPatient(Patient patient) async => added.add(patient);
  @override
  Future<void> addRecord(String patientId, VisitRecord record) async => records.add(record);
  @override
  Patient findById(String id) => fixture!;
}

class FakeMedicineProvider extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

Future<void> open(WidgetTester t, Widget screen, PatientProvider p) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: p),
      ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider()),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => screen)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
}

Finder get nameField => find.byType(TextField).at(0);
Finder get ageField => find.byType(TextField).at(1);
Finder get phoneField => find.byType(TextField).last;

Future<void> fillPatient(WidgetTester t, {String name = 'Asha Rao', String age = '34', String phone = '9876543210'}) async {
  await t.enterText(nameField, name);
  await t.enterText(ageField, age);
  await t.enterText(phoneField, phone);
}

Future<void> register(WidgetTester t) async {
  await t.tap(find.text('Register Profile'));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('PatientFormValidators', () {
    test('name', () {
      expect(PatientFormValidators.name(''), isNotNull);
      expect(PatientFormValidators.name('   '), isNotNull);
      expect(PatientFormValidators.name('Asha2'), isNotNull);
      expect(PatientFormValidators.name('---'), isNotNull);
      expect(PatientFormValidators.name('A' * 81), isNotNull);
      expect(PatientFormValidators.name('Asha Rao'), isNull);
      expect(PatientFormValidators.name("D'Souza-Pinto"), isNull);
      expect(PatientFormValidators.name('आशा राव'), isNull);
      expect(PatientFormValidators.normalizeName('  Asha   Rao '), 'Asha Rao');
    });

    test('age', () {
      expect(PatientFormValidators.age(''), isNotNull);
      expect(PatientFormValidators.age('abc'), isNotNull);
      expect(PatientFormValidators.age('-1'), isNotNull);
      expect(PatientFormValidators.age('3.5'), isNotNull);
      expect(PatientFormValidators.age('121'), isNotNull);
      expect(PatientFormValidators.age('0'), isNull);
      expect(PatientFormValidators.age('120'), isNull);
    });

    test('phone', () {
      expect(PatientFormValidators.phone(''), isNotNull);
      expect(PatientFormValidators.phone('98765 43210'), isNotNull);
      expect(PatientFormValidators.phone('9876543210'), isNull);
    });
  });

  group('AddPatientScreen', () {
    testWidgets('UI-01 blank name is rejected inline and nothing is saved', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, name: '');
      await register(t);
      expect(find.text("Enter the patient's name"), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('UI-01 whitespace-only name is rejected', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, name: '    ');
      await register(t);
      expect(find.text("Enter the patient's name"), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('UI-01 blank age is rejected inline and nothing is saved', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, age: '');
      await register(t);
      expect(find.text('Enter the age in years'), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('age field only accepts digits and rejects > 120', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, age: '1a5x0');
      expect(t.widget<TextField>(ageField).controller!.text, '150');
      await register(t);
      expect(find.text('Enter an age between 0 and 120'), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('UI-02 blank phone is rejected inline and nothing is saved', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, phone: '');
      await register(t);
      expect(find.text('Enter the mobile number'), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('UI-02 too-short phone is rejected', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, phone: '98765');
      await register(t);
      expect(find.text('Enter a valid mobile number'), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('all fields blank shows every error at once', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await register(t);
      expect(find.text("Enter the patient's name"), findsOneWidget);
      expect(find.text('Enter the age in years'), findsOneWidget);
      expect(find.text('Enter the mobile number'), findsOneWidget);
      expect(p.added, isEmpty);
    });

    testWidgets('valid form saves normalized values with the dial code', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, name: '  Asha   Rao ');
      await register(t);
      expect(p.added, hasLength(1));
      expect(p.added.single.name, 'Asha Rao');
      expect(p.added.single.age, '34');
      expect(p.added.single.phone, '+919876543210');
      expect(find.text('Register Profile'), findsNothing, reason: 'screen closes after save');
    });

    testWidgets('error clears once the field is fixed', (t) async {
      final p = FakePatientProvider();
      await open(t, const AddPatientScreen(), p);
      await fillPatient(t, phone: '');
      await register(t);
      expect(find.text('Enter the mobile number'), findsOneWidget);
      await t.enterText(phoneField, '9876543210');
      await t.pumpAndSettle();
      expect(find.text('Enter the mobile number'), findsNothing);
      await register(t);
      expect(p.added, hasLength(1));
    });
  });

  group('AddRecordScreen', () {
    FakePatientProvider provider() => FakePatientProvider()
      ..fixture = Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '+919876543210');

    Finder diagnosisField() => find.widgetWithText(TextFormField, 'Diagnosis');

    testWidgets('UI-03 blank diagnosis is rejected inline and nothing is saved', (t) async {
      final p = provider();
      await open(t, const AddRecordScreen(patientId: 'p1'), p);
      await t.tap(find.text('Save Clinical Record'));
      await t.pumpAndSettle();
      expect(find.text('Enter a diagnosis'), findsOneWidget);
      expect(p.records, isEmpty);
    });

    testWidgets('UI-03 whitespace-only diagnosis is rejected', (t) async {
      final p = provider();
      await open(t, const AddRecordScreen(patientId: 'p1'), p);
      await t.enterText(diagnosisField(), '   \n ');
      await t.tap(find.text('Save Clinical Record'));
      await t.pumpAndSettle();
      expect(find.text('Enter a diagnosis'), findsOneWidget);
      expect(p.records, isEmpty);
    });

    testWidgets('a note with a diagnosis saves (trimmed)', (t) async {
      final p = provider();
      await open(t, const AddRecordScreen(patientId: 'p1'), p);
      await t.enterText(diagnosisField(), '  Viral fever ');
      await t.tap(find.text('Save Clinical Record'));
      await t.pumpAndSettle();
      expect(p.records, hasLength(1));
      expect(p.records.single.diagnosis, 'Viral fever');
    });
  });
}
