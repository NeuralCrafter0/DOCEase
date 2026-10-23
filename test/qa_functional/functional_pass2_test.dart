// QA functional pass, batch 2 (local only, not committed).
import 'dart:io';

import 'package:docease/config/dev_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() => group('[needs --dart-define=DOCEASE_DEV_MODE=true]', _main, skip: !kDevMode);

void _main() {
  late Directory root;
  late Directory support;

  setUpAll(loadRealFonts);
  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_fp2');
    support = Directory('${root.path}/support')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> openPatient(WidgetTester t, String name) => tapText(t, name);
  Future<void> openNewVisit(WidgetTester t) => tapText(t, 'Add Clinical Note');
  Future<void> saveVisit(WidgetTester t) async {
    await tapText(t, 'Save Clinical Record');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle(t);
  }

  Future<void> openDrawerItem(WidgetTester t, String item) async {
    await t.tap(find.byTooltip('Open navigation menu'));
    await settle(t);
    await tapText(t, item);
  }

  // ------------------------------------------------------------------ visits
  group('F-VIS visits', () {
    testWidgets('F-VIS-01 add a visit: shown on the timeline, stored, survives restart', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      var r = await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      expect(find.text('No Clinical Records Available'), findsOneWidget);
      await openNewVisit(t);
      expect(find.text(kDevModeBannerText), findsOneWidget, reason: 'banner on the visit form');
      await type(t, 'Diagnosis', 'Acute bronchitis');
      await type(t, 'Chief Symptoms', 'cough, mild fever');
      await type(t, '120/80', '130/85');
      await type(t, '72 bpm', '88');
      await type(t, 'Type medicine name...', 'Azithromycin 500mg');
      await saveVisit(t);
      expect(find.text('Clinical Timeline'), findsOneWidget, reason: 'back on the patient screen');
      expect(find.textContaining('Acute bronchitis'), findsWidgets);
      final h = db.rows['p1']!.history;
      expect(h, hasLength(1));
      expect(h.single.diagnosis, 'Acute bronchitis');
      expect(h.single.bp, '130/85');
      expect(h.single.pulse, '88');
      r = await restart(t, r, support);
      await openPatient(t, 'Asha Verma');
      expect(find.textContaining('Acute bronchitis'), findsWidgets);
      expect(hits, isEmpty, reason: '$hits');
    });

    testWidgets('F-VIS-02 edit a visit from its sheet: change stored, same record id', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma', history: [visitOn('v1', DateTime(2026, 3, 1), diagnosis: 'Viral fever')]);
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await tapText(t, 'Viral fever');
      await tapIconLast(t, Icons.edit_outlined);
      await type(t, 'Diagnosis', 'Dengue fever');
      await saveVisit(t);
      final h = db.rows['p1']!.history;
      expect(h, hasLength(1), reason: 'edit must not add a second visit');
      expect(h.single.id, 'v1');
      expect(h.single.diagnosis, 'Dengue fever');
      expect(find.textContaining('Dengue fever'), findsWidgets);
    });

    testWidgets('F-VIS-03 delete a visit from its sheet', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma', history: [
        visitOn('v1', DateTime(2026, 3, 1), diagnosis: 'Viral fever'),
        visitOn('v2', DateTime(2026, 2, 1), diagnosis: 'Migraine'),
      ]);
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await tapText(t, 'Migraine');
      await tapIconLast(t, Icons.delete_outline);
      expect(find.text('Delete Visit Record?'), findsOneWidget);
      // a confirm step, if any
      final confirm = find.widgetWithText(ElevatedButton, 'Delete');
      if (confirm.evaluate().isNotEmpty) {
        await t.tap(confirm.first);
        await settle(t);
      }
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      expect(db.rows['p1']!.history.map((v) => v.id), ['v1']);
      expect(find.text('Migraine'), findsNothing);
    });

    testWidgets('F-VIS-04 refused visit save: message, stays on the form, nothing changes', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      db.refuseUpdates = true;
      await type(t, 'Diagnosis', 'Acute bronchitis');
      await saveVisit(t);
      expect(find.text('Could not save this visit. Please try again.'), findsOneWidget);
      expect(find.text('Save Clinical Record'), findsOneWidget, reason: 'stays on the form');
      expect(db.rows['p1']!.history, isEmpty);
      // back to the patient: timeline must not show the refused visit
      db.refuseUpdates = false;
      await t.pageBack();
      await settle(t);
      expect(find.textContaining('Acute bronchitis'), findsNothing);
      expect(find.text('No Clinical Records Available'), findsOneWidget);
    });

    testWidgets('F-VIS-05 [r3, refused, r1]: a refused save in between leaves r1 and r3 only', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      final r = await boot(t, db: db, support: support);
      await t.runAsync(() async {
        await r.patients.addRecord('p1', visitOn('r3', DateTime(2026, 3, 3), diagnosis: 'three'));
        db.refuseUpdates = true;
        await expectLater(r.patients.addRecord('p1', visitOn('rx', DateTime(2026, 3, 2), diagnosis: 'refused')), throwsA(anything));
        db.refuseUpdates = false;
        await r.patients.addRecord('p1', visitOn('r1', DateTime(2026, 3, 1), diagnosis: 'one'));
      });
      expect(db.rows['p1']!.history.map((v) => v.id).toSet(), {'r3', 'r1'});
      expect(r.patients.findById('p1').history.map((v) => v.id).toSet(), {'r3', 'r1'});
    });
  });

  // ------------------------------------------------------------------ repeat last
  group('F-RPT Repeat Last', () {
    testWidgets('F-RPT-01 copies the LATEST visit by date (not list position), as a Follow-up', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma', history: [
        visitOn('new', DateTime(2026, 3, 1), diagnosis: 'New dx', prescription: 'Cetirizine 10mg', bp: '118/76'),
        visitOn('old', DateTime(2026, 1, 1), diagnosis: 'Old dx', prescription: 'Old med'),
      ]);
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      await tapText(t, 'Repeat Last');
      final texts = t.widgetList<TextField>(find.byType(TextField)).map((f) => f.controller?.text ?? '').toList();
      expect(texts, contains('New dx'));
      expect(texts, contains('Cetirizine 10mg'));
      expect(texts, isNot(contains('Old dx')));
      await saveVisit(t);
      final h = db.rows['p1']!.history;
      expect(h, hasLength(3));
      final added = h.firstWhere((v) => v.id != 'new' && v.id != 'old');
      expect(added.visitType, 'Follow-up');
      expect(added.diagnosis, 'New dx');
    });

    testWidgets('F-RPT-02 Repeat Last with no earlier visit: no crash, nothing filled', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      if (find.text('Repeat Last').evaluate().isNotEmpty) await tapText(t, 'Repeat Last');
      expect(t.takeException(), isNull);
      final texts = t.widgetList<TextField>(find.byType(TextField)).map((f) => f.controller?.text ?? '');
      expect(texts.where((s) => s.isNotEmpty), isEmpty);
    });
  });

  // ------------------------------------------------------------------ medicines
  group('F-MED medicine suggestions', () {
    testWidgets('F-MED-01 a saved medicine is suggested on the next visit and after restart', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      var r = await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      await type(t, 'Diagnosis', 'Bronchitis');
      await type(t, 'Type medicine name...', 'Azithromycin 500mg');
      await saveVisit(t);
      expect(r.medicines.frequentMedicines, contains('Azithromycin 500mg'));
      r = await restart(t, r, support);
      expect(r.medicines.frequentMedicines, contains('Azithromycin 500mg'), reason: 'loaded at startup');
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      await t.ensureVisible(field('Type medicine name...'));
      await settle(t);
      await t.tap(field('Type medicine name...'));
      await settle(t);
      await type(t, 'Type medicine name...', 'azi');
      await settle(t);
      expect(find.widgetWithText(ListTile, 'Azithromycin 500mg'), findsOneWidget);
      await t.tap(find.widgetWithText(ListTile, 'Azithromycin 500mg'));
      await settle(t);
      expect(t.widget<TextField>(field('Type medicine name...')).controller!.text, 'Azithromycin 500mg');
    });

    testWidgets('F-MED-02 every prescription line is learned, not only the first', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      final r = await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      await type(t, 'Diagnosis', 'Bronchitis');
      await type(t, 'Type medicine name...', 'Azithromycin 500mg\nParacetamol 650mg');
      await saveVisit(t);
      expect(r.medicines.frequentMedicines, containsAll(['Azithromycin 500mg', 'Paracetamol 650mg']));
    });

    testWidgets('F-MED-03 a dosage chip is not learned as part of the medicine name', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      final r = await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      await type(t, 'Diagnosis', 'Bronchitis');
      await type(t, 'Type medicine name...', 'Azithromycin 500mg');
      final chip = r.medicines.dosageTemplates.first;
      await tapText(t, chip);
      final rx = t.widget<TextField>(field('Type medicine name...')).controller!.text;
      expect(rx, startsWith('Azithromycin 500mg'));
      await saveVisit(t);
      expect(r.medicines.frequentMedicines, contains('Azithromycin 500mg'));
      expect(r.medicines.frequentMedicines.where((m) => m.contains(chip)), isEmpty,
          reason: 'learned "${r.medicines.frequentMedicines}"');
    });

    testWidgets('F-MED-04 a dosage chip on an empty prescription does not start with " - "', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      final r = await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      await tapText(t, r.medicines.dosageTemplates.first);
      final rx = t.widget<TextField>(field('Type medicine name...')).controller!.text;
      expect(rx.startsWith(' - '), isFalse, reason: 'got "$rx"');
    });

    testWidgets('F-MED-05 a refused visit save does not learn its medicine', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      final r = await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      db.refuseUpdates = true;
      await type(t, 'Diagnosis', 'Bronchitis');
      await type(t, 'Type medicine name...', 'Refusedmycin 1mg');
      await saveVisit(t);
      expect(r.medicines.frequentMedicines, isNot(contains('Refusedmycin 1mg')));
    });
  });

  // ------------------------------------------------------------------ search
  group('F-SRCH search', () {
    QaDb family() {
      final db = QaDb();
      seedPatient(db, 'a', 'Asha Verma', phone: '+919876543210', history: [visitOn('v1', DateTime(2026, 3, 1))]);
      seedPatient(db, 'b', 'Rohan Verma', phone: '+919876543210', relation: 'Son', history: [visitOn('v2', DateTime(2026, 3, 2))]);
      seedPatient(db, 'c', 'Kiran Rao', phone: '+919811111111', history: [visitOn('v3', DateTime(2026, 3, 3), diagnosis: 'Asthma')]);
      return db;
    }

    testWidgets('F-SRCH-01 by name (any case) and by phone digits', (t) async {
      await boot(t, db: family(), support: support);
      await type(t, 'Search patients...', 'ASHA');
      await settle(t);
      expect(find.text('Asha Verma'), findsOneWidget);
      expect(find.text('Kiran Rao'), findsNothing);
      await type(t, 'Search patients...', '98111');
      await settle(t);
      expect(find.text('Kiran Rao'), findsOneWidget);
      expect(find.text('Asha Verma'), findsNothing);
      await type(t, 'Search patients...', '');
      await settle(t);
      expect(find.text('Asha Verma'), findsOneWidget);
      expect(find.text('Kiran Rao'), findsOneWidget);
    });

    testWidgets('F-SRCH-02 a phone typed with a space or +91 still matches', (t) async {
      await boot(t, db: family(), support: support);
      await type(t, 'Search patients...', '98111 11111');
      await settle(t);
      expect(find.text('Kiran Rao'), findsOneWidget, reason: '"98111 11111"');
      await type(t, 'Search patients...', '+91 9811111111');
      await settle(t);
      expect(find.text('Kiran Rao'), findsOneWidget, reason: '"+91 9811111111"');
    });

    testWidgets('F-SRCH-03 an active search does not change Insights totals', (t) async {
      await boot(t, db: family(), support: support);
      await type(t, 'Search patients...', 'kiran');
      await settle(t);
      await openDrawerItem(t, 'Clinical Insights');
      final total = find.ancestor(of: find.text('Total Patients'), matching: find.byType(Column)).first;
      final shown = t.widgetList<Text>(find.descendant(of: total, matching: find.byType(Text))).map((w) => w.data).toList();
      expect(find.descendant(of: total, matching: find.text('3')), findsOneWidget,
          reason: 'shown: $shown. Insights must count all 3 patients, not the 1 search hit');
    });

    testWidgets('F-SRCH-04c (control) without a search, Family Network lists the relative', (t) async {
      await boot(t, db: family(), support: support);
      await openPatient(t, 'Rohan Verma');
      expect(find.text('Family Network'), findsOneWidget);
      expect(find.text('Asha Verma'), findsOneWidget);
    });

    testWidgets('F-SRCH-04 an active search does not hide family members on the patient screen', (t) async {
      await boot(t, db: family(), support: support);
      await type(t, 'Search patients...', 'rohan');
      await settle(t);
      await openPatient(t, 'Rohan Verma');
      expect(find.text('Family Network'), findsOneWidget);
      expect(find.text('Asha Verma'), findsOneWidget, reason: 'Asha shares the phone number');
    });
  });

  // ------------------------------------------------------------------ insights
  group('F-INS insights', () {
    testWidgets('F-INS-01 totals and top diagnoses (case/space-insensitive grouping)', (t) async {
      final db = QaDb();
      seedPatient(db, 'a', 'Asha Verma', history: [
        visitOn('v1', DateTime(2026, 3, 1), diagnosis: 'Viral fever'),
        visitOn('v2', DateTime(2026, 3, 2), diagnosis: 'viral fever '),
      ]);
      seedPatient(db, 'b', 'Kiran Rao', phone: '+919811111111', history: [visitOn('v3', DateTime(2026, 3, 3), diagnosis: 'Asthma')]);
      await boot(t, db: db, support: support);
      await openDrawerItem(t, 'Clinical Insights');
      expect(find.text('Clinical Insights'), findsWidgets);
      expect(find.text('2'), findsWidgets); // Total Patients
      expect(find.text('3'), findsWidgets); // All-Time Visits
      expect(find.text('Viral fever'), findsOneWidget);
      expect(find.text('2 cases'), findsOneWidget);
      expect(find.text('Asthma'), findsOneWidget);
      expect(find.text('1 cases'), findsOneWidget);
    });

    testWidgets('F-INS-02 no visits: empty state, no crash', (t) async {
      final db = QaDb();
      seedPatient(db, 'a', 'Asha Verma');
      await boot(t, db: db, support: support);
      await openDrawerItem(t, 'Clinical Insights');
      expect(find.textContaining('No diagnosis data yet'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  // ------------------------------------------------------------------ profile
  group('F-PRO profile', () {
    testWidgets('F-PRO-01 first open is editable; save; reopens locked with the values after restart', (t) async {
      var r = await boot(t, support: support);
      await openDrawerItem(t, 'Professional Profile');
      expect(find.text(kDevModeBannerText), findsOneWidget, reason: 'banner on profile');
      await type(t, 'Full Name', 'Meera Rao');
      await type(t, 'Clinic / Hospital', 'QA Clinic');
      await type(t, 'Specialty', 'General Physician');
      final save = find.textContaining('Save');
      expect(save, findsWidgets);
      await t.ensureVisible(save.first);
      await t.tap(save.first);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      expect(find.text('Profile Locked & Saved'), findsOneWidget);
      expect(r.doctor.currentDoctor?.name, 'Meera Rao');
      r = await restart(t, r, support);
      expect(r.doctor.currentDoctor?.clinicName, 'QA Clinic', reason: 'profile loaded at startup');
      await openDrawerItem(t, 'Professional Profile');
      expect(find.text('Meera Rao'), findsWidgets);
      expect(find.textContaining('Save'), findsNothing, reason: 'existing profile opens locked');
      expect(hits, isEmpty, reason: '$hits');
    });

    testWidgets('F-PRO-02 a failed profile save says so and keeps the form', (t) async {
      final db = QaDb()..failPutSetting = true;
      await boot(t, db: db, support: support);
      await openDrawerItem(t, 'Professional Profile');
      await type(t, 'Full Name', 'Meera Rao');
      await type(t, 'Clinic / Hospital', 'QA Clinic');
      final save = find.textContaining('Save');
      await t.ensureVisible(save.first);
      await t.tap(save.first);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      expect(find.text('Could not save profile'), findsOneWidget);
      expect(find.text('Profile Locked & Saved'), findsNothing);
    });
  });
}
