// Regression tests: PHI inputs opt out of keyboard learning, autocorrect,
// suggestions and smart punctuation (security review C12, PR #7 review,
// QA feature pass F-PRIV-02 for the phone field).
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
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
}

class FakeMedicineProvider extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
}

Future<void> pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: FakePatientProvider()),
      ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider()),
    ],
    child: MaterialApp(home: home),
  ));
  await t.pumpAndSettle();
}

/// Every EditableText on screen, including the patient's phone number
/// (QA feature pass F-PRIV-02: the phone field was the one left out).
List<EditableText> phiEditables(WidgetTester t) => t.widgetList<EditableText>(find.byType(EditableText)).toList();
/// What a clinical input must turn off: learned words, autocorrect,
/// suggestion strip, and smart dashes/quotes (which silently rewrite
/// dosages such as "1--0--1" and quoted instructions).
void expectNoKeyboardRewrites(EditableText f) {
  expect(f.enableIMEPersonalizedLearning, isFalse);
  expect(f.autocorrect, isFalse);
  expect(f.enableSuggestions, isFalse);
  expect(f.smartDashesType, SmartDashesType.disabled);
  expect(f.smartQuotesType, SmartQuotesType.disabled);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  testWidgets('C12 patient form: no IME learning, autocorrect, suggestions or smart punctuation', (t) async {
    await pump(t, const AddPatientScreen());
    final fields = phiEditables(t);
    expect(fields, hasLength(3), reason: 'name, age and phone');
    fields.forEach(expectNoKeyboardRewrites);
  });

  testWidgets('C12 clinical note: every text input opts out of learning, autocorrect, suggestions and smart punctuation', (t) async {
    await pump(t, const AddRecordScreen(patientId: 'p1'));
    final fields = phiEditables(t);
    expect(fields.length, greaterThanOrEqualTo(7), reason: 'symptoms, diagnosis, 4 vitals, prescription');
    fields.forEach(expectNoKeyboardRewrites);
  });
}
