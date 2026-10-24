import '../models/patient.dart';

/// The vitals the visit form records, as chartable series.
enum VitalKind {
  bp('Blood Pressure', 'mmHg'),
  pulse('Pulse', 'bpm'),
  temp('Temperature', '°F'),
  weight('Weight', 'kg'),
  sugar('Blood Sugar', 'mg/dL');

  const VitalKind(this.label, this.unit);
  final String label;
  final String unit;

  String? rawOf(VisitRecord r) => switch (this) {
        VitalKind.bp => r.bp,
        VitalKind.pulse => r.pulse,
        VitalKind.temp => r.temp,
        VitalKind.weight => r.weight,
        VitalKind.sugar => r.sugar,
      };

  /// A light "typical adult range" band for the chart, or null.
  (double, double)? get typicalRange => switch (this) {
        VitalKind.bp => null, // two lines; see bpTypical
        VitalKind.pulse => (60, 100),
        VitalKind.temp => (97, 99.5),
        VitalKind.weight => null,
        VitalKind.sugar => (70, 140),
      };
}

/// Typical adult systolic / diastolic upper limits, drawn as dashed lines.
const bpTypical = (systolic: 120.0, diastolic: 80.0);

/// One reading on a chart. [value] is in [VitalKind.unit]; for BP it is the
/// systolic and [value2] the diastolic.
class VitalPoint {
  const VitalPoint({required this.date, required this.value, this.value2, required this.raw, required this.recordId});
  final DateTime date;
  final double value;
  final double? value2;
  final String raw;
  final String recordId;
}

/// A whole series for one patient and vital, oldest first.
class VitalSeries {
  const VitalSeries(this.kind, this.points, this.unreadable);
  final VitalKind kind;
  final List<VitalPoint> points;

  /// Filled-in values that could not be read as a number (or were outside
  /// any plausible range), so the screen can say so instead of hiding them.
  final int unreadable;

  bool get isEmpty => points.isEmpty;
  VitalPoint? get latest => points.isEmpty ? null : points.last;
  VitalPoint? get previous => points.length < 2 ? null : points[points.length - 2];
  double? get min => points.isEmpty ? null : points.map((p) => p.value).reduce((a, b) => a < b ? a : b);
  double? get max => points.isEmpty ? null : points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
}

final _number = RegExp(r'(\d+(?:[.,]\d+)?)');
final _bp = RegExp(r'(\d{2,3})\s*[/\\-]\s*(\d{2,3})');

double? _firstNumber(String s) {
  final m = _number.firstMatch(s);
  return m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', '.'));
}

/// Systolic/diastolic from text like "120/80", "120 / 80 mmHg", "120-80".
(double, double)? parseBp(String raw) {
  final m = _bp.firstMatch(raw);
  if (m == null) return null;
  final sys = double.parse(m.group(1)!), dia = double.parse(m.group(2)!);
  if (sys < 50 || sys > 300 || dia < 20 || dia > 200 || sys <= dia) return null;
  return (sys, dia);
}

/// Temperature in °F. "37.2 C" / "37.2°C" / a bare 30-45 are Celsius.
double? parseTempF(String raw) {
  final v = _firstNumber(raw);
  if (v == null) return null;
  final s = raw.toLowerCase();
  final saysC = RegExp(r'°\s*c|\dc\b|\sc\b|celsius').hasMatch(s);
  final saysF = RegExp(r'°\s*f|\df\b|\sf\b|fahrenheit').hasMatch(s);
  final f = (saysC || (!saysF && v >= 30 && v <= 45)) ? v * 9 / 5 + 32 : v;
  return (f >= 86 && f <= 113) ? f : null;
}

/// Pulse in bpm.
double? parsePulse(String raw) {
  final v = _firstNumber(raw);
  return (v != null && v >= 20 && v <= 250) ? v : null;
}

/// Weight in kg. "lb" / "lbs" values are converted.
double? parseWeightKg(String raw) {
  var v = _firstNumber(raw);
  if (v == null) return null;
  if (RegExp(r'\blbs?\b|pound').hasMatch(raw.toLowerCase())) v = v * 0.45359237;
  return (v >= 0.5 && v <= 400) ? v : null;
}

/// Blood sugar in mg/dL. "mmol" values, and bare values under 25 (which can
/// only be mmol/L), are converted with 1 mmol/L = 18 mg/dL.
double? parseSugarMgDl(String raw) {
  var v = _firstNumber(raw);
  if (v == null) return null;
  if (raw.toLowerCase().contains('mmol') || v < 25) v = v * 18;
  return (v >= 10 && v <= 1500) ? v : null;
}

/// The [kind] series for [history], oldest first. Same-day visits keep the
/// order they were entered in (history is newest-first).
VitalSeries vitalSeries(List<VisitRecord> history, VitalKind kind) {
  final indexed = [for (var i = 0; i < history.length; i++) (i, history[i])];
  indexed.sort((a, b) {
    final c = a.$2.date.compareTo(b.$2.date);
    return c != 0 ? c : b.$1.compareTo(a.$1);
  });
  final points = <VitalPoint>[];
  var unreadable = 0;
  for (final (_, r) in indexed) {
    final raw = kind.rawOf(r)?.trim() ?? '';
    if (raw.isEmpty) continue;
    double? v, v2;
    switch (kind) {
      case VitalKind.bp:
        final bp = parseBp(raw);
        if (bp != null) (v, v2) = bp;
      case VitalKind.pulse:
        v = parsePulse(raw);
      case VitalKind.temp:
        v = parseTempF(raw);
      case VitalKind.weight:
        v = parseWeightKg(raw);
      case VitalKind.sugar:
        v = parseSugarMgDl(raw);
    }
    if (v == null) {
      unreadable++;
      continue;
    }
    points.add(VitalPoint(date: r.date, value: v, value2: v2, raw: raw, recordId: r.id));
  }
  return VitalSeries(kind, points, unreadable);
}

/// Compact number for labels: "98.6", "120", "72.5".
String formatVital(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
