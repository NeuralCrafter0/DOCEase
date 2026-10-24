// Readable grey labels (UI map item 15): the muted token passes WCAG AA on
// white and the light page colour, and the screens fixed here no longer use
// #94A3B8, Colors.grey or 9-11px text for labels.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:docease/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

// Files covered by this fix. insights_screen.dart is left for after #11
// merges, because #11 rewrites those lines.
const _files = [
  'lib/screens/patient_detail_screen.dart',
  'lib/screens/add_record_screen.dart',
  'lib/screens/home_screen.dart',
  'lib/widgets/stat_card.dart',
];

// latin1: main's patient_detail_screen.dart still has a cp1252 byte until #3.
String _src(String p) => File(p).readAsStringSync(encoding: latin1);

void main() {
  test('muted grey passes WCAG AA (4.5:1) on white and the page colour', () {
    expect(contrast(AppColors.muted, Colors.white), greaterThanOrEqualTo(4.5));
    expect(contrast(AppColors.muted, AppColors.page), greaterThanOrEqualTo(4.5));
  });

  test('the old greys fail AA, so this fix is needed', () {
    expect(contrast(const Color(0xFF94A3B8), Colors.white), lessThan(4.5));
    expect(contrast(Colors.grey, Colors.white), lessThan(4.5));
  });

  for (final f in _files) {
    test('$f: no #94A3B8 and no text below 11px', () {
      final s = _src(f);
      expect(s.contains('0xFF94A3B8'), isFalse);
      expect(RegExp(r'fontSize: (9|10)\b').hasMatch(s), isFalse);
    });
  }

  test('11px is only the stat card caption; screen labels are at least 12px', () {
    for (final f in _files.where((f) => f.contains('/screens/'))) {
      expect(RegExp(r'fontSize: 11\b').hasMatch(_src(f)), isFalse, reason: f);
    }
  });

  test('stat card caption and detail visit-type badge use the muted token', () {
    expect(_src('lib/widgets/stat_card.dart'), contains('color: AppColors.muted'));
    final detail = _src('lib/screens/patient_detail_screen.dart');
    expect(detail, contains(': AppColors.muted, fontSize: 12'));
    expect(detail.contains(': Colors.grey, fontSize'), isFalse);
  });
}
