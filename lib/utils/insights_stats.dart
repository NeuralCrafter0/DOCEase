import '../models/patient.dart';

/// Visit types offered on the visit form, in form order.
const formVisitTypes = ['Initial Visit', 'Follow-up', 'Routine'];

typedef MonthCount = ({DateTime month, int count});
typedef TypeCount = ({String type, int count});

/// Visits per calendar month for the [months] months ending with [now]'s
/// month, oldest first. Empty months are included as 0 so the chart keeps
/// its shape; visits outside the window are not counted.
List<MonthCount> visitsPerMonth(List<Patient> patients, DateTime now, {int months = 6}) {
  final starts = [for (var i = months - 1; i >= 0; i--) DateTime(now.year, now.month - i)];
  final counts = List<int>.filled(months, 0);
  for (final p in patients) {
    for (final r in p.history) {
      final m = DateTime(r.date.year, r.date.month);
      final i = starts.indexOf(m);
      if (i != -1) counts[i]++;
    }
  }
  return [for (var i = 0; i < months; i++) (month: starts[i], count: counts[i])];
}

/// How many visits of each type, form types first in form order, then any
/// other stored types by count. Types with no visits are left out.
List<TypeCount> visitTypeBreakdown(List<Patient> patients) {
  final counts = <String, int>{};
  for (final p in patients) {
    for (final r in p.history) {
      final t = r.visitType.trim().isEmpty ? 'Other' : r.visitType.trim();
      counts[t] = (counts[t] ?? 0) + 1;
    }
  }
  final known = [for (final t in formVisitTypes) if (counts.containsKey(t)) (type: t, count: counts[t]!)];
  final others = [for (final e in counts.entries) if (!formVisitTypes.contains(e.key)) (type: e.key, count: e.value)]
    ..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : a.type.compareTo(b.type));
  return [...known, ...others];
}
