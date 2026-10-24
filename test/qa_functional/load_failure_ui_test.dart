// Widget side of the load-failure contract on the merge (#16 3a695b0 loadFailed/
// reload(), #20 4b2b897 screens). Dev mode, no Firebase:
//   flutter test --no-pub --dart-define=DOCEASE_DEV_MODE=true test/qa_functional/load_failure_ui_test.dart
// Agreed UI: "Couldn't load records" + Retry on Home and in search; Add, edit and
// delete hidden or disabled; a startup read failure never shows the empty list.
import 'dart:io';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const kLoadError = "Couldn't load records";
const kRetry = 'Retry';
// #20: a failed reload over a non-empty list keeps the rows and shows a banner instead.
const kStale = "Couldn't refresh. ";
const kStaleTail = 'Editing is paused.';
// Failing-first (#20 Lows from security's polish review): run with
// --dart-define=QA_FAILING_FIRST=true; they fail until the sheet is fixed.
const _ff = bool.fromEnvironment('QA_FAILING_FIRST');
const kEmpty = 'No Clinical Records';
const kAdd = 'Register Patient';

class _FailQaDb extends QaDb {
  bool get failReads => strictReadFailure != null;
  set failReads(bool v) => strictReadFailure = v ? DbReadFailure.readFailed : null;
  @override
  Future<List<Patient>> fetchPatients() async =>
      failReads ? <Patient>[] : super.fetchPatients();
}

/// The add control is either absent or disabled.
void expectNoAdd() {
  final fab = find.widgetWithText(FloatingActionButton, kAdd);
  if (fab.evaluate().isEmpty) return;
  expect(
      (fab.evaluate().single.widget as FloatingActionButton).onPressed, isNull,
      reason: 'Add patient offered while records could not be loaded');
}

void expectNoEditDelete() {
  for (final icon in [Icons.edit_outlined, Icons.delete_outline]) {
    for (final e in find.widgetWithIcon(IconButton, icon).evaluate()) {
      expect((e.widget as IconButton).onPressed, isNull,
          reason: '$icon enabled while loadFailed');
    }
  }
}

void main() => group('[needs --dart-define=DOCEASE_DEV_MODE=true]', _main,
    skip: !kDevMode);

void _main() {
  late Directory root;
  late Directory support;

  setUpAll(loadRealFonts);
  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_lf_ui');
    support = Directory('${root.path}/support')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('UI-01 startup read failure: error + Retry, no empty list, '
      'no Add patient', (t) async {
    final db = _FailQaDb()..failReads = true;
    seedPatient(db, 'p1', 'Asha');
    await boot(t, db: db, support: support);
    expect(find.text(kLoadError), findsOneWidget);
    expect(find.text(kRetry), findsOneWidget);
    expect(find.text(kEmpty), findsNothing,
        reason: 'an unreadable DB must not look like "no patients"');
    expectNoAdd();
    expect(hits, isEmpty, reason: '$hits');
  });

  testWidgets('UI-02 search shows the same error, not "no results"',
      (t) async {
    final db = _FailQaDb()..failReads = true;
    seedPatient(db, 'p1', 'Asha');
    await boot(t, db: db, support: support);
    await type(t, 'Search patients...', 'Asha');
    await settle(t);
    expect(find.text(kLoadError), findsOneWidget);
    expect(find.text(kEmpty), findsNothing);
    expectNoAdd();
  });

  testWidgets('UI-03 Retry after recovery shows the list and Add patient',
      (t) async {
    final db = _FailQaDb()..failReads = true;
    seedPatient(db, 'p1', 'Asha');
    await boot(t, db: db, support: support);
    db.failReads = false;
    await tapText(t, kRetry);
    await settle(t);
    expect(find.text(kLoadError), findsNothing);
    expect(find.text('Asha'), findsWidgets);
    final fab = find.widgetWithText(FloatingActionButton, kAdd);
    expect(fab, findsOneWidget);
    expect((fab.evaluate().single.widget as FloatingActionButton).onPressed,
        isNotNull);
  });

  testWidgets('UI-04 failed reload over a stale list: edit/delete disabled',
      (t) async {
    final db = _FailQaDb();
    seedPatient(db, 'p1', 'Asha');
    final rig = await boot(t, db: db, support: support);
    db.failReads = true;
    await t.runAsync(rig.patients.reload);
    await settle(t);
    expect(find.text(kLoadError), findsNothing,
        reason: 'a stale list is not replaced by the full error view');
    expect(find.textContaining(kStale, findRichText: true), findsOneWidget);
    expect(find.textContaining(kStaleTail, findRichText: true), findsOneWidget);
    expect(find.text('Asha'), findsWidgets, reason: 'failed reload keeps the old list');
    expectNoAdd();
    // Stale rows may stay visible; opening one must not offer edit/delete.
    if (find.text('Asha').evaluate().isNotEmpty) {
      await tapText(t, 'Asha');
      await settle(t);
      expectNoEditDelete();
    }
  });

  // --------------------------------------------------- #20 Lows (failing-first)
  // Both sheets come from _showRecordDetails (patient_detail_screen.dart:221),
  // which reads the record and PatientLoad.readOnly once, when it opens.
  const symptoms = 'QA-SYMPTOM-7f3a chest tightness';
  const diagnosis = 'QA-DIAG-7f3a angina';
  QaDb seededVisit() {
    final db = _FailQaDb();
    seedPatient(db, 'p1', 'Asha', history: [
      visitOn('v1', DateTime(2026, 3, 4), symptoms: symptoms, diagnosis: diagnosis),
    ]);
    return db;
  }

  // Sheet-only markers (the visit card on the detail screen also shows symptoms).
  bool sheetOpen() =>
      find.text('Chief Symptoms').evaluate().isNotEmpty || find.byTooltip('Share visit').evaluate().isNotEmpty;
  bool detailOpen() => find.byTooltip('Vitals trends').evaluate().isNotEmpty;

  Future<void> openSheet(WidgetTester t) async {
    await tapText(t, 'Asha');
    await tapText(t, diagnosis); // visit card on the detail screen
    await settle(t);
    expect(sheetOpen(), isTrue, reason: 'details sheet open (precondition)');
    expect(find.byTooltip('Delete visit'), findsOneWidget, reason: 'precondition: writable before the reload fails');
  }

  testWidgets('LOW20-1 visit-details sheet open when the session ends: no diagnosis/symptoms stay on screen',
      (t) async {
    final rig = await boot(t, db: seededVisit(), support: support);
    await openSheet(t);
    // Session end = SessionController._clearProviders() (patients/doctor/medicines
    // clear), which is what the auth-change and signOut teardown run first. Local-only
    // dev mode has no account, so the harness runs that same teardown directly.
    rig.patients.clear();
    rig.doctor.clear();
    rig.medicines.clear();
    await settle(t);
    expect(rig.patients.patients, isEmpty, reason: 'teardown ran');
    expect(sheetOpen() && find.text(symptoms).evaluate().isNotEmpty, isFalse,
        reason: 'sheet left open after session end still shows symptoms');
    expect(find.textContaining(diagnosis), findsNothing,
        reason: 'sheet left open after session end still shows the diagnosis');
  }, skip: !_ff);

  testWidgets('LOW20-2a sheet opened before a failed reload: Edit/Delete gone or disabled',
      (t) async {
    final rig = await boot(t, db: seededVisit(), support: support);
    await openSheet(t);
    (rig.db as _FailQaDb).failReads = true;
    await t.runAsync(rig.patients.reload);
    await settle(t);
    expect(rig.patients.loadFailed, isTrue, reason: 'precondition');
    for (final tip in ['Edit visit', 'Delete visit']) {
      for (final e in find.byTooltip(tip).evaluate()) {
        final b = e.findAncestorWidgetOfExactType<IconButton>();
        expect(b?.onPressed, isNull, reason: '"$tip" still offered after loadFailed');
      }
    }
    expectNoEditDelete();
  }, skip: !_ff);

  testWidgets('LOW20-2b delete confirmed after a failed reload: refused, record kept, '
      'screens do not close as if it worked', (t) async {
    final rig = await boot(t, db: seededVisit(), support: support);
    await openSheet(t);
    (rig.db as _FailQaDb).failReads = true;
    await t.runAsync(rig.patients.reload);
    await settle(t);
    expect(rig.patients.loadFailed, isTrue, reason: 'precondition');
    final del = find.byTooltip('Delete visit');
    if (del.evaluate().isEmpty) return; // 2a fixed by hiding: nothing to confirm
    await t.tap(del);
    await settle(t);
    await tapText(t, 'Delete'); // confirm sheet button
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(t);
    expect(rig.db.rows['p1']!.history.map((r) => r.id), ['v1'],
        reason: 'delete must be refused while loadFailed');
    expect(find.textContaining('Could not delete'), findsOneWidget,
        reason: 'the refusal is reported');
    expect(detailOpen(), isTrue, reason: 'detail screen closed as if the delete had worked');
    expect(sheetOpen(), isTrue,
        reason: 'details sheet closed before the result was known, as if the delete had worked');
  }, skip: !_ff);
}
