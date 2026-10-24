import '../models/patient.dart';

/// One vital as entered on the visit form, ready to display.
typedef VitalEntry = ({String label, String value});

/// The vitals recorded on [record], in form order (BP, Temp, Pulse, Weight,
/// Sugar), skipping empty ones. Values are shown exactly as entered.
///
/// Every place that lists a visit's vitals (timeline chips, visit details,
/// PDF) uses this, so a vital is never hidden just because BP is empty.
List<VitalEntry> filledVitals(VisitRecord record) {
  final out = <VitalEntry>[];
  void add(String label, String? value) {
    final v = value?.trim() ?? '';
    if (v.isNotEmpty) out.add((label: label, value: v));
  }

  add('BP', record.bp);
  add('Temp', record.temp);
  add('Pulse', record.pulse);
  add('Weight', record.weight);
  add('Sugar', record.sugar);
  return out;
}

/// "BP: 120/80 | Temp: 98.6 | Sugar: 110" for one-line displays.
String vitalsLine(VisitRecord record) => filledVitals(record).map((v) => '${v.label}: ${v.value}').join(' | ');
