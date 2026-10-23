// Regression tests: when the local database refuses to register or edit a
// patient, the form shows a message instead of an uncaught exception and a
// silent close (QA feature pass F-PAT-05, F-PAT-06; screen side only, the
// provider rollback is the backend's).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/patient.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_patient_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Stands in for #13's UnsyncedCounterException / SaveRefusedException,
/// which are not on main. The message carries patient data on purpose: the
/// screen must not show it.
class RefusedSave implements Exception {
  @override
  String toString() => 'refused: Ravi Changed +919876543210';
}

/// Refuses like the DB does: the provider rolls back and rethrows.
class RefusingProvider extends PatientProvider {
  bool refuse;
  final List<Patient> saved = [];
  RefusingProvider({this.refuse = true});
  @override
  Future<void> addPatient(Patient patient) async {
    if (refuse) throw RefusedSave();
    saved.add(patient);
  }
  @override
  Future<void> updatePatient(Patient patient) async {
    if (refuse) throw RefusedSave();
    saved.add(patient);
  }
}

Future<void> open(WidgetTester t, Widget screen, PatientProvider p) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<PatientProvider>.value(
    value: p,
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => screen)),
            child: const Text('open'),
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

final ravi = Patient(id: 'p1', name: 'Ravi', age: '40', gender: 'Male', phone: '+919876543210');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  testWidgets('F-PAT-05 refused registration shows a message and keeps the form open', (t) async {
    final p = RefusingProvider();
    await open(t, const AddPatientScreen(), p);
    await t.enterText(nameField, 'Asha Rao');
    await t.enterText(ageField, '34');
    await t.enterText(phoneField, '9876543210');
    await t.tap(find.text('Register Profile'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text("Couldn't register this patient. Nothing was saved. Please try again."), findsOneWidget);
    expect(find.text('Register Profile'), findsOneWidget, reason: 'form stays open');
    expect(find.text('Asha Rao'), findsOneWidget, reason: 'nothing typed is lost');
    expect(find.textContaining('+91987'), findsNothing, reason: 'no patient data in the message');
    expect(p.saved, isEmpty);

    // Once the database accepts it again, the same tap saves and closes.
    p.refuse = false;
    await t.tap(find.text('Register Profile'));
    await t.pumpAndSettle();
    expect(p.saved, hasLength(1));
    expect(find.text('Register Profile'), findsNothing);
  });

  testWidgets('F-PAT-06 refused edit shows a message and does not close as if saved', (t) async {
    final p = RefusingProvider();
    await open(t, AddPatientScreen(existingPatient: ravi), p);
    await t.enterText(nameField, 'Ravi Changed');
    await t.tap(find.text('Save Changes'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text("Couldn't save these changes. The previous details were kept. Please try again."), findsOneWidget);
    expect(find.text('Save Changes'), findsOneWidget);
    expect(find.textContaining('refused'), findsNothing);
    expect(p.saved, isEmpty);
  });

  testWidgets('a save that goes through still closes the form', (t) async {
    final p = RefusingProvider(refuse: false);
    await open(t, AddPatientScreen(existingPatient: ravi), p);
    await t.enterText(nameField, 'Ravi Kumar');
    await t.tap(find.text('Save Changes'));
    await t.pumpAndSettle();
    expect(p.saved.single.name, 'Ravi Kumar');
    expect(find.text('Save Changes'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });
}
