// Vitals Trends: per-patient fl_chart line charts from local visits only.
// No Firebase app, no FirebaseAuth.
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/screens/vitals_trends_screen.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

Future<void> pump(WidgetTester t, Widget child, {LocalPatientProvider? pp}) async {
  t.view.physicalSize = const Size(1080, 4000);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: pp ?? LocalPatientProvider([])),
      ChangeNotifierProvider<MedicineProvider>.value(value: LocalMedicineProvider()),
      ChangeNotifierProvider<DoctorProvider>.value(value: LocalDoctorProvider()),
    ],
    child: MaterialApp(home: child),
  ));
  await t.pumpAndSettle();
}

Finder card(String kind) => find.byKey(ValueKey('trend-$kind'));
LineChart chartIn(WidgetTester t, String kind) => t.widget<LineChart>(find.descendant(of: card(kind), matching: find.byType(LineChart)));

Patient diabetic() => patientWith([
      // newest first, as the provider stores them
      visit('r3', DateTime(2026, 3, 1), bp: '125/82', sugar: '150'),
      visit('r1', DateTime(2026, 1, 1), bp: '140/90', sugar: '210'),
      visit('r2', DateTime(2026, 2, 1), bp: '132/86', sugar: '180 mg/dL'),
    ]);

void main() {
  testWidgets('one card per recorded vital, nothing for vitals never taken', (t) async {
    await pump(t, Scaffold(body: VitalsTrendsView(patient: diabetic())));
    expect(card('bp'), findsOneWidget);
    expect(card('sugar'), findsOneWidget);
    expect(card('pulse'), findsNothing);
    expect(card('temp'), findsNothing);
    expect(card('weight'), findsNothing);
    expect(find.byType(LineChart), findsNWidgets(2));
  });

  testWidgets('sugar chart plots readings in date order with latest, change and range', (t) async {
    await pump(t, Scaffold(body: VitalsTrendsView(patient: diabetic())));
    final spots = chartIn(t, 'sugar').data.lineBarsData.single.spots;
    expect(spots.map((s) => s.y), [210, 180, 150]);
    expect(spots.map((s) => s.x).toList(), orderedEquals([...spots.map((s) => s.x)]..sort()));
    expect(spots.first.x, 0);
    expect(spots.last.x, DateTime(2026, 3, 1).difference(DateTime(2026, 1, 1)).inMinutes / (60 * 24));

    final sugar = find.descendant(of: card('sugar'), matching: find.byType(Text));
    String texts() => t.widgetList<Text>(sugar).map((w) => w.data).join(' | ');
    expect(texts(), contains('150 mg/dL'));
    expect(texts(), contains('−30 since last visit'));
    expect(texts(), contains('3 readings · range 150–210 mg/dL'));
    expect(texts(), contains('Shaded: typical adult range 70–140 mg/dL.'));
    expect(chartIn(t, 'sugar').data.rangeAnnotations.horizontalRangeAnnotations.single.y1, 70);
  });

  testWidgets('BP draws systolic and diastolic with 120/80 guides', (t) async {
    await pump(t, Scaffold(body: VitalsTrendsView(patient: diabetic())));
    final data = chartIn(t, 'bp').data;
    expect(data.lineBarsData, hasLength(2));
    expect(data.lineBarsData[0].spots.map((s) => s.y), [140, 132, 125]);
    expect(data.lineBarsData[1].spots.map((s) => s.y), [90, 86, 82]);
    expect(data.extraLinesData.horizontalLines.map((l) => l.y), [120, 80]);
    expect(find.descendant(of: card('bp'), matching: find.text('125/82 mmHg')), findsOneWidget);
    expect(find.descendant(of: card('bp'), matching: find.text('−7 systolic since last visit')), findsOneWidget);
  });

  testWidgets('one reading says a trend needs another visit', (t) async {
    await pump(t, Scaffold(body: VitalsTrendsView(patient: patientWith([visit('r', DateTime(2026, 1, 1), weight: '72 kg')]))));
    expect(find.text('1 reading. Add another visit to see a trend.'), findsOneWidget);
    expect(find.textContaining('since last visit'), findsNothing);
  });

  testWidgets('unreadable entries are reported, not silently dropped', (t) async {
    await pump(
        t,
        Scaffold(
            body: VitalsTrendsView(
                patient: patientWith([
          visit('a', DateTime(2026, 1, 2), temp: 'afebrile'),
          visit('b', DateTime(2026, 1, 1), temp: '37.5 C'),
        ]))));
    expect(find.text("1 entry couldn't be read as a number and isn't charted."), findsOneWidget);
    expect(chartIn(t, 'temp').data.lineBarsData.single.spots.single.y, closeTo(99.5, 1e-9));
  });

  testWidgets('a patient with no vitals gets a clear empty state', (t) async {
    await pump(t, Scaffold(body: VitalsTrendsView(patient: patientWith([visit('a', DateTime(2026, 1, 1))]))));
    expect(find.textContaining('No vitals recorded yet.'), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('the chart describes itself for screen readers', (t) async {
    final handle = t.ensureSemantics();
    await pump(t, Scaffold(body: VitalsTrendsView(patient: diabetic())));
    expect(find.bySemanticsLabel('Blood Sugar trend, 3 readings, latest 150 mg/dL on 01 Mar 2026'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('opens from the patient detail app bar and updates when a visit is added', (t) async {
    final pp = LocalPatientProvider([diabetic()]);
    await pump(t, const PatientDetailScreen(patientId: 'p1'), pp: pp);
    await t.tap(find.byTooltip('Vitals trends'));
    await t.pumpAndSettle();
    expect(find.byType(VitalsTrendsScreen), findsOneWidget);
    expect(find.text('Asha · Vitals'), findsOneWidget);
    expect(card('pulse'), findsNothing);

    await pp.addRecord('p1', visit('r4', DateTime(2026, 4, 1), sugar: '130', pulse: '76'));
    await t.pumpAndSettle();
    expect(card('pulse'), findsOneWidget);
    expect(chartIn(t, 'sugar').data.lineBarsData.single.spots.map((s) => s.y), [210, 180, 150, 130]);
  });

  testWidgets('a home-screen search does not hide the patient', (t) async {
    final pp = LocalPatientProvider([diabetic()])..searchQuery = 'somebody else';
    expect(pp.patients, isEmpty);
    await pump(t, const VitalsTrendsScreen(patientId: 'p1'), pp: pp);
    expect(find.text('Asha · Vitals'), findsOneWidget);
    expect(card('sugar'), findsOneWidget);
  });

  testWidgets('a patient that is gone shows a message instead of crashing', (t) async {
    await pump(t, const VitalsTrendsScreen(patientId: 'missing'), pp: LocalPatientProvider([diabetic()]));
    expect(find.text('This patient is no longer on this phone.'), findsOneWidget);
  });
}
