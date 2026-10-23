import '../models/patient.dart';

/// Visit history in clinical order. The stored list is in insertion order
/// (new notes are inserted at index 0), so a backdated note added later sits
/// first even though it is older. Anything that means "latest visit" or shows
/// the timeline should use these instead of `history.first` / list order.
extension VisitHistoryOrder on List<VisitRecord> {
  /// Newest visit date first. Visits on the same date keep their stored order,
  /// so the most recently added one comes first.
  List<VisitRecord> newestFirst() {
    final indexed = asMap().entries.toList()
      ..sort((a, b) {
        final byDate = b.value.date.compareTo(a.value.date);
        return byDate != 0 ? byDate : a.key.compareTo(b.key);
      });
    return [for (final e in indexed) e.value];
  }

  /// The visit with the latest date, or null when there are none.
  VisitRecord? get latestVisit => isEmpty ? null : newestFirst().first;
}
