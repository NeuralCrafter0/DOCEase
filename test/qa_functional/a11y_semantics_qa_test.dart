// QA: #17 (screen-reader labels, tooltips, button semantics) and #19
// (contrast) on the main screens, with the real app, real Roboto and the
// dev-mode harness. Two parts:
//   A11Y-0x  #17's specific claims (fail on the base branch, pass with #17);
//   A11Y-G   Flutter's built-in guidelines per screen. Each violation list is
//            printed as "A11Y-G <screen> <guideline> n=<count> ..." so the
//            base (qa-merged10) and qa-polish runs can be diffed. The test
//            only fails if QA_A11Y_BASELINE (a file of base lines) shows a NEW
//            violation, so it is a no-regression check, not a full audit.
// ignore_for_file: deprecated_member_use
import 'dart:io';
import 'dart:ui' show SemanticsFlag;

import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/doctor.dart';
import 'package:docease/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const bool _ff = bool.fromEnvironment('QA_FAILING_FIRST');

double _ratio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // #19: WCAG AA for normal-size text (< 18px, < 14px bold) is 4.5:1.
  group('A11Y-C #19 contrast ratios (pure, both modes)', () {
    test('A11Y-C01 muted text on white and on the page background passes AA', () {
      expect(_ratio(AppColors.muted, Colors.white), greaterThanOrEqualTo(4.5));
      expect(_ratio(AppColors.muted, AppColors.page), greaterThanOrEqualTo(4.5));
      expect(_ratio(AppColors.label, Colors.white), greaterThanOrEqualTo(4.5));
    });
    test('A11Y-C02 control: the old #94A3B8 grey fails AA (detector works)', () {
      expect(_ratio(const Color(0xFF94A3B8), Colors.white), lessThan(4.5));
    });
    test('A11Y-C03 selector: unselected muted on track and selected primary on white pass AA', () {
      expect(_ratio(AppColors.muted, AppColors.track), greaterThanOrEqualTo(4.5),
          reason: 'unselected option text (12-13px) muted #64748B on track #F1F5F9');
      expect(_ratio(AppColors.primary, Colors.white), greaterThanOrEqualTo(4.5),
          reason: 'selected option text (12-13px) primary #6366F1 on white');
    }, skip: _ff ? null : 'CONFIRMED #19/#17: 4.34:1 and 4.47:1 (< 4.5); QA_FAILING_FIRST=true');
  });
  group('[needs --dart-define=DOCEASE_DEV_MODE=true]', _main, skip: !kDevMode);
}

void _main() {
  late Directory root;
  late Directory support;
  setUpAll(loadRealFonts);
  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_a11y');
    support = Directory('${root.path}/support')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Doctor doc() => Doctor(
      id: 'local', title: 'Dr.', name: 'Meera Rao', email: 'meera@example.com', age: '45',
      mobileNumber: '9800000000', specialty: 'General Physician', clinicName: 'QA Clinic',
      practiceMode: 'Clinic');

  QaDb seeded() {
    final db = QaDb();
    seedPatient(db, 'a1b2c3d4-e5f6-7890-abcd-ef0123456789', 'Asha Verma', history: [
      visitOn('v1', DateTime.now(), diagnosis: 'Acute bronchitis', prescription: 'Azithromycin 500mg',
          bp: '130/85', temp: '99.1', pulse: '88', weight: '62'),
      visitOn('v2', DateTime(2026, 2, 1), diagnosis: 'Migraine', prescription: 'Naproxen 250mg'),
    ]);
    return db;
  }

  Future<Rig> home(WidgetTester t) async {
    final r = await boot(t, db: seeded(), support: support);
    await t.runAsync(() => r.doctor.saveDoctorProfile(doc()));
    await settle(t, 5);
    return r;
  }

  group('A11Y #17 claims', () {
    testWidgets('A11Y-01 each Daily Pulse card reads as one item "Label: value"', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      expect(find.bySemanticsLabel(RegExp(r'^Today Patients: \d+$')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Today Visits: \d+$')), findsOneWidget);
      h.dispose();
    });

    testWidgets('A11Y-02 detail AppBar and visit sheet icons have tooltips', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      await tapText(t, 'Asha Verma');
      expect(find.byTooltip('Export PDF'), findsOneWidget);
      await tapText(t, 'Acute bronchitis');
      for (final tip in ['Edit visit', 'Delete visit', 'Share visit']) {
        expect(find.byTooltip(tip), findsOneWidget, reason: tip);
      }
      h.dispose();
    });

    testWidgets('A11Y-02b GAP (not claimed by #17): every detail IconButton has a tooltip', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Acute bronchitis');
      final untipped = t.widgetList<IconButton>(find.byType(IconButton))
          .where((b) => (b.tooltip ?? '').isEmpty)
          .map((b) => b.icon is Icon ? '${(b.icon as Icon).icon}' : '${b.icon.runtimeType}')
          .toList();
      expect(untipped, isEmpty, reason: 'IconButtons without tooltip on detail + visit sheet');
      h.dispose();
    }, skip: !_ff); // detail AppBar edit-patient / delete-patient IconButtons have no tooltip or label

    testWidgets('A11Y-03 the visit card is announced as a button', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      await tapText(t, 'Asha Verma');
      expect(t.getSemantics(find.text('Acute bronchitis').first), containsSemantics(isButton: true));
      h.dispose();
    });

    testWidgets('A11Y-04 visit form: type selector is an exclusive group with selected state; date is a button', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Add Clinical Note');
      final opts = ['Initial Visit', 'Follow-up', 'Routine'];
      var selected = 0;
      for (final o in opts) {
        final s = t.getSemantics(find.text(o));
        expect(s, containsSemantics(isInMutuallyExclusiveGroup: true, isButton: true), reason: o);
        if (s.hasFlag(SemanticsFlag.isSelected)) selected++;
      }
      expect(selected, 1, reason: 'exactly one visit type is announced as selected');
      expect(find.bySemanticsLabel(RegExp('^Visit date')), findsOneWidget);
      expect(t.getSemantics(find.bySemanticsLabel(RegExp('^Visit date'))), containsSemantics(isButton: true));
      h.dispose();
    });

    testWidgets('A11Y-05 patient form: gender selector exposes selected state', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      await tapText(t, 'Register Patient');
      var selected = 0;
      for (final o in ['Male', 'Female', 'Other']) {
        final s = t.getSemantics(find.text(o));
        expect(s, containsSemantics(isInMutuallyExclusiveGroup: true), reason: o);
        if (s.hasFlag(SemanticsFlag.isSelected)) selected++;
      }
      expect(selected, 1);
      h.dispose();
    });
  });

  // ---------------------------------------------------------------- guidelines
  final baselineFile = Platform.environment['QA_A11Y_BASELINE'];
  final baseline = baselineFile == null || !File(baselineFile).existsSync()
      ? null
      : {
          for (final m in File(baselineFile).readAsLinesSync()
              .map(RegExp(r'^A11Y-G-COUNT (\S+) (\S+) n=(\d+)').firstMatch)
              .whereType<RegExpMatch>())
            '${m[1]} ${m[2]}': int.parse(m[3]!)
        };

  final guidelines = <String, AccessibilityGuideline>{
    'labeledTapTarget': labeledTapTargetGuideline,
    'androidTapTarget': androidTapTargetGuideline,
    'textContrast': textContrastGuideline,
  };

  final screens = <String, Future<void> Function(WidgetTester)>{
    'home': (t) async {},
    'detail': (t) async => tapText(t, 'Asha Verma'),
    'visitSheet': (t) async {
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Acute bronchitis');
    },
    'visitForm': (t) async {
      await tapText(t, 'Asha Verma');
      await tapText(t, 'Add Clinical Note');
    },
    'patientForm': (t) async => tapText(t, 'Register Patient'),
    'profile': (t) async {
      await t.tap(find.byTooltip('Open navigation menu'));
      await settle(t);
      await tapText(t, 'Professional Profile');
    },
  };

  /// One stable line per violation, without render-object ids or offsets.
  List<String> violations(String screen, String g, Evaluation e) {
    if (e.passed) return const [];
    return e.reason!.split('\n').where((l) => l.trim().isNotEmpty).map((l) {
      final clean = l
          .replaceAll(RegExp(r'#[0-9a-f]{5}'), '')
          .replaceAll(RegExp(r'Rect\.fromLTRB\([^)]*\)'), 'Rect')
          .replaceAll(RegExp(r'\d+\.\d+'), 'N')
          .trim();
      return 'A11Y-G $screen $g :: $clean';
    }).toList();
  }

  for (final s in screens.entries) {
    testWidgets('A11Y-G ${s.key}: no new guideline violations vs base', (t) async {
      final h = t.ensureSemantics();
      await home(t);
      await s.value(t);
      await settle(t);
      final found = <String>[];
      final over = <String>[];
      for (final g in guidelines.entries) {
        final e = await g.value.evaluate(t);
        final v = violations(s.key, g.key, e);
        // ignore: avoid_print
        print('A11Y-G-COUNT ${s.key} ${g.key} n=${v.where((l) => l.contains('SemanticsNode')).length}');
        for (final l in v) {
          // ignore: avoid_print
          print(l);
        }
        found.addAll(v);
        final n = v.where((l) => l.contains('SemanticsNode')).length;
        final base = baseline?['${s.key} ${g.key}'];
        if (base != null && n > base) over.add('${s.key} ${g.key}: $n > base $base');
      }
      h.dispose();
      if (baseline != null) {
        expect(over, isEmpty, reason: 'more violations than base:\n${found.join('\n')}');
      }
    });
  }
}
