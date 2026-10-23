// Regression tests for deleting a patient from the detail screen (QA UI-07).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

/// Same list semantics as the real provider: findById has no orElse.
class ListPatientProvider extends PatientProvider {
  final List<Patient> list;
  final List<String> deleted = [];
  ListPatientProvider(this.list);
  @override
  List<Patient> get patients => [...list];
  @override
  Patient findById(String id) => list.firstWhere((p) => p.id == id);
  @override
  Future<void> deletePatient(String id) async {
    deleted.add(id);
    list.removeWhere((p) => p.id == id);
    notifyListeners();
  }
}

class NoDoctor extends DoctorProvider {
  @override
  Doctor? get currentDoctor => null;
}

Patient asha() => Patient(id: 'p1', name: 'Asha', age: '34', gender: 'Female', phone: '+919999999999', history: [
      VisitRecord(id: 'r1', date: DateTime(2026, 10, 1), visitType: 'Routine', symptoms: 'cough', diagnosis: 'URTI', prescription: 'Rx'),
    ]);

Future<ListPatientProvider> openDetail(WidgetTester t) async {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  final pp = ListPatientProvider([asha()]);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: pp),
      ChangeNotifierProvider<DoctorProvider>.value(value: NoDoctor()),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () => Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => const PatientDetailScreen(patientId: 'p1'))),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return pp;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  testWidgets('UI-07 "Delete All" deletes, closes the screen and does not throw', (t) async {
    final pp = await openDetail(t);
    await t.tap(find.byIcon(Icons.delete_outline).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Delete All'));
    await t.pump();
    expect(t.takeException(), isNull);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(pp.deleted, ['p1']);
    expect(find.byType(PatientDetailScreen), findsNothing);
    expect(find.text('open'), findsOneWidget, reason: 'back on the previous screen');
  });

  testWidgets('Cancel keeps the patient', (t) async {
    final pp = await openDetail(t);
    await t.tap(find.byIcon(Icons.delete_outline).first);
    await t.pumpAndSettle();
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(pp.deleted, isEmpty);
    expect(find.text('Asha'), findsWidgets);
  });

  testWidgets('patient removed elsewhere while the screen is open does not crash', (t) async {
    final pp = await openDetail(t);
    await pp.deletePatient('p1'); // e.g. removed by a sync
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(find.text('URTI'), findsNothing);
  });
}
