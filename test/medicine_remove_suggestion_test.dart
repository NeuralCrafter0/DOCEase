// Regression tests: the doctor can remove a wrongly learned entry from the
// medicine suggestions (security review #6, Low: a short line such as a
// patient's or relative's name can still be learned).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/patient.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class OnePatientProvider extends PatientProvider {
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
}

/// Stands in for the stored list; [refuse] mimics the provider's guard
/// (the learned list has not loaded, or the write failed).
class RemovableMedicineProvider extends MedicineProvider {
  RemovableMedicineProvider(this.learned);
  final List<String> learned;
  bool refuse = false;
  final removed = <String>[];
  @override
  List<String> get frequentMedicines => learned;
  @override
  Future<void> removeLearnedMedicine(String name) async {
    if (refuse) throw StateError('Learned medicines have not loaded; nothing was removed.');
    removed.add(name);
    learned.remove(name);
    notifyListeners();
  }
}

const rxHint = 'Type medicine name...';
Finder get rx => find.widgetWithText(TextField, rxHint);
String rxText(WidgetTester t) => t.widget<TextField>(rx).controller!.text;
Finder suggestion(String name) => find.widgetWithText(ListTile, name);
const dialogTitle = 'Remove from suggestions?';

Future<RemovableMedicineProvider> openNote(WidgetTester t) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  final meds = RemovableMedicineProvider(['Ravi Kumar', 'Rabeprazole 20mg']);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: OnePatientProvider()),
      ChangeNotifierProvider<MedicineProvider>.value(value: meds),
    ],
    child: const MaterialApp(home: AddRecordScreen(patientId: 'p1')),
  ));
  await t.pumpAndSettle();
  return meds;
}

Future<void> typeRx(WidgetTester t, String text) async {
  await t.tap(rx);
  await t.enterText(rx, text);
  await t.pump(const Duration(milliseconds: 600));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  test('the provider refuses to remove before the learned list has loaded', () async {
    final p = MedicineProvider();
    expect(p.learnedMedicinesLoaded, isFalse);
    await expectLater(p.removeLearnedMedicine('Ravi Kumar'), throwsStateError);
  });

  testWidgets('long-press, confirm: the entry is removed from the stored list and the suggestions', (t) async {
    final meds = await openNote(t);
    await typeRx(t, 'Ra');
    expect(suggestion('Ravi Kumar'), findsOneWidget);
    await t.longPress(suggestion('Ravi Kumar'));
    await t.pumpAndSettle();
    expect(find.text(dialogTitle), findsOneWidget);
    await t.tap(find.widgetWithText(TextButton, 'Remove'));
    await t.pumpAndSettle();
    expect(meds.removed, ['Ravi Kumar'], reason: 'exact stored name');
    expect(meds.learned, ['Rabeprazole 20mg']);
    expect(rxText(t), 'Ra', reason: 'the prescription being typed is not changed');
    await typeRx(t, 'Ra');
    expect(suggestion('Ravi Kumar'), findsNothing);
    expect(suggestion('Rabeprazole 20mg'), findsOneWidget);
  });

  testWidgets('long-press, cancel: nothing is removed', (t) async {
    final meds = await openNote(t);
    await typeRx(t, 'Ra');
    await t.longPress(suggestion('Ravi Kumar'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Cancel'));
    await t.pumpAndSettle();
    expect(find.text(dialogTitle), findsNothing);
    expect(meds.removed, isEmpty);
    expect(meds.learned, ['Ravi Kumar', 'Rabeprazole 20mg']);
  });

  testWidgets('a refused removal tells the doctor and keeps the entry', (t) async {
    final meds = await openNote(t);
    meds.refuse = true;
    await typeRx(t, 'Ra');
    await t.longPress(suggestion('Ravi Kumar'));
    await t.pumpAndSettle();
    await t.tap(find.widgetWithText(TextButton, 'Remove'));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text("Couldn't remove it from suggestions. Try again in a moment."), findsOneWidget);
    expect(find.textContaining('not loaded'), findsNothing, reason: 'no internal error text');
    expect(meds.learned, ['Ravi Kumar', 'Rabeprazole 20mg']);
  });

  testWidgets('a tap still picks the suggestion', (t) async {
    final meds = await openNote(t);
    await typeRx(t, 'Ra');
    await t.tap(suggestion('Rabeprazole 20mg'));
    await t.pumpAndSettle();
    expect(rxText(t), startsWith('Rabeprazole 20mg'));
    expect(find.text(dialogTitle), findsNothing);
    expect(meds.removed, isEmpty);
  });
}
