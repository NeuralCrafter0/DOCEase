// Regression tests for date-based visit ordering (QA case UI-04).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/utils/visit_order.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

VisitRecord visit(String id, DateTime date, String dx) =>
    VisitRecord(id: id, date: date, visitType: 'Routine', symptoms: 's-$dx', diagnosis: dx, prescription: 'rx-$dx');

// A backdated note added last ends up at index 0 (addRecord inserts at 0).
final older = visit('r-old', DateTime(2024, 1, 1), 'OLD-DX');
final newer = visit('r-new', DateTime(2026, 10, 1), 'NEW-DX');
Patient fixture() => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '+919999999999', history: [older, newer]);

class FakePatientProvider extends PatientProvider {
  final Patient p = fixture();
  @override
  List<Patient> get patients => [p];
  @override
  Patient findById(String id) => p;
}

class FakeMedicineProvider extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
}

class NoDoctor extends DoctorProvider {
  @override
  Doctor? get currentDoctor => null;
}

Future<void> pump(WidgetTester t, Widget home) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: FakePatientProvider()),
      ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider()),
      ChangeNotifierProvider<DoctorProvider>.value(value: NoDoctor()),
    ],
    child: MaterialApp(home: home),
  ));
  await t.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('VisitHistoryOrder', () {
    test('newestFirst sorts by date, newest first', () {
      expect([older, newer].newestFirst().map((r) => r.id), ['r-new', 'r-old']);
      expect([newer, older].newestFirst().map((r) => r.id), ['r-new', 'r-old']);
    });

    test('same-date visits keep stored order (most recently added first)', () {
      final a = visit('a', DateTime(2026, 5, 5), 'A');
      final b = visit('b', DateTime(2026, 5, 5), 'B');
      final c = visit('c', DateTime(2026, 5, 5), 'C');
      expect([a, b, older, c].newestFirst().map((r) => r.id), ['a', 'b', 'c', 'r-old']);
    });

    test('latestVisit', () {
      expect(<VisitRecord>[].latestVisit, isNull);
      expect([older, newer].latestVisit!.id, 'r-new');
    });

    test('does not reorder the stored list', () {
      final list = [older, newer];
      list.newestFirst();
      expect(list.first.id, 'r-old');
    });
  });

  testWidgets('UI-04 "Repeat Last" copies the visit with the latest date', (t) async {
    await pump(t, const AddRecordScreen(patientId: 'p1'));
    await t.tap(find.text('Repeat Last'));
    await t.pumpAndSettle();
    expect(find.text('NEW-DX'), findsOneWidget);
    expect(find.text('OLD-DX'), findsNothing);
  });

  testWidgets('UI-04 detail screen: "Last Visit" and timeline follow visit date', (t) async {
    await pump(t, const PatientDetailScreen(patientId: 'p1'));
    expect(find.text('01 Oct'), findsOneWidget, reason: 'Last Visit shows the newest date');
    final newY = t.getTopLeft(find.text('NEW-DX')).dy;
    final oldY = t.getTopLeft(find.text('OLD-DX')).dy;
    expect(newY, lessThan(oldY), reason: 'newest visit is at the top of the timeline');
  });
}
