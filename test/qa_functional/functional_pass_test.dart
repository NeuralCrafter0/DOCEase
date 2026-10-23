// QA functional pass (local only, not committed). No Firebase: dev-mode
// wiring over the in-memory DB fake. Each test asserts the CORRECT behaviour;
// a failing test is a confirmed defect (see the report for steps).
import 'dart:io';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/dev/dev_mode_app.dart';
import 'package:docease/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/save_refused_exception.dart';

import 'harness.dart';

void main() => group('[needs --dart-define=DOCEASE_DEV_MODE=true]', _main, skip: !kDevMode);

void _main() {
  late Directory root;
  late Directory support;

  setUpAll(loadRealFonts);
  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_fp');
    support = Directory('${root.path}/support')..createSync();
  });
  tearDown(() {
    root.deleteSync(recursive: true);
  });

  group('F-DEV boot', () {
    testWidgets('F-DEV-01 dev mode opens on Home with the banner, no lock, no cloud', (t) async {
      await boot(t, support: support);
      expect(find.byType(DevModeHome), findsOneWidget);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text(kDevModeBannerText), findsOneWidget);
      expect(find.text('DOCEase Secured'), findsNothing);
      expect(find.text('No Clinical Records'), findsOneWidget);
      expect(hits, isEmpty, reason: '$hits');
    });
  });

  group('F-PAT patients', () {
    testWidgets('F-PAT-01 register a patient: listed, stored, survives restart', (t) async {
      var rig = await boot(t, support: support);
      await tapText(t, 'Register Patient');
      expect(find.text('Patient Registration'), findsOneWidget);
      expect(find.text(kDevModeBannerText), findsOneWidget, reason: 'banner on the form');
      await type(t, 'Enter patient name', 'Asha Verma');
      await type(t, 'Years', '34');
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.keyboardType == TextInputType.phone).first, '9876543210');
      await t.pump();
      await tapText(t, 'Register Profile');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      expect(find.text('Asha Verma'), findsOneWidget);
      expect(rig.db.rows.values.map((p) => p.name), contains('Asha Verma'));
      expect(rig.db.rows.values.single.phone, '+919876543210');
      rig = await restart(t, rig, support);
      expect(find.text('Asha Verma'), findsOneWidget);
      expect(hits, isEmpty, reason: '$hits');
    });

    testWidgets('F-PAT-02 validation: empty name, digits in name, age 121 are rejected; nothing saved', (t) async {
      final rig = await boot(t, support: support);
      await tapText(t, 'Register Patient');
      await tapText(t, 'Register Profile'); // submit empty form
      expect(find.text('Patient Registration'), findsOneWidget, reason: 'stays on the form');
      await type(t, 'Enter patient name', 'Asha 2');
      await type(t, 'Years', '121');
      await tapText(t, 'Register Profile');
      expect(find.text('Patient Registration'), findsOneWidget);
      expect(rig.db.rows, isEmpty);
    });

    testWidgets('F-PAT-03 edit a patient: name and age change, phone kept, survives restart', (t) async {
      var rig = QaDb();
      seedPatient(rig, 'p1', 'Ravi Kumar', phone: '+919812345678');
      var r = await boot(t, db: rig, support: support);
      await tapText(t, 'Ravi Kumar');
      await tapIcon(t, Icons.edit_outlined);
      expect(find.text('Edit Profile'), findsOneWidget);
      await type(t, 'Enter patient name', 'Ravi K Sharma');
      await type(t, 'Years', '41');
      await tapText(t, 'Save Changes');
      await settle(t);
      final stored = rig.rows['p1']!;
      expect(stored.name, 'Ravi K Sharma');
      expect(stored.age, '41');
      expect(stored.phone, '+919812345678', reason: 'phone must survive an edit');
      r = await restart(t, r, support);
      expect(find.text('Ravi K Sharma'), findsOneWidget);
    });

    testWidgets('F-PAT-03b edit keeps a non-Indian phone number (+1)', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'John Doe', phone: '+14155550123');
      await boot(t, db: db, support: support);
      await tapText(t, 'John Doe');
      await tapIcon(t, Icons.edit_outlined);
      await type(t, 'Years', '52');
      await tapText(t, 'Save Changes');
      await settle(t);
      expect(db.rows['p1']!.phone, '+14155550123');
    });

    testWidgets('F-PAT-04 delete a patient: confirm, gone from list, tombstoned, not back after restart', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Meena Iyer');
      var r = await boot(t, db: db, support: support);
      await tapText(t, 'Meena Iyer');
      await tapIcon(t, Icons.delete_outline);
      expect(find.text('Delete Patient Profile?'), findsOneWidget);
      final confirm = find.descendant(of: find.byType(BottomSheet), matching: find.byType(ElevatedButton));
      await t.tap(confirm.first);
      await settle(t);
      expect(find.text('Meena Iyer'), findsNothing);
      expect(db.rows, isEmpty);
      expect(db.tombstones, {'p1'});
      r = await restart(t, r, support);
      expect(find.text('Meena Iyer'), findsNothing);
      expect(hits, isEmpty, reason: '$hits');
    });

    testWidgets('F-PAT-04b cancel on the delete sheet keeps the patient', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Meena Iyer');
      await boot(t, db: db, support: support);
      await tapText(t, 'Meena Iyer');
      await tapIcon(t, Icons.delete_outline);
      await tapText(t, 'Cancel');
      expect(db.rows.keys, ['p1']);
      expect(db.tombstones, isEmpty);
    });

    testWidgets('F-PAT-05 refused save on register: user is told, patient not listed, no crash', (t) async {
      final rig = await boot(t, support: support);
      rig.db.refuseWrites = true;
      await tapText(t, 'Register Patient');
      await type(t, 'Enter patient name', 'Asha Verma');
      await type(t, 'Years', '34');
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.keyboardType == TextInputType.phone).first, '9876543210');
      await tapText(t, 'Register Profile');
      await settle(t);
      expect(find.text('Asha Verma'), findsNothing);
      expect(rig.db.rows, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget, reason: 'the doctor must be told the patient was not saved');
      expectNoPatientData(t, ['Asha', 'Verma', '9876543210']);
    });

    testWidgets('F-PAT-06 refused save on edit: old values shown, user is told', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Ravi Kumar');
      await boot(t, db: db, support: support);
      db.refuseWrites = true;
      await tapText(t, 'Ravi Kumar');
      await tapIcon(t, Icons.edit_outlined);
      await type(t, 'Enter patient name', 'Ravi Changed');
      await tapText(t, 'Save Changes');
      await settle(t);
      expect(db.rows['p1']!.name, 'Ravi Kumar');
      expect(find.text('Ravi Changed'), findsNothing, reason: 'screen reverts to what is stored');
      expect(find.byType(SnackBar), findsOneWidget, reason: 'the doctor must be told the edit was not saved');
      expectNoPatientData(t, ['Ravi', 'Kumar', 'Changed', '9876543210']);
    });
    // Backend contract (next #13 push): addPatient/updatePatient roll back and
    // throw SaveRefusedException, whose message never contains patient data.
    testWidgets('F-PAT-05p refused addPatient throws SaveRefusedException, rolls back, no patient data in message', (t) async {
      final rig = await boot(t, support: support);
      rig.db.refuseWrites = true;
      final p = Patient(name: 'Asha Verma', age: '34', gender: 'Female', phone: '9876543210', relation: 'Self', history: []);
      Object? err;
      await t.runAsync(() async { try { await rig.patients.addPatient(p); } catch (e) { err = e; } });
      await settle(t);
      expect(err, isA<SaveRefusedException>(), reason: 'got ${err?.runtimeType}');
      expectMessageClean(err, ['Asha', 'Verma', '9876543210', p.id]);
      expect(rig.patients.patients.where((x) => x.id == p.id), isEmpty, reason: 'not rolled back');
      expect(rig.db.rows, isEmpty);
    });
    testWidgets('F-PAT-06p refused updatePatient throws SaveRefusedException, keeps stored values', (t) async {
      final db = QaDb();
      final old = seedPatient(db, 'p1', 'Ravi Kumar');
      final rig = await boot(t, db: db, support: support);
      db.refuseWrites = true;
      final changed = Patient(id: 'p1', name: 'Ravi Changed', age: old.age, gender: old.gender, phone: old.phone, relation: old.relation, history: old.history);
      Object? err;
      await t.runAsync(() async { try { await rig.patients.updatePatient(changed); } catch (e) { err = e; } });
      await settle(t);
      expect(err, isA<SaveRefusedException>(), reason: 'got ${err?.runtimeType}');
      expectMessageClean(err, ['Ravi', 'Kumar', 'Changed', old.phone]);
      expect(rig.patients.patients.singleWhere((x) => x.id == 'p1').name, 'Ravi Kumar', reason: 'in-memory list not rolled back');
      expect(db.rows['p1']!.name, 'Ravi Kumar');
    });
  });
}

void expectNoPatientData(WidgetTester t, List<String> tokens) {
  final texts = find.descendant(of: find.byType(SnackBar), matching: find.byType(Text))
      .evaluate().map((e) => (e.widget as Text).data ?? '').join(' | ');
  for (final w in tokens) {
    expect(texts.toLowerCase().contains(w.toLowerCase()), isFalse, reason: 'SnackBar "$texts" contains "$w"');
  }
}

void expectMessageClean(Object? err, List<String> tokens) {
  final m = err.toString().toLowerCase();
  for (final w in tokens) {
    expect(m.contains(w.toLowerCase()), isFalse, reason: 'exception text "$err" contains "$w"');
  }
}
