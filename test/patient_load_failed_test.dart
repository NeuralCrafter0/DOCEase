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

/// Deletes that can be held open ([gate]) or refused ([refuse]).
class _Deleting extends _Patients {
  _Deleting({super.list});
  final deletes = <String>[];
  Completer<void>? gate;
  bool refuse = false;
  Future<void> _delete(String what, void Function() apply) async {
    deletes.add(what);
    if (gate != null) await gate!.future;
    if (refuse) throw StateError('refused'); // stands in for SaveRefusedException
    apply();
    notifyListeners();
  }
  @override
  Future<void> deleteRecord(String patientId, String recordId) => _delete('visit $recordId', () {
        _list = [for (final p in _list) p.id == patientId ? Patient(id: p.id, name: p.name, age: p.age, gender: p.gender, phone: p.phone, history: [for (final r in p.history) if (r.id != recordId) r]) : p];
      });
  @override
  Future<void> deletePatient(String id) => _delete('patient $id', () {
        _list = [for (final p in _list) if (p.id != id) p];
      });
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

  group('detail: open sheets on session end, reload failure and refused deletes', () {
    final sheetOpen = find.byTooltip('Share visit');
    Future<void> openDetailFromHome(WidgetTester t, PatientProvider p) async {
      await _pump(t, p, Builder(builder: (ctx) => Scaffold(body: TextButton(
        onPressed: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => const PatientDetailScreen(patientId: 'p1'))),
        child: const Text('open detail'),
      ))));
      await t.tap(find.text('open detail'));
      await t.pumpAndSettle();
    }
    Future<void> openSheet(WidgetTester t) async {
      await t.tap(find.text('Viral fever').first);
      await t.pumpAndSettle();
      expect(sheetOpen, findsOneWidget, reason: 'precondition');
    }

    testWidgets('session end closes the visit sheet and the detail screen: no diagnosis or symptoms left', (t) async {
      final p = _Patients(list: [_ravi]);
      await openDetailFromHome(t, p);
      await openSheet(t);
      p.endSession();
      await t.pump();
      expect(find.text('Fever'), findsNothing, reason: 'gone from the first frame, not only once the sheet has animated away');
      expect(find.text('Viral fever'), findsNothing);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Viral fever'), findsNothing);
      expect(find.text('Fever'), findsNothing);
      expect(find.text('Ravi Kumar'), findsNothing);
      expect(sheetOpen, findsNothing);
      expect(find.text('open detail'), findsOneWidget, reason: 'back on the first route, which is never popped');
    });

    testWidgets('session end with the delete confirm open closes it too', (t) async {
      final p = _Deleting(list: [_ravi]);
      await openDetailFromHome(t, p);
      await openSheet(t);
      await t.tap(find.byTooltip('Delete visit'));
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      p.endSession();
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      expect(sheetOpen, findsNothing);
      expect(find.text('open detail'), findsOneWidget);
    });

    testWidgets('a reload failing while the sheet is open removes its Edit/Delete', (t) async {
      final p = _Patients(list: [_ravi])..succeed = false;
      await openDetailFromHome(t, p);
      await openSheet(t);
      expect(find.byTooltip('Delete visit'), findsOneWidget);
      await p.reload();
      await t.pumpAndSettle();
      expect(p.loadFailed, isTrue);
      expect(find.byTooltip('Edit visit'), findsNothing);
      expect(find.byTooltip('Delete visit'), findsNothing);
      expect(sheetOpen, findsOneWidget, reason: 'reading and sharing stay available');
      expect(find.text('Fever'), findsWidgets);
    });

    testWidgets('refused visit delete: says so, sheet and screen stay open', (t) async {
      final p = _Deleting(list: [_ravi])..refuse = true;
      await openDetailFromHome(t, p);
      await openSheet(t);
      await t.tap(find.byTooltip('Delete visit'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(p.deletes, ['visit v1']);
      expect(find.text('Could not delete this visit. Nothing was deleted.'), findsOneWidget);
      expect(find.text('Delete'), findsNothing, reason: 'only the confirm closes');
      expect(sheetOpen, findsOneWidget, reason: 'the visit sheet stays open');
      expect(find.text('Ravi Kumar'), findsWidgets, reason: 'the detail screen stays open');
    });

    testWidgets('visit delete waits for the result; a second tap is ignored; success closes the sheet only', (t) async {
      final p = _Deleting(list: [_ravi])..gate = Completer<void>();
      await openDetailFromHome(t, p);
      await openSheet(t);
      await t.tap(find.byTooltip('Delete visit'));
      await t.pumpAndSettle();
      await t.tap(find.text('Delete'));
      await t.pump();
      await t.tap(find.text('Delete'));
      await t.pump();
      expect(p.deletes, ['visit v1'], reason: 'second tap while deleting is ignored');
      expect(find.text('Delete'), findsOneWidget, reason: 'nothing closes before the result is known');
      expect(sheetOpen, findsOneWidget);
      p.gate!.complete();
      await t.pumpAndSettle();
      expect(find.text('Delete'), findsNothing);
      expect(sheetOpen, findsNothing);
      expect(find.text('Ravi Kumar'), findsWidgets, reason: 'the detail screen stays');
      expect(find.text('open detail'), findsNothing);
      expect(find.textContaining('Could not delete'), findsNothing);
    });

    testWidgets('refused patient delete: says so and the detail screen stays open', (t) async {
      final p = _Deleting(list: [_ravi])..refuse = true;
      await openDetailFromHome(t, p);
      await t.tap(find.byIcon(Icons.delete_outline).first);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete All'));
      await t.pumpAndSettle();
      expect(p.deletes, ['patient p1']);
      expect(find.text('Could not delete this patient. Nothing was deleted.'), findsOneWidget);
      expect(find.text('Delete All'), findsNothing);
      expect(find.text('Ravi Kumar'), findsWidgets);
      expect(find.text('open detail'), findsNothing);
    });

    testWidgets('patient delete that works goes back to the list', (t) async {
      final p = _Deleting(list: [_ravi]);
      await openDetailFromHome(t, p);
      await t.tap(find.byIcon(Icons.delete_outline).first);
      await t.pumpAndSettle();
      await t.tap(find.text('Delete All'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('open detail'), findsOneWidget);
      expect(find.text('Ravi Kumar'), findsNothing);
    });
  });
}
