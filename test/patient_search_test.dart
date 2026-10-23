// Regression tests for the patient search (QA feature pass F-SRCH-02,
// F-SRCH-04): phone numbers typed with spaces or +91, and family members
// hidden by an active search.
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/utils/patient_search.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

Patient patient(String id, String name, String phone) =>
    Patient(id: id, name: name, age: '30', gender: 'Male', phone: phone, history: []);

/// Behaves like the real provider while the doctor has typed [query] on the
/// home screen: [patients] is filtered, [allPatients] is not.
class SearchingProvider extends PatientProvider {
  final String query;
  final List<Patient> everyone;
  SearchingProvider(this.query, this.everyone);
  @override
  List<Patient> get patients => everyone
      .where((p) => p.name.toLowerCase().contains(query) || phoneMatchesQuery(p.phone, query))
      .toList();
  @override
  List<Patient> get allPatients => [...everyone];
  @override
  Patient findById(String id) => everyone.firstWhere((p) => p.id == id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('phoneMatchesQuery', () {
    const stored = '+919811111111';
    test('F-SRCH-02 matches a number typed with a space or +91', () {
      expect(phoneMatchesQuery(stored, '98111 11111'), isTrue);
      expect(phoneMatchesQuery(stored, '+91 9811111111'), isTrue);
      expect(phoneMatchesQuery(stored, '+91 98111-11111'), isTrue);
      expect(phoneMatchesQuery(stored, '098111 11111'), isTrue);
      expect(phoneMatchesQuery(stored, '9811111111'), isTrue);
      expect(phoneMatchesQuery(stored, '98111'), isTrue);
    });
    test('a number saved without +91 is found by a query with it', () {
      expect(phoneMatchesQuery('9811111111', '+91 98111 11111'), isTrue);
      expect(phoneMatchesQuery('98111 11111', '9811111111'), isTrue);
    });
    test('different numbers and plain words do not match', () {
      expect(phoneMatchesQuery(stored, '98222 22222'), isFalse);
      expect(phoneMatchesQuery(stored, '+91 9822222222'), isFalse);
      expect(phoneMatchesQuery(stored, 'rohan'), isFalse);
      expect(phoneMatchesQuery(stored, '   '), isFalse);
      expect(phoneMatchesQuery(stored, '+'), isFalse);
      expect(phoneMatchesQuery(stored, 'ravi 98'), isFalse);
    });
  });

  testWidgets('F-SRCH-04 an active search does not hide family members on the patient screen', (t) async {
    final rohan = patient('p1', 'Rohan', '+919811111111');
    final asha = patient('p2', 'Asha', '+919811111111');
    final other = patient('p3', 'Ravi', '+919822222222');
    final provider = SearchingProvider('rohan', [rohan, asha, other]);
    expect(provider.patients.map((p) => p.name), ['Rohan']);
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: provider),
        ChangeNotifierProvider<DoctorProvider>.value(value: DoctorProvider()),
      ],
      child: const MaterialApp(home: PatientDetailScreen(patientId: 'p1')),
    ));
    await t.pumpAndSettle();
    expect(find.text('Family Network'), findsOneWidget);
    expect(find.textContaining('Asha'), findsWidgets);
    expect(find.textContaining('Ravi'), findsNothing);
  });
}
