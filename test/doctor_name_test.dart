// Regression tests for the doctor's name on share text and PDF (QA UI-06).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/utils/doctor_name.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Doctor doc(String title, String name) => Doctor(
    id: 'u1', title: title, name: name, email: 'j@x.com', age: '40', mobileNumber: '+919000000000',
    specialty: 'GP', clinicName: 'C', practiceMode: 'Solo Practice');

class OnePatient extends PatientProvider {
  final Patient p = Patient(id: 'p1', name: 'Asha', age: '34', gender: 'Female', phone: '+919999999999', history: [
    VisitRecord(id: 'r1', date: DateTime(2026, 10, 1), visitType: 'Routine', symptoms: 'cough', diagnosis: 'URTI', prescription: 'Rx'),
  ]);
  @override
  List<Patient> get patients => [p];
  @override
  Patient findById(String id) => p;
}

class FixedDoctor extends DoctorProvider {
  final Doctor? d;
  FixedDoctor(this.d);
  @override
  Doctor? get currentDoctor => d;
}

/// Opens the record sheet, taps share and returns the text sent to the
/// share plugin.
Future<String?> shareText(WidgetTester t, Doctor? d) async {
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
      ChangeNotifierProvider<DoctorProvider>.value(value: FixedDoctor(d)),
    ],
    child: const MaterialApp(home: PatientDetailScreen(patientId: 'p1')),
  ));
  await t.pumpAndSettle();
  await t.tap(find.text('URTI'));
  await t.pumpAndSettle();
  await t.tap(find.byIcon(Icons.share_outlined));
  await t.pumpAndSettle();
  return shared;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  test('doctorDisplayName', () {
    expect(doctorDisplayName(doc('MR', 'John')), 'Dr. John');
    expect(doctorDisplayName(doc('MRS', ' Priya Shah ')), 'Dr. Priya Shah');
    expect(doctorDisplayName(doc('MS', 'Dr. Meera')), 'Dr. Meera');
    expect(doctorDisplayName(doc('MR', 'dr john')), 'Dr. john');
    expect(doctorDisplayName(doc('MR', '  ')), isNull);
    expect(doctorDisplayName(null), isNull);
  });

  testWidgets('UI-06 share text signs off as "Dr. John", never "Dr. MR John"', (t) async {
    final text = await shareText(t, doc('MR', 'John'));
    expect(text, isNotNull);
    expect(text, contains('*Dr. John*'));
    expect(text, isNot(contains('MR John')));
  });

  testWidgets('share text without a doctor profile has no "Dr. Doctor" line', (t) async {
    final text = await shareText(t, null);
    expect(text, isNotNull);
    expect(text, isNot(contains('Dr.')));
    expect(text, endsWith('*Prescription:* Rx'));
  });
}
