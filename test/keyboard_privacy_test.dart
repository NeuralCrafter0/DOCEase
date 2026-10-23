// Regression tests: PHI inputs opt out of keyboard learning (security review C12).
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
import 'package:intl_phone_field/intl_phone_field.dart';
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

/// Every EditableText on screen except the ones inside IntlPhoneField
/// (numeric phone pad; the package exposes no IME option).
List<EditableText> phiEditables(WidgetTester t) {
  final phone = find.descendant(of: find.byType(IntlPhoneField), matching: find.byType(EditableText)).evaluate().map((e) => e.widget).toSet();
  return t.widgetList<EditableText>(find.byType(EditableText)).where((w) => !phone.contains(w)).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  testWidgets('C12 patient form: no IME learning, no autocorrect/suggestions on name', (t) async {
    await pump(t, const AddPatientScreen());
    final fields = phiEditables(t);
    expect(fields, hasLength(2), reason: 'name + age');
    for (final f in fields) {
      expect(f.enableIMEPersonalizedLearning, isFalse);
      expect(f.autocorrect, isFalse);
      expect(f.enableSuggestions, isFalse);
    }
  });

  testWidgets('C12 clinical note: every text input opts out of IME learning', (t) async {
    await pump(t, const AddRecordScreen(patientId: 'p1'));
    final fields = phiEditables(t);
    expect(fields.length, greaterThanOrEqualTo(7), reason: 'symptoms, diagnosis, 4 vitals, prescription');
    for (final f in fields) {
      expect(f.enableIMEPersonalizedLearning, isFalse);
    }
  });
}
