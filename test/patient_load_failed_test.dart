// "Couldn't load records": home list/search and detail actions when the
// strict patient read fails (backend contract on #16: `bool get loadFailed`,
// `Future<void> reload()`, writes refused while loadFailed).
// ignore_for_file: depend_on_referenced_packages (firebase_core_platform_interface test mocks, as in the other widget tests)
import 'dart:async';

import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/home_screen.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/theme/app_theme.dart';
import 'package:docease/utils/patient_load.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final _now = DateTime.now();
final _visit = VisitRecord(id: 'v1', date: DateTime(_now.year, _now.month, _now.day, 9), visitType: 'Initial', symptoms: 'Fever', diagnosis: 'Viral fever', prescription: 'Paracetamol - 1-0-1', bp: '120/80', temp: '101');
final _ravi = Patient(id: 'p1', name: 'Ravi Kumar', age: '42', gender: 'Male', phone: '+919876543210', history: [_visit]);
final _doc = Doctor(id: 'd1', title: 'MR', name: 'John', email: 'john@clinic.test', age: '45', mobileNumber: '+919812345678', specialty: 'General Medicine', clinicName: 'City Clinic', practiceMode: 'Solo Practice');

/// Fake of the #16 provider contract (loadFailed / reload()).
class _Patients extends PatientProvider {
  _Patients({List<Patient> list = const [], bool failed = false})
      : _list = list,
        _failed = failed;

  List<Patient> _list;
  bool _failed;
  int reloads = 0;

  /// What the next reload does: null = succeed with [onSuccess]; otherwise
  /// the reload waits for this completer, then applies [onSuccess] only if
  /// [succeed] is true.
  Completer<void>? gate;
  bool succeed = true;
  List<Patient> onSuccess = const [];

  @override
  bool get loadFailed => _failed;

  @override
  Future<void> reload() async {
    reloads++;
    if (gate != null) await gate!.future;
    if (succeed) {
      _list = onSuccess;
      _failed = false;
    } else {
      _failed = true; // a failed reload keeps the old list
    }
    notifyListeners();
  }

  /// Session end / owner change: the provider clears list and loadFailed.
  void endSession() {
    _list = const [];
    _failed = false;
    notifyListeners();
  }

  @override
  List<Patient> get patients => _list;
  // ignore: annotate_overrides
  List<Patient> get allPatients => _list;
  @override
  bool get isSyncing => false;
  @override
  Future<void> fetchAndSetPatients() async {}
  @override
  Patient findById(String id) => _list.firstWhere((p) => p.id == id);
}

class _Doctor extends DoctorProvider {
  @override
  Doctor? get currentDoctor => _doc;
  @override
  bool get isLoading => false;
  @override
  Future<void> fetchDoctorProfile() async {}
}

class _Meds extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

Future<void> _pump(WidgetTester t, PatientProvider patients, Widget screen) async {
  t.view.physicalSize = const Size(1200, 2800);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  // The test font is wider than real fonts, so ignore overflow stripes.
  final prev = FlutterError.onError;
  FlutterError.onError = (d) {
    if (!d.exceptionAsString().contains('overflowed by')) prev?.call(d);
  };
  addTearDown(() => FlutterError.onError = prev);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: patients),
      ChangeNotifierProvider<DoctorProvider>.value(value: _Doctor()),
      ChangeNotifierProvider<MedicineProvider>.value(value: _Meds()),
    ],
    child: MaterialApp(theme: AppTheme.light(), home: screen),
  ));
  await t.pumpAndSettle();
}

final _failedTitle = find.text("Couldn't load records");
final _empty = find.text('No Clinical Records');
final _register = find.text('Register Patient');
final _retry = find.widgetWithText(FilledButton, 'Retry');
final _banner = find.textContaining("Couldn't refresh");

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('home: empty vs failed', () {
    testWidgets('a successful empty load shows the empty state and Register', (t) async {
      await _pump(t, _Patients(), const HomeScreen());
      expect(_empty, findsOneWidget);
      expect(_register, findsOneWidget);
      expect(_failedTitle, findsNothing);
      expect(_banner, findsNothing);
    });

    testWidgets('a failed first load shows the error with Retry, never the empty state', (t) async {
      await _pump(t, _Patients(failed: true), const HomeScreen());
      expect(_failedTitle, findsOneWidget);
      expect(_retry, findsOneWidget);
      expect(_empty, findsNothing, reason: 'an empty list after a failed read leads to duplicate registrations');
      expect(_register, findsNothing);
      expect(find.byType(FloatingActionButton), findsNothing);
      // Daily Pulse says "unknown", not 0.
      expect(find.text('\u2014'), findsNWidgets(2));
      expect(find.text('0'), findsNothing);
    });

    testWidgets('search while failed still shows the error, not "no results"', (t) async {
      await _pump(t, _Patients(failed: true), const HomeScreen());
      await t.enterText(find.byType(TextField), '98765');
      await t.pumpAndSettle();
      expect(_failedTitle, findsOneWidget);
      expect(_empty, findsNothing);
    });
  });

  group('home: retry', () {
    testWidgets('failed load, then Retry succeeds: list and Register come back', (t) async {
      final p = _Patients(failed: true)
        ..gate = Completer<void>()
        ..onSuccess = [_ravi];
      await _pump(t, p, const HomeScreen());

      await t.tap(_retry);
      await t.pump();
      expect(p.reloads, 1);
      // In flight: disabled with a spinner, so a second tap does nothing.
      expect(t.widget<FilledButton>(_retry).onPressed, isNull);
      expect(find.descendant(of: _retry, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      await t.tap(_retry, warnIfMissed: false);
      await t.pump();
      expect(p.reloads, 1);

      p.gate!.complete();
      await t.pumpAndSettle();
      expect(_failedTitle, findsNothing);
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(_register, findsOneWidget);
    });

    testWidgets('Retry that fails again keeps the error and re-enables Retry', (t) async {
      final p = _Patients(failed: true)..succeed = false;
      await _pump(t, p, const HomeScreen());
      await t.tap(_retry);
      await t.pumpAndSettle();
      expect(p.reloads, 1);
      expect(_failedTitle, findsOneWidget);
      expect(_empty, findsNothing);
      expect(_register, findsNothing);
      expect(t.widget<FilledButton>(_retry).onPressed, isNotNull);
    });

    testWidgets('session end clears loadFailed: the screen follows the provider', (t) async {
      final p = _Patients(failed: true);
      await _pump(t, p, const HomeScreen());
      p.endSession();
      await t.pumpAndSettle();
      expect(_failedTitle, findsNothing);
      expect(_empty, findsOneWidget);
    });
  });

  group('home: stale list after a failed reload', () {
    testWidgets('shows the old list read-only under a "Couldn\'t refresh" banner', (t) async {
      final p = _Patients(list: [_ravi], failed: true)..onSuccess = [_ravi];
      await _pump(t, p, const HomeScreen());
      expect(find.text('Ravi Kumar'), findsOneWidget);
      expect(_banner, findsOneWidget);
      expect(_failedTitle, findsNothing);
      expect(_register, findsNothing);

      await t.tap(find.widgetWithText(TextButton, 'Retry'));
      await t.pumpAndSettle();
      expect(p.reloads, 1);
      expect(_banner, findsNothing);
      expect(_register, findsOneWidget);
    });
  });

  group('detail: writes hidden while loadFailed', () {
    Future<void> openVisitSheet(WidgetTester t) async {
      await t.tap(find.text('Viral fever').first);
      await t.pumpAndSettle();
    }

    testWidgets('stale patient: no edit, delete or add-note; visit sheet keeps Share only', (t) async {
      await _pump(t, _Patients(list: [_ravi], failed: true), const PatientDetailScreen(patientId: 'p1'));
      expect(find.text('Ravi Kumar'), findsWidgets);
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(find.text('Add Clinical Note'), findsNothing);
      expect(find.byTooltip('Export PDF'), findsOneWidget, reason: 'reading and printing stay available');

      await openVisitSheet(t);
      expect(find.byTooltip('Share visit'), findsOneWidget);
      expect(find.byTooltip('Edit visit'), findsNothing);
      expect(find.byTooltip('Delete visit'), findsNothing);
    });

    testWidgets('loaded patient: all actions present (control)', (t) async {
      await _pump(t, _Patients(list: [_ravi]), const PatientDetailScreen(patientId: 'p1'));
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.text('Add Clinical Note'), findsOneWidget);

      await openVisitSheet(t);
      expect(find.byTooltip('Edit visit'), findsOneWidget);
      expect(find.byTooltip('Delete visit'), findsOneWidget);
    });
  });
}
