// Design review screenshots, not a regression test. Run with
//   SHOTS=1 flutter test test/shots --update-goldens
// PNGs land in test/shots/goldens/ (git-ignored).
@Tags(['shots'])
library;

import 'dart:io';

import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/home_screen.dart';
import 'package:docease/screens/add_patient_screen.dart';
import 'package:docease/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'shot_fonts.dart';

final _now = DateTime.now();
DateTime _ago(int d, [int h = 10]) => DateTime(_now.year, _now.month, _now.day - d, h);
VisitRecord _v(String id, DateTime d) =>
    VisitRecord(id: id, date: d, visitType: 'Follow-up', symptoms: 'Cough', diagnosis: 'Viral fever', prescription: 'Paracetamol - 1-0-1');

final _patients = [
  Patient(id: 'a1', name: 'Asha Verma', age: '34', gender: 'Female', phone: '+919811111111', history: [_v('1', _ago(0, 9)), _v('2', _ago(40))]),
  Patient(id: 'b2', name: 'Ravi Kumar', age: '42', gender: 'Male', phone: '+919876543210', history: [_v('3', _ago(1))]),
  Patient(id: 'c3', name: 'Meena Iyer', age: '67', gender: 'Female', phone: '+919900112233', relation: 'Mother', history: [_v('4', _ago(3)), _v('5', _ago(90)), _v('6', _ago(200))]),
  Patient(id: 'd4', name: 'Kiran Rao', age: '8', gender: 'Male', phone: '+919845012345', relation: 'Son', history: [_v('7', _ago(0, 11))]),
  Patient(id: 'e5', name: 'Farhan Sheikh', age: '29', gender: 'Male', phone: '+919812300000', history: [_v('8', _ago(21))]),
  Patient(id: 'f6', name: 'Lakshmi Narayanan Subramaniam', age: '51', gender: 'Female', phone: '+919811100022', history: []),
  Patient(id: 'g7', name: 'Priya Desai', age: '23', gender: 'Female', phone: '+919822233344', history: [_v('9', _ago(400))]),
];

class _Patients extends PatientProvider {
  _Patients(this._list, {this.failed = false, this.query = '', this.loaded = true});
  final List<Patient> _list;
  final bool failed;
  final bool loaded;
  @override
  bool get hasLoaded => loaded;
  final String query;
  @override
  bool get loadFailed => failed;
  @override
  List<Patient> get patients => query.isEmpty ? _list : [for (final p in _list) if (p.name.toLowerCase().contains(query)) p];
  // ignore: annotate_overrides
  List<Patient> get allPatients => _list;
  @override
  bool get isSyncing => false;
  @override
  Future<void> fetchAndSetPatients() async {}
  @override
  void setSearchQuery(String q) {}
}

class _Doctor extends DoctorProvider {
  _Doctor(this.d);
  final Doctor? d;
  @override
  Doctor? get currentDoctor => d;
  @override
  bool get isLoading => false;
  @override
  Future<void> fetchDoctorProfile() async {}
}

final _doc = Doctor(id: 'd1', title: 'Dr.', name: 'Anjali Mehta', email: 'a@clinic.test', age: '45', mobileNumber: '+919812345678', specialty: 'General Medicine', clinicName: 'Sunrise Clinic', practiceMode: 'Solo Practice');

Future<void> _shot(WidgetTester t, String name, {required PatientProvider p, Doctor? doctor, Widget home = const HomeScreen(), Size size = const Size(390, 844), double text = 1, bool dark = false, Future<void> Function(WidgetTester)? act}) async {
  debugDisableShadows = false;
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: p),
      ChangeNotifierProvider<DoctorProvider>.value(value: _Doctor(doctor)),
    ],
    child: MaterialApp(
      key: ValueKey(name),
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      builder: (c, child) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(text)), child: child!),
      home: home,
    ),
  ));
  await t.pump(const Duration(milliseconds: 50));
  if (act != null) await act(t);
  await t.pump(const Duration(milliseconds: 400));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
}

void main() {
  final enabled = Platform.environment['SHOTS'] == '1';
  setUpAll(() async {
    if (enabled) await loadShotFonts();
  });

  testWidgets('home shots', (t) async {
    await _shot(t, 'home_list', p: _Patients(_patients), doctor: _doc);
    await _shot(t, 'home_list_dark', p: _Patients(_patients), doctor: _doc, dark: true);
    await _shot(t, 'home_empty', p: _Patients(const []), doctor: _doc);
    await _shot(t, 'home_loading', p: _Patients(const [], loaded: false), doctor: _doc);
    await _shot(t, 'home_failed', p: _Patients(const [], failed: true), doctor: null);
    await _shot(t, 'home_stale', p: _Patients(_patients, failed: true), doctor: _doc);
    await _shot(t, 'home_nomatch', p: _Patients(_patients, query: 'zz'), doctor: _doc, act: (t) async {
      await t.enterText(find.byType(TextField), 'zz');
    });
    await _shot(t, 'home_text2x', p: _Patients(_patients), doctor: _doc, size: const Size(360, 780), text: 2);
    await _shot(t, 'home_small', p: _Patients(_patients), doctor: _doc, size: const Size(320, 640));
    await _shot(t, 'home_wide', p: _Patients(_patients), doctor: _doc, size: const Size(1280, 800));
    await _shot(t, 'home_drawer', p: _Patients(_patients), doctor: _doc, act: (t) async {
      await t.tap(find.byTooltip('Open menu'));
      await t.pumpAndSettle();
    });
    await _shot(t, 'home_scrolled', p: _Patients(_patients), doctor: _doc, act: (t) async {
      await t.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await t.pump();
    });
    debugDisableShadows = true;
  }, skip: !enabled);

  testWidgets('patient form shots', (t) async {
    debugDisableShadows = false;
    await _shot(t, 'form_new', p: _Patients(_patients), home: const AddPatientScreen());
    await _shot(t, 'form_errors', p: _Patients(_patients), home: const AddPatientScreen(), act: (t) async {
      await t.tap(find.byKey(const ValueKey('patientForm.save')));
      await t.pump();
    });
    await _shot(t, 'form_edit', p: _Patients(_patients), home: AddPatientScreen(existingPatient: _patients[2]));
    await _shot(t, 'form_dup', p: _Patients(_patients), home: const AddPatientScreen(), act: (t) async {
      await t.enterText(find.byKey(const ValueKey('patientForm.name')), 'asha  verma');
      await t.enterText(find.byKey(const ValueKey('patientForm.age')), '34');
      await t.enterText(find.byKey(const ValueKey('patientForm.phone')), '9811111111');
      await t.tap(find.byKey(const ValueKey('patientForm.save')));
      await t.pumpAndSettle();
    });
    await _shot(t, 'form_text2x', p: _Patients(_patients), home: AddPatientScreen(existingPatient: _patients[2]), size: const Size(360, 780), text: 2);
    debugDisableShadows = true;
  }, skip: !enabled);
}
