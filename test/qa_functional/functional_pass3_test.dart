// QA functional pass, batch 3 (local only, not committed).
import 'dart:io';
import 'dart:typed_data';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/doctor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() => group('[needs --dart-define=DOCEASE_DEV_MODE=true]', _main, skip: !kDevMode);

void _main() {
  late Directory root;
  late Directory support;
  late FakePrinter printer;
  late FakeShare share;

  setUpAll(loadRealFonts);
  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_fp3');
    support = Directory('${root.path}/support')..createSync();
    printer = FakePrinter()..install();
    share = FakeShare()..install();
  });
  tearDown(() {
    restoreLogs();
    root.deleteSync(recursive: true);
  });

  Doctor doc() => Doctor(
      id: 'local', title: 'Dr.', name: 'Meera Rao', email: 'meera@example.com', age: '45',
      mobileNumber: '9800000000', specialty: 'General Physician', clinicName: 'QA Clinic',
      practiceMode: 'Clinic');

  Future<String> pdfText(WidgetTester t, Uint8List bytes) async {
    return (await t.runAsync(() async {
      final f = File('${root.path}/out.pdf')..writeAsBytesSync(bytes);
      final r = await Process.run('pdftotext', ['-layout', f.path, '-']);
      return '${r.stdout}';
    }))!;
  }

  Future<void> exportPdf(WidgetTester t) async {
    await tapIcon(t, Icons.picture_as_pdf_outlined);
    for (var i = 0; i < 40 && printer.lastPdf == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(milliseconds: 50));
    }
    await settle(t, 10);
  }

  QaDb seeded({String name = 'Asha Verma'}) {
    final db = QaDb();
    seedPatient(db, 'a1b2c3d4-e5f6-7890-abcd-ef0123456789', name, history: [
      visitOn('v1', DateTime(2026, 3, 1), diagnosis: 'Acute bronchitis', prescription: 'Azithromycin 500mg',
          bp: '130/85', temp: '99.1', pulse: '88', weight: '62'),
      visitOn('v2', DateTime(2026, 2, 1), diagnosis: 'Migraine', prescription: 'Naproxen 250mg'),
    ]);
    return db;
  }

  // ------------------------------------------------------------------ PDF
  group('F-PDF export', () {
    testWidgets('F-PDF-01 report: neutral filename, letterhead, patient and both visits', (t) async {
      final db = seeded();
      final r = await boot(t, db: db, support: support);
      await t.runAsync(() => r.doctor.saveDoctorProfile(doc()));
      await settle(t, 5);
      await tapText(t, 'Asha Verma');
      await exportPdf(t);
      expect(printer.calls, hasLength(1));
      final name = '${printer.calls.single['name']}';
      // dev mode (#13 8429324): TEST_DATA_ prefix on the neutral #7 name
      expect(name, matches(RegExp(r'^TEST_DATA_report_a1b2c3d4_\d{8}\.pdf$')));
      expect(name.toLowerCase(), isNot(contains('asha')));
      expect(printer.lastPdf, isNotNull, reason: 'PDF bytes were produced');
      final text = await pdfText(t, printer.lastPdf!);
      for (final s in ['QA Clinic', 'Meera Rao', 'Asha Verma', 'Acute bronchitis', 'Azithromycin 500mg', 'Migraine', '130/85']) {
        expect(text, contains(s), reason: 'PDF text is missing "$s"');
      }
      expect(hits, isEmpty, reason: '$hits');
    });

    testWidgets('F-PDF-02 a Hindi patient name is printed (not dropped)', (t) async {
      final db = seeded(name: 'राम शर्मा');
      await boot(t, db: db, support: support);
      await tapText(t, 'राम शर्मा');
      await exportPdf(t);
      expect(printer.lastPdf, isNotNull, reason: 'export must not fail on a non-Latin name');
      final text = await pdfText(t, printer.lastPdf!);
      expect(text, contains('राम'), reason: 'PDF text: ${text.substring(0, text.length.clamp(0, 300))}');
    });

    testWidgets('F-PDF-03 a patient with no visits and no doctor profile still exports', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Kiran Rao');
      await boot(t, db: db, support: support);
      await tapText(t, 'Kiran Rao');
      await exportPdf(t);
      expect(printer.lastPdf, isNotNull);
      expect(await pdfText(t, printer.lastPdf!), contains('Kiran Rao'));
    });

    testWidgets('F-PDF-04 (L3) a dev-mode PDF is marked as test data', (t) async {
      final db = seeded();
      await boot(t, db: db, support: support);
      await tapText(t, 'Asha Verma');
      await exportPdf(t);
      final text = await pdfText(t, printer.lastPdf!);
      final marks = RegExp('TEST DATA - NOT A MEDICAL RECORD').allMatches(text).length;
      final pages = '\f'.allMatches(text).length;
      expect(marks, greaterThanOrEqualTo(2 * pages), reason: 'marker top and bottom of every page ($pages pages, $marks marks)');
    });
  });

  // ------------------------------------------------------------------ share
  group('F-SHR share', () {
    Future<void> openShare(WidgetTester t) async {
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Acute bronchitis');
      await tapIconLast(t, Icons.share_outlined);
      expect(find.text('Share outside DOCEase?'), findsOneWidget);
    }

    testWidgets('F-SHR-01 confirm step: Cancel shares nothing', (t) async {
      await boot(t, db: seeded(), support: support);
      await openShare(t);
      await tapText(t, 'Cancel');
      expect(share.calls, isEmpty);
    });

    testWidgets('F-SHR-02 unticked patient name is left out; diagnosis and Rx are in', (t) async {
      final r = await boot(t, db: seeded(), support: support);
      await t.runAsync(() => r.doctor.saveDoctorProfile(doc()));
      await openShare(t);
      // #7 eccedde: every field starts unticked; tick only diagnosis + Rx.
      await tapText(t, 'Diagnosis');
      await tapText(t, 'Prescription');
      await tapText(t, 'Share');
      expect(share.calls, hasLength(1));
      final s = share.lastText;
      expect(s, isNot(contains('Asha')));
      expect(s, contains('Acute bronchitis'));
      expect(s, contains('Azithromycin 500mg'));
      expect(hits, isEmpty, reason: '$hits');
    });

    testWidgets('F-SHR-05 nothing is pre-ticked and Share stays disabled until a field is ticked', (t) async {
      await boot(t, db: seeded(), support: support);
      await openShare(t);
      final boxes = t.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(boxes, hasLength(4));
      expect(boxes.where((b) => b.value == true), isEmpty);
      final btn = find.ancestor(of: find.text('Share'), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
      expect(t.widget<ButtonStyleButton>(btn.first).onPressed, isNull);
      await t.tap(find.text('Share'));
      await settle(t);
      expect(share.calls, isEmpty);
    });

    testWidgets('F-SHR-03 shared vitals include pulse and weight that were recorded', (t) async {
      await boot(t, db: seeded(), support: support);
      await openShare(t);
      await tapText(t, 'Vitals');
      await tapText(t, 'Share');
      final s = share.lastText;
      expect(s, contains('130/85'));
      expect(s, contains('88'), reason: 'pulse recorded but not shared: $s');
      expect(s, contains('62'), reason: 'weight recorded but not shared: $s');
    });

    testWidgets('F-SHR-04 (L3) a dev-mode share is marked as test data', (t) async {
      await boot(t, db: seeded(), support: support);
      await openShare(t);
      await tapText(t, 'Diagnosis');
      await tapText(t, 'Share');
      expect(share.lastText.toUpperCase(), anyOf(contains('TEST DATA'), contains('DEV')), reason: share.lastText);
    });
  });

  // ------------------------------------------------------------------ privacy
  group('F-PRIV clinical keyboard flags', () {
    void expectPrivate(WidgetTester t, String screen) {
      final bad = <String>[];
      for (final f in t.widgetList<TextField>(find.byType(TextField))) {
        final label = f.decoration?.hintText ?? f.decoration?.labelText ?? '?';
        if (f.enableSuggestions || (f.autocorrect ?? !f.obscureText) || f.enableIMEPersonalizedLearning) {
          bad.add('$label(sugg=${f.enableSuggestions},autocorrect=${f.autocorrect},ime=${f.enableIMEPersonalizedLearning})');
        }
      }
      expect(bad, isEmpty, reason: '$screen fields: $bad');
    }

    testWidgets('F-PRIV-01 visit form: suggestions, autocorrect and IME learning are off on every field', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Add Clinical Note');
      expectPrivate(t, 'visit form');
    });

    testWidgets('F-PRIV-02 patient form: same flags off', (t) async {
      await boot(t, support: support);
      await tapText(t, 'Register Patient');
      expectPrivate(t, 'patient form');
    });

    testWidgets('F-PRIV-03 home search box: same flags off', (t) async {
      await boot(t, support: support);
      expectPrivate(t, 'home');
    });
  });

  // ------------------------------------------------------------------ logs
  group('F-LOG logs', () {
    testWidgets('F-LOG-01 full journey: no patient name, phone or clinical text in logs', (t) async {
      captureLogs();
      final db = QaDb();
      final r = await boot(t, db: db, support: support);
      await tapText(t, 'Register Patient');
      await type(t, 'Enter patient name', 'Zelda Quixote');
      await type(t, 'Years', '33');
      await t.enterText(find.byWidgetPredicate((w) => w is TextField && w.keyboardType == TextInputType.phone).first, '9123456789');
      await tapText(t, 'Register Profile');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      await tapText(t, 'Zelda Quixote');
      await tapText(t, 'Add Clinical Note');
      await type(t, 'Diagnosis', 'Xerophthalmia');
      await type(t, 'Type medicine name...', 'Retinolzine 9mg');
      await tapText(t, 'Save Clinical Record');
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await settle(t);
      await exportPdf(t);
      // a refused save too (error paths log)
      db.refuseUpdates = true;
      await t.runAsync(() => r.patients.addRecord(db.rows.keys.single, visitOn('x', DateTime(2026, 1, 1), diagnosis: 'Xerophthalmia')).catchError((_) {}));
      restoreLogs();
      final leaks = logLines.where((l) => RegExp('Zelda|Quixote|9123456789|Xerophthalmia|Retinolzine').hasMatch(l)).toList();
      expect(leaks, isEmpty, reason: 'leaked: $leaks');
      // ignore: avoid_print
      print('F-LOG-01 captured ${logLines.length} log lines: $logLines');
    });
  });

  // ------------------------------------------------------------------ dev chrome
  group('F-DEV chrome', () {
    testWidgets('F-DEV-02 banner on detail, insights and profile; no Sign Out; no cloud touched', (t) async {
      await boot(t, db: seeded(), support: support);
      await tapText(t, 'Asha Verma');
      expect(find.text(kDevModeBannerText), findsOneWidget);
      await t.pageBack();
      await settle(t);
      await t.tap(find.byTooltip('Open navigation menu'));
      await settle(t);
      expect(find.text('Sign Out'), findsNothing);
      await tapText(t, 'Clinical Insights');
      expect(find.text(kDevModeBannerText), findsOneWidget);
      expect(hits, isEmpty, reason: '$hits');
    });
  });

  // ------------------------------------------------------------------ layout
  group('F-UI layout (real Roboto)', () {
    for (final (label, size, scale) in [
      ('small phone 320x568', const Size(320, 568), 1.0),
      ('360x780 at text scale 1.3', const Size(360, 780), 1.3),
    ]) {
      testWidgets('F-UI-01 no overflow on $label: home, detail, visit form, profile', (t) async {
        phoneSize = size;
        addTearDown(() => phoneSize = const Size(360, 780));
        t.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        final r = await boot(t, db: seeded(), support: support);
        await t.runAsync(() => r.doctor.saveDoctorProfile(doc()));
        await settle(t, 5);
        await tapText(t, 'Asha Verma');
        await tapText(t, 'Acute bronchitis');
        await t.tapAt(const Offset(5, 5)); // close the sheet
        await settle(t);
        await tapText(t, 'Add Clinical Note');
        await t.pageBack();
        await settle(t);
        await t.pageBack();
        await settle(t);
        await t.tap(find.byTooltip('Open navigation menu'));
        await settle(t);
        await tapText(t, 'Professional Profile');
      });
    }
  });
}
