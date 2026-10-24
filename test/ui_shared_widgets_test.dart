// Shared widgets, theme tokens and accessibility (UI map steps 2-3, items
// 14-16). The look is checked separately with before/after screenshots; these
// tests pin behaviour and screen-reader output.
// ignore_for_file: depend_on_referenced_packages (firebase_core_platform_interface test mocks, as in the other widget tests)
import 'dart:ui' show Tristate;

import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/doctor_profile_screen.dart';
import 'package:docease/screens/home_screen.dart';
import 'package:docease/screens/patient_detail_screen.dart';
import 'package:docease/theme/app_theme.dart';
import 'package:docease/widgets/app_text_field.dart';
import 'package:docease/widgets/field_label.dart';
import 'package:docease/widgets/primary_button.dart';
import 'package:docease/widgets/segmented_selector.dart';
import 'package:docease/widgets/stat_card.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final _now = DateTime.now();
final _visit = VisitRecord(id: 'v1', date: DateTime(_now.year, _now.month, _now.day, 9), visitType: 'Initial', symptoms: 'Fever', diagnosis: 'Viral fever', prescription: 'Paracetamol - 1-0-1', bp: '120/80', temp: '101');
final _ravi = Patient(id: 'p1', name: 'Ravi Kumar', age: '42', gender: 'Male', phone: '+919876543210', history: [_visit]);
final _asha = Patient(id: 'p2', name: 'Asha Kumar', age: '39', gender: 'Female', phone: '+919876543210', relation: 'Spouse', history: const []);
final _doc = Doctor(id: 'd1', title: 'MR', name: 'John', email: 'john@clinic.test', age: '45', mobileNumber: '+919812345678', specialty: 'General Medicine', clinicName: 'City Clinic', practiceMode: 'Solo Practice');

class _Patients extends PatientProvider {
  @override
  List<Patient> get patients => [_ravi, _asha];
  // #11 reads family members from allPatients (not on main yet), so supply it
  // too; without @override this compiles both before and after #11.
  // ignore: annotate_overrides
  List<Patient> get allPatients => [_ravi, _asha];
  @override
  bool get isSyncing => false;
  @override
  Future<void> fetchAndSetPatients() async {}
  @override
  Patient findById(String id) => [_ravi, _asha].firstWhere((p) => p.id == id);
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

Widget _host(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: _Patients()),
        ChangeNotifierProvider<DoctorProvider>.value(value: _Doctor()),
        ChangeNotifierProvider<MedicineProvider>.value(value: _Meds()),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: child),
    );

Future<void> _pumpScreen(WidgetTester t, Widget screen) async {
  t.view.physicalSize = const Size(1200, 2800);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  // The test font is wider than real fonts, so ignore overflow stripes.
  final prev = FlutterError.onError;
  FlutterError.onError = (d) {
    if (!d.exceptionAsString().contains('overflowed by')) prev?.call(d);
  };
  addTearDown(() => FlutterError.onError = prev);
  await t.pumpWidget(_host(screen));
  await t.pumpAndSettle();
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  group('AppTheme', () {
    test('light() is the ThemeData main.dart builds inline', () {
      // main.dart: ThemeData(useMaterial3: true, colorScheme:
      //   ColorScheme.fromSeed(seedColor: 0xFF6366F1, surface: 0xFFF8FAFC))
      final inline = ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1), surface: const Color(0xFFF8FAFC)));
      expect(AppTheme.light().colorScheme, inline.colorScheme);
      expect(AppTheme.light().useMaterial3, isTrue);
    });

    test('tokens are the literals the screens used', () {
      expect(AppColors.primary, const Color(0xFF6366F1));
      expect(AppColors.ink, const Color(0xFF1E293B));
      expect(AppColors.track, const Color(0xFFF1F5F9));
      expect(AppColors.label, const Color(0xFF475569));
      expect(AppColors.muted, const Color(0xFF64748B));
      expect(AppText.label, const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569)));
    });
  });

  group('SegmentedSelector', () {
    testWidgets('tap selects; options are exclusive buttons with selected state', (t) async {
      final handle = t.ensureSemantics();
      String? picked;
      await t.pumpWidget(_wrap(SegmentedSelector(options: const ['Male', 'Female', 'Other'], selected: 'Male', onSelected: (v) => picked = v)));
      await t.tap(find.text('Female'));
      expect(picked, 'Female');
      expect(t.getSemantics(find.text('Male')), matchesSemantics(label: 'Male', isButton: true, isSelected: true, hasSelectedState: true, isInMutuallyExclusiveGroup: true, hasEnabledState: true, isEnabled: true, hasTapAction: true, isFocusable: false));
      expect(t.getSemantics(find.text('Other')), matchesSemantics(label: 'Other', isButton: true, isSelected: false, hasSelectedState: true, isInMutuallyExclusiveGroup: true, hasEnabledState: true, isEnabled: true, hasTapAction: true));
      handle.dispose();
    });

    testWidgets('disabled: taps ignored and options read as disabled', (t) async {
      final handle = t.ensureSemantics();
      String? picked;
      await t.pumpWidget(_wrap(SegmentedSelector(options: const ['MR', 'MRS'], selected: 'MR', enabled: false, onSelected: (v) => picked = v)));
      await t.tap(find.text('MRS'), warnIfMissed: false);
      expect(picked, isNull);
      final flags = t.getSemantics(find.text('MRS')).getSemanticsData().flagsCollection;
      expect(flags.isEnabled, Tristate.isFalse);
      handle.dispose();
    });
  });

  group('form widgets', () {
    testWidgets('FieldLabel is a heading', (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_wrap(const FieldLabel('Patient Name')));
      expect(t.getSemantics(find.text('Patient Name')), matchesSemantics(label: 'Patient Name', isHeader: true));
      handle.dispose();
    });

    testWidgets('AppTextField: private turns off keyboard learning and suggestions', (t) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      await t.pumpWidget(_wrap(Column(children: [
        AppTextField(key: const Key('plain'), controller: c, hint: 'Clinic', icon: Icons.home),
        AppTextField(key: const Key('phi'), controller: c, hint: 'Symptoms', icon: Icons.notes, private: true),
      ])));
      TextField field(String k) => t.widget<TextField>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(TextField)));
      expect(field('plain').autocorrect, isTrue);
      expect(field('plain').enableSuggestions, isTrue);
      expect(field('plain').enableIMEPersonalizedLearning, isTrue);
      expect(field('phi').autocorrect, isFalse);
      expect(field('phi').enableSuggestions, isFalse);
      expect(field('phi').enableIMEPersonalizedLearning, isFalse);
      expect(field('phi').smartDashesType, SmartDashesType.disabled);
      expect(field('phi').smartQuotesType, SmartQuotesType.disabled);
    });

    testWidgets('PrimaryButton calls back', (t) async {
      var taps = 0;
      await t.pumpWidget(_wrap(PrimaryButton(label: 'Save', onPressed: () => taps++)));
      await t.tap(find.text('Save'));
      expect(taps, 1);
    });

    testWidgets('StatCard reads as one item: "label: value"', (t) async {
      final handle = t.ensureSemantics();
      await t.pumpWidget(_wrap(const StatCard(label: 'TODAY VISITS', value: '3', icon: Icons.history, color: Colors.green)));
      expect(find.bySemanticsLabel('TODAY VISITS: 3'), findsOneWidget);
      handle.dispose();
    });
  });

  group('screens', () {
    testWidgets('home: no unmatched Hero; Daily Pulse uses StatCard', (t) async {
      await _pumpScreen(t, const HomeScreen());
      // The detail screen has no Hero with the same tag, so this one never
      // animated and only risked duplicate-tag errors.
      // (The FAB keeps its own default Hero; only the patient-tagged ones go.)
      expect(find.byWidgetPredicate((w) => w is Hero && (w.tag == 'p1' || w.tag == 'p2')), findsNothing);
      expect(find.byType(StatCard), findsNWidgets(2));
    });

    testWidgets('profile: locked selector ignores taps; save uses PrimaryButton', (t) async {
      await _pumpScreen(t, const DoctorProfileScreen());
      expect(find.byType(SegmentedSelector), findsWidgets);
      final before = t.widget<SegmentedSelector>(find.byType(SegmentedSelector).first);
      expect(before.enabled, isFalse);
      await t.tap(find.byIcon(Icons.edit_note_rounded));
      await t.pumpAndSettle();
      expect(t.widget<SegmentedSelector>(find.byType(SegmentedSelector).first).enabled, isTrue);
      expect(find.widgetWithText(PrimaryButton, 'Save and Lock Profile'), findsOneWidget);
    });

    testWidgets('detail: icon buttons have tooltips; chip and visit card are buttons', (t) async {
      final handle = t.ensureSemantics();
      await _pumpScreen(t, const PatientDetailScreen(patientId: 'p1'));
      expect(find.byTooltip('Export PDF'), findsOneWidget);
      // The chip's and the visit card's text merge into a tappable button node.
      for (final label in ['Asha Kumar', 'Viral fever']) {
        final data = t.getSemantics(find.text(label)).getSemanticsData();
        expect(data.flagsCollection.isButton, isTrue, reason: label);
        expect(data.hasAction(SemanticsAction.tap), isTrue, reason: label);
      }
      await t.tap(find.text('Viral fever'));
      await t.pumpAndSettle();
      expect(find.byTooltip('Edit visit'), findsOneWidget);
      expect(find.byTooltip('Delete visit'), findsOneWidget);
      expect(find.byTooltip('Share visit'), findsOneWidget);
      handle.dispose();
    });
  });
}
