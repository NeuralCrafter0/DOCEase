// Regression tests: when the local database refuses to register or edit a
// patient, the form shows a message instead of an uncaught exception and a
// silent close (QA feature pass F-PAT-05, F-PAT-06; screen side only, the
// provider rollback is the backend's).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/patient.dart';
import 'dart:async';

import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_patient_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Cause of the refusal. Its text carries patient data on purpose: the
/// screen must not show it (#5 merge notes: real SaveRefusedException).
class LeakyCause implements Exception {
  @override
  String toString() => 'refused: Ravi Changed +919876543210';
}

/// Refuses like the DB does: the provider rolls back and rethrows.
class RefusingProvider extends PatientProvider {
  bool refuse;
  /// When set, thrown instead of a refusal (a bug, not a refused save).
  Object? bug;
  final List<Patient> saved = [];
  RefusingProvider({this.refuse = true});
  @override
  Future<void> addPatient(Patient patient) async {
    if (bug != null) throw bug!;
    if (refuse) throw SaveRefusedException(PatientSaveOperation.add, LeakyCause());
    saved.add(patient);
  }
  @override
  Future<void> updatePatient(Patient patient) async {
    if (bug != null) throw bug!;
    if (refuse) throw SaveRefusedException(PatientSaveOperation.update, LeakyCause());
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

  testWidgets('F-PAT-05 refused registration closes the form and tells the doctor', (t) async {
    final p = RefusingProvider();
    await open(t, const AddPatientScreen(), p);
    await t.enterText(nameField, 'Asha Rao');
    await t.enterText(ageField, '34');
    await t.enterText(phoneField, '9876543210');
    await t.tap(find.text('Register Profile'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text("Couldn't register this patient. Nothing was saved."), findsOneWidget);
    expect(find.text('Register Profile'), findsNothing, reason: 'form closes');
    expect(find.text('Asha Rao'), findsNothing, reason: 'the unsaved patient is not shown');
    expect(find.textContaining('Asha'), findsNothing, reason: 'no patient data in the message');
    expect(find.textContaining('+91987'), findsNothing, reason: 'no patient data in the message');
    expect(p.saved, isEmpty);
  });
  testWidgets('F-PAT-06 refused edit closes the form and says the old details were kept', (t) async {
    final p = RefusingProvider();
    await open(t, AddPatientScreen(existingPatient: ravi), p);
    await t.enterText(nameField, 'Ravi Changed');
    await t.tap(find.text('Save Changes'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text("Couldn't save these changes. The previous details were kept."), findsOneWidget);
    expect(find.text('Save Changes'), findsNothing, reason: 'form closes');
    expect(find.text('Ravi Changed'), findsNothing, reason: 'the refused edit is not shown');
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

  testWidgets('a StateError from addPatient is not swallowed: form stays open, no SnackBar', (t) async {
    final p = RefusingProvider(refuse: false)..bug = StateError('bug');
    await open(t, const AddPatientScreen(), p);
    await t.enterText(nameField, 'Asha Rao');
    await t.enterText(ageField, '34');
    await t.enterText(phoneField, '9876543210');
    final escaped = <Object>[];
    await runZonedGuarded(() async {
      await t.tap(find.text('Register Profile'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
    }, (e, _) => escaped.add(e));
    final taken = t.takeException();
    if (taken != null) escaped.add(taken);
    expect(escaped.whereType<StateError>(), isNotEmpty, reason: 'the bug must escape the handler');
    expect(find.text('Register Profile'), findsOneWidget, reason: 'form stays open');
    expect(find.text('Asha Rao'), findsOneWidget, reason: 'typed data kept');
    expect(find.byType(SnackBar), findsNothing);
  });
}
