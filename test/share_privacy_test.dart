// Regression tests for PHI export safeguards (security review C6).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/utils/visit_share_text.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final record = VisitRecord(
    id: 'r1', date: DateTime(2026, 10, 1), visitType: 'Routine', symptoms: 'cough', diagnosis: 'URTI-DX',
    prescription: 'Azithro-RX', bp: '120/80', temp: '99');
Patient asha() => Patient(id: 'p1', name: 'Asha Rao', age: '34', gender: 'Female', phone: '+919999999999', history: [record]);

class OnePatient extends PatientProvider {
  final Patient p = asha();
  @override
  List<Patient> get patients => [p];
  @override
  Patient findById(String id) => p;
}

class FixedDoctor extends DoctorProvider {
  @override
  Doctor? get currentDoctor => Doctor(
      id: 'u1', title: 'MR', name: 'John', email: 'j@x.com', age: '40', mobileNumber: '+919000000000',
      specialty: 'GP', clinicName: 'C', practiceMode: 'Solo Practice');
}

/// Opens the record sheet and taps share. Returns a getter for the text
/// handed to the share plugin (null = nothing shared).
Future<String? Function()> openAndTapShare(WidgetTester t) async {
  String? shared;
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/share'), (c) async {
    shared = (c.arguments as Map)['text'] as String?;
    return 'dev.fluttercommunity.plus/share/unavailable';
  });
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: OnePatient()),
      ChangeNotifierProvider<DoctorProvider>.value(value: FixedDoctor()),
    ],
    child: const MaterialApp(home: PatientDetailScreen(patientId: 'p1')),
  ));
  await t.pumpAndSettle();
  await t.tap(find.text('URTI-DX'));
  await t.pumpAndSettle();
  await t.tap(find.byIcon(Icons.share_outlined));
  await t.pumpAndSettle();
  return () => shared;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('share confirmation', () {
    testWidgets('C6 tapping share asks first and sends nothing yet', (t) async {
      final shared = await openAndTapShare(t);
      expect(find.text('Share outside DOCEase?'), findsOneWidget);
      expect(find.textContaining("Asha Rao's visit details"), findsOneWidget);
      expect(shared(), isNull);
    });

    testWidgets('Cancel shares nothing', (t) async {
      final shared = await openAndTapShare(t);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(shared(), isNull);
      expect(find.text('Share outside DOCEase?'), findsNothing);
    });

    testWidgets('dismissing the sheet shares nothing', (t) async {
      final shared = await openAndTapShare(t);
      await t.tapAt(const Offset(10, 10));
      await t.pumpAndSettle();
      expect(shared(), isNull);
    });

    testWidgets('Share with defaults sends every field', (t) async {
      final shared = await openAndTapShare(t);
      await t.tap(find.widgetWithText(ElevatedButton, 'Share'));
      await t.pumpAndSettle();
      expect(shared(), allOf(contains('Asha Rao'), contains('URTI-DX'), contains('Azithro-RX'), contains('BP: 120/80')));
    });

    testWidgets('unticked fields are left out', (t) async {
      final shared = await openAndTapShare(t);
      await t.tap(find.byKey(const ValueKey('share-field-patientName')));
      await t.tap(find.byKey(const ValueKey('share-field-prescription')));
      await t.pump();
      await t.tap(find.widgetWithText(ElevatedButton, 'Share'));
      await t.pumpAndSettle();
      final text = shared()!;
      expect(text, isNot(contains('Asha')));
      expect(text, isNot(contains('Azithro-RX')));
      expect(text, contains('URTI-DX'));
      expect(text, contains('*Date:* 01 Oct 2026'));
    });
  });

  group('VisitShareText.build', () {
    test('all fields, with sign-off', () {
      expect(
        VisitShareText.build(patient: asha(), record: record, fields: {...ShareField.values}, signOff: 'Dr. John'),
        '*Visit Summary - DOCEase*\n*Patient:* Asha Rao\n*Date:* 01 Oct 2026\n*Type:* Routine\n\n'
        '*Vitals:* BP: 120/80, Temp: 99\n*Diagnosis:* URTI-DX\n*Prescription:* Azithro-RX\n\n*Dr. John*',
      );
    });

    test('nothing optional selected and no sign-off', () {
      expect(
        VisitShareText.build(patient: asha(), record: record, fields: const {}),
        '*Visit Summary - DOCEase*\n*Date:* 01 Oct 2026\n*Type:* Routine',
      );
    });
  });
}
