// Clinical Insights: visit distribution charts from local data only.
// No Firebase app, no FirebaseAuth.
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/insights_screen.dart';
import 'package:docease/utils/insights_stats.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

final now = DateTime(2026, 10, 23);


LocalPatientProvider practice() => LocalPatientProvider([
      patientWith(id: 'p1', name: 'Asha', [
        visit('a1', DateTime(2026, 10, 20), type: 'Follow-up'),
        visit('a2', DateTime(2026, 9, 2), type: 'Initial Visit'),
        visit('a3', DateTime(2025, 12, 1), type: 'Routine'), // outside 6 months
      ]),
      patientWith(id: 'p2', name: 'Ravi', [
        visit('b1', DateTime(2026, 10, 1), type: 'Routine'),
        visit('b2', DateTime(2026, 7, 31, 23, 30), type: 'Follow-up'),
        visit('b3', DateTime(2026, 5, 1), type: 'Telehealth'), // May is the first month in the window
      ]),
    ]);

Future<void> pumpView(WidgetTester t, LocalPatientProvider pp) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: InsightsView(patients: pp.allPatients, now: now))));
  await t.pumpAndSettle();
}

void main() {
  group('visitsPerMonth', () {
    test('six calendar months ending this month, empty months as 0', () {
      final m = visitsPerMonth(practice().allPatients, now);
      expect(m.map((e) => e.month), [for (var i = 5; i <= 10; i++) DateTime(2026, i)]);
      expect(m.map((e) => e.count), [1, 0, 1, 0, 1, 2]);
    });

    test('crosses the year boundary', () {
      final m = visitsPerMonth(practice().allPatients, DateTime(2026, 2, 10));
      expect(m.first.month, DateTime(2025, 9));
      expect(m.map((e) => e.count), [0, 0, 0, 1, 0, 0]);
    });
  });

  test('visitTypeBreakdown: form types in form order, then others', () {
    expect(visitTypeBreakdown(practice().allPatients), [
      (type: 'Initial Visit', count: 1),
      (type: 'Follow-up', count: 2),
      (type: 'Routine', count: 2),
      (type: 'Telehealth', count: 1),
    ]);
  });

  testWidgets('visits per month bar chart replaces the placeholder', (t) async {
    await pumpView(t, practice());
    expect(find.text('Visual Trends System Active'), findsNothing);
    final monthly = find.byKey(const ValueKey('insights-monthly'));
    expect(find.descendant(of: monthly, matching: find.text('Last 6 months · 5 visits')), findsOneWidget);
    final bars = t.widget<BarChart>(find.descendant(of: monthly, matching: find.byType(BarChart))).data.barGroups;
    expect(bars.map((g) => g.barRods.single.toY), [1, 0, 1, 0, 1, 2]);
    expect(find.descendant(of: monthly, matching: find.text('May')), findsOneWidget);
    expect(find.descendant(of: monthly, matching: find.text('Oct')), findsOneWidget);
  });

  testWidgets('visit types donut with counts and percentages', (t) async {
    await pumpView(t, practice());
    final types = find.byKey(const ValueKey('insights-types'));
    expect(find.descendant(of: types, matching: find.text('All 6 visits on this phone')), findsOneWidget);
    final sections = t.widget<PieChart>(find.descendant(of: types, matching: find.byType(PieChart))).data.sections;
    expect(sections.map((s) => s.value), [1, 2, 2, 1]);
    expect(find.descendant(of: types, matching: find.text('2 · 33%')), findsNWidgets(2));
    expect(find.descendant(of: types, matching: find.text('Telehealth')), findsOneWidget);
  });

  testWidgets('no visits at all: one empty state, no charts', (t) async {
    await pumpView(t, LocalPatientProvider([patientWith([])]));
    expect(find.text('No visits yet. Charts appear here once clinical notes are added.'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(PieChart), findsNothing);
  });

  testWidgets('only old visits: the month chart says so, types still shown', (t) async {
    await pumpView(t, LocalPatientProvider([
      patientWith([visit('x', DateTime(2025, 1, 1))]),
    ]));
    expect(find.text('No visits in the last 6 months.'), findsOneWidget);
    expect(find.byType(BarChart), findsNothing);
    expect(find.byType(PieChart), findsOneWidget);
  });

  testWidgets('charts describe themselves for screen readers', (t) async {
    final h = t.ensureSemantics();
    await pumpView(t, practice());
    expect(find.bySemanticsLabel('Visits per month: May 1, Jun 0, Jul 1, Aug 0, Sep 1, Oct 2'), findsOneWidget);
    expect(find.bySemanticsLabel('Visit types: Initial Visit 1 (17%), Follow-up 2 (33%), Routine 2 (33%), Telehealth 1 (17%)'), findsOneWidget);
    h.dispose();
  });

  testWidgets('the screen uses every patient, not the home search results', (t) async {
    final pp = practice()..searchQuery = 'asha';
    expect(pp.patients, hasLength(1));
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(ChangeNotifierProvider<PatientProvider>.value(value: pp, child: const MaterialApp(home: InsightsScreen())));
    await t.pumpAndSettle();
    expect(find.text('Total Patients'), findsOneWidget);
    final total = find.ancestor(of: find.text('Total Patients'), matching: find.byType(Column)).first;
    expect(find.descendant(of: total, matching: find.text('2')), findsOneWidget);
    expect(find.text('All 6 visits on this phone'), findsOneWidget);
  });
}
