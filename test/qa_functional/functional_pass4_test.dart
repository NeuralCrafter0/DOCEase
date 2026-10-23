import 'package:docease/config/dev_mode.dart' show kDevMode;
// QA functional pass, batch 4: blood sugar + vitals charts (#11 feat/feature-gaps).
// Runs only on a merge that contains #11 (VitalsTrendsScreen, sugar field).
import 'dart:io';

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
    root = Directory.systemTemp.createTempSync('docease_fp4');
    support = Directory('${root.path}/support')..createSync();
    printer = FakePrinter()..install();
    share = FakeShare()..install();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> saveVisit(WidgetTester t) async {
    await tapText(t, 'Save Clinical Record');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await settle(t);
  }

  Future<String> pdfText(WidgetTester t) async {
    await tapIcon(t, Icons.picture_as_pdf_outlined);
    for (var i = 0; i < 40 && printer.lastPdf == null; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(printer.lastPdf, isNotNull);
    return (await t.runAsync(() async {
      final f = File('${root.path}/out.pdf')..writeAsBytesSync(printer.lastPdf!);
      return '${(await Process.run('pdftotext', ['-layout', f.path, '-'])).stdout}';
    }))!;
  }

  Future<void> openTrends(WidgetTester t) async {
    await t.tap(find.byTooltip('Vitals trends'));
    await settle(t);
  }

  /// Trend cards live in a lazy ListView: scroll until [f] is built.
  Future<void> reveal(WidgetTester t, Finder f) async {
    await t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).last, maxScrolls: 30);
    await settle(t, 5);
  }

  QaDb sugarOnly() {
    final db = QaDb();
    seedPatient(db, 'p1', 'Asha Verma', history: [
      visitOn('v1', DateTime(2026, 3, 1), diagnosis: 'Type 2 diabetes', sugar: '182'),
    ]);
    return db;
  }

  QaDb series() {
    final db = QaDb();
    seedPatient(db, 'p1', 'Asha Verma', history: [
      // newest first, like the app stores it
      visitOn('v3', DateTime(2026, 3, 1), diagnosis: 'Review', bp: '128/82', pulse: '76', sugar: '5.5 mmol/L'),
      visitOn('v2', DateTime(2026, 2, 1), diagnosis: 'Review', bp: '140/90', pulse: '88', sugar: '160'),
      visitOn('v1', DateTime(2026, 1, 1), diagnosis: 'Type 2 diabetes', bp: '150/95', pulse: 'abc', sugar: '210'),
    ]);
    return db;
  }

  group('F-SUG blood sugar', () {
    testWidgets('F-SUG-01 entered on the visit form, stored, shown on the timeline and sheet', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Add Clinical Note');
      expect(field('mg/dL'), findsOneWidget, reason: 'Blood Sugar input exists');
      await type(t, 'Diagnosis', 'Type 2 diabetes');
      await type(t, 'mg/dL', '182');
      await saveVisit(t);
      expect(db.rows['p1']!.history.single.sugar, '182');
      expect(find.textContaining('182'), findsWidgets, reason: 'timeline shows a sugar-only visit\'s vitals');
      await tapText(t, 'Type 2 diabetes');
      expect(find.textContaining('182'), findsWidgets, reason: 'visit sheet shows sugar');
    });

    testWidgets('F-SUG-02 edit keeps and changes sugar; Repeat Last copies it', (t) async {
      final db = sugarOnly();
      await boot(t, db: db, support: support);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Type 2 diabetes');
      await tapIconLast(t, Icons.edit_outlined);
      expect(t.widget<TextField>(field('mg/dL')).controller!.text, '182');
      await type(t, 'mg/dL', '150');
      await saveVisit(t);
      expect(db.rows['p1']!.history.single.sugar, '150');
      await tapText(t, 'Add Clinical Note');
      await tapText(t, 'Repeat Last');
      expect(t.widget<TextField>(field('mg/dL')).controller!.text, '150');
    });

    testWidgets('F-SUG-03 the PDF report includes blood sugar', (t) async {
      await boot(t, db: sugarOnly(), support: support);
      await tapText(t, 'Asha Verma');
      final text = await pdfText(t);
      expect(text, contains('Type 2 diabetes'));
      expect(text, contains('182'), reason: 'sugar recorded but missing from the PDF');
    });

    testWidgets('F-SUG-04 sharing Vitals includes blood sugar', (t) async {
      await boot(t, db: sugarOnly(), support: support);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Type 2 diabetes');
      await tapIconLast(t, Icons.share_outlined);
      await tapText(t, 'Vitals');
      await tapText(t, 'Share');
      expect(share.calls, hasLength(1));
      expect(share.lastText, contains('182'), reason: 'shared: ${share.lastText}');
    });
  });

  group('F-CHART vitals trends', () {
    testWidgets('F-CHART-01 trends: BP, pulse and sugar cards, oldest-to-newest, latest values', (t) async {
      await boot(t, db: series(), support: support);
      await tapText(t, 'Asha Verma');
      await openTrends(t);
      expect(find.text('Asha Verma · Vitals'), findsOneWidget);
      expect(find.byKey(const ValueKey('trend-bp')), findsOneWidget);
      expect(find.text('128/82 mmHg'), findsOneWidget, reason: 'latest BP is the newest visit');
      expect(find.text('3 readings · range 128–150 mmHg'), findsOneWidget);
      await reveal(t, find.byKey(const ValueKey('trend-pulse')));
      await reveal(t, find.byKey(const ValueKey('trend-sugar')));
      expect(find.byKey(const ValueKey('trend-temp')), findsNothing, reason: 'no temp recorded');
      expect(t.takeException(), isNull);
    });

    testWidgets('F-CHART-02 mmol/L is converted; unreadable entries are counted, not charted', (t) async {
      await boot(t, db: series(), support: support);
      await tapText(t, 'Asha Verma');
      await openTrends(t);
      final sugar = find.byKey(const ValueKey('trend-sugar'));
      await reveal(t, sugar);
      expect(find.descendant(of: sugar, matching: find.text('99 mg/dL')), findsOneWidget,
          reason: '5.5 mmol/L = 99 mg/dL');
      final pulse = find.byKey(const ValueKey('trend-pulse'));
      await t.scrollUntilVisible(pulse, -200, scrollable: find.byType(Scrollable).last, maxScrolls: 30);
      await settle(t, 5);
      expect(find.descendant(of: pulse, matching: find.textContaining("couldn't be read")), findsOneWidget);
      expect(find.descendant(of: pulse, matching: find.textContaining('2 readings')), findsOneWidget);
    });

    testWidgets('F-CHART-03 one reading and no readings', (t) async {
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma', history: [visitOn('v1', DateTime(2026, 3, 1), pulse: '80')]);
      seedPatient(db, 'p2', 'Kiran Rao', phone: '+919811111111', history: [visitOn('v2', DateTime(2026, 3, 1))]);
      await boot(t, db: db, support: support);
      await tapText(t, 'Asha Verma');
      await openTrends(t);
      expect(find.text('1 reading. Add another visit to see a trend.'), findsOneWidget);
      await t.pageBack();
      await settle(t);
      await t.pageBack();
      await settle(t);
      await tapText(t, 'Kiran Rao');
      await openTrends(t);
      expect(find.textContaining('No vitals recorded yet'), findsOneWidget);
    });

    testWidgets('F-CHART-04 a new visit appears on the open trends after saving', (t) async {
      final db = series();
      await boot(t, db: db, support: support);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Add Clinical Note');
      await type(t, 'Diagnosis', 'Review');
      await type(t, '120/80', '118/76');
      await saveVisit(t);
      await openTrends(t);
      expect(find.text('118/76 mmHg'), findsOneWidget);
      expect(find.textContaining('4 readings'), findsWidgets);
    });

    testWidgets('F-CHART-05 Insights charts render with data; totals ignore the home search', (t) async {
      await boot(t, db: series(), support: support);
      await type(t, 'Search patients...', 'zzz');
      await settle(t);
      await t.tap(find.byTooltip('Open navigation menu'));
      await settle(t);
      await tapText(t, 'Clinical Insights');
      expect(find.text('Visual Trends System Active'), findsNothing, reason: 'placeholder replaced by charts');
      final total = find.ancestor(of: find.text('Total Patients'), matching: find.byType(Column)).first;
      expect(find.descendant(of: total, matching: find.text('1')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });
}
