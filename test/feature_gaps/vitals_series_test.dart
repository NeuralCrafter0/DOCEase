import 'package:docease/utils/vitals_series.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('parseBp', () {
    test('reads the common ways BP is typed', () {
      expect(parseBp('120/80'), (120.0, 80.0));
      expect(parseBp(' 135 / 88 mmHg'), (135.0, 88.0));
      expect(parseBp('140-90'), (140.0, 90.0));
    });
    test('rejects junk and impossible pairs', () {
      expect(parseBp('normal'), isNull);
      expect(parseBp('120'), isNull);
      expect(parseBp('80/120'), isNull, reason: 'systolic must be above diastolic');
      expect(parseBp('999/80'), isNull);
    });
  });

  group('parseTempF', () {
    test('Fahrenheit stays as typed', () {
      expect(parseTempF('98.6 F'), 98.6);
      expect(parseTempF('101'), 101);
      expect(parseTempF('99.1°F'), 99.1);
    });
    test('Celsius is converted, with or without a unit', () {
      expect(parseTempF('37 C'), closeTo(98.6, 1e-9));
      expect(parseTempF('38.5°C'), closeTo(101.3, 1e-9));
      expect(parseTempF('37'), closeTo(98.6, 1e-9));
    });
    test('implausible or missing values are dropped', () {
      expect(parseTempF('afebrile'), isNull);
      expect(parseTempF('200'), isNull);
    });
  });

  group('pulse, weight and sugar', () {
    test('pulse', () {
      expect(parsePulse('72 bpm'), 72);
      expect(parsePulse('5'), isNull);
    });
    test('weight in kg, pounds converted', () {
      expect(parseWeightKg('70 kg'), 70);
      expect(parseWeightKg('70,5'), 70.5);
      expect(parseWeightKg('154 lb'), closeTo(69.85, 0.01));
    });
    test('sugar in mg/dL, mmol/L converted', () {
      expect(parseSugarMgDl('110'), 110);
      expect(parseSugarMgDl('186 mg/dL'), 186);
      expect(parseSugarMgDl('7.8 mmol/L'), closeTo(140.4, 1e-9));
      expect(parseSugarMgDl('6.1'), closeTo(109.8, 1e-9), reason: 'bare values under 25 can only be mmol/L');
      expect(parseSugarMgDl('fasting'), isNull);
    });
  });

  group('vitalSeries', () {
    test('orders by visit date, oldest first, whatever the list order', () {
      final h = [
        visit('c', DateTime(2026, 3, 1), sugar: '150'),
        visit('a', DateTime(2026, 1, 1), sugar: '200'),
        visit('b', DateTime(2026, 2, 1), sugar: '180'),
      ];
      final s = vitalSeries(h, VitalKind.sugar);
      expect(s.points.map((p) => p.recordId), ['a', 'b', 'c']);
      expect(s.latest!.value, 150);
      expect(s.previous!.value, 180);
      expect(s.min, 150);
      expect(s.max, 200);
    });

    test('same-day visits keep the order they were entered (history is newest first)', () {
      final d = DateTime(2026, 1, 1);
      final s = vitalSeries([visit('second', d, pulse: '90'), visit('first', d, pulse: '80')], VitalKind.pulse);
      expect(s.points.map((p) => p.recordId), ['first', 'second']);
    });

    test('empty values are skipped; unreadable ones are counted, not charted', () {
      final h = [
        visit('a', DateTime(2026, 1, 1), bp: '130/85'),
        visit('b', DateTime(2026, 1, 2), bp: ''),
        visit('c', DateTime(2026, 1, 3), bp: 'normal'),
        visit('d', DateTime(2026, 1, 4)),
        visit('e', DateTime(2026, 1, 5), bp: '125/82'),
      ];
      final s = vitalSeries(h, VitalKind.bp);
      expect(s.points.map((p) => (p.value, p.value2)), [(130.0, 85.0), (125.0, 82.0)]);
      expect(s.unreadable, 1);
    });

    test('mixed units end up on one scale', () {
      final h = [visit('a', DateTime(2026, 1, 1), temp: '37 C'), visit('b', DateTime(2026, 1, 2), temp: '100.4 F')];
      expect(vitalSeries(h, VitalKind.temp).points.map((p) => p.value.toStringAsFixed(1)), ['98.6', '100.4']);
    });

    test('no visits gives an empty series', () {
      expect(vitalSeries(const [], VitalKind.weight).isEmpty, isTrue);
    });
  });

  test('formatVital', () {
    expect(formatVital(120), '120');
    expect(formatVital(98.6), '98.6');
    expect(formatVital(69.853), '69.9');
  });
}
