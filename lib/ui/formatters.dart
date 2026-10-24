// Display formatting shared by the redesigned screens. Every function copes
// with any stored string: older or cloud rows may break the form rules.
import 'package:intl/intl.dart';

import '../models/patient.dart';

abstract final class Fmt {
  static bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  /// Whole calendar days from [d] to [now] in local time (0 = today).
  static int daysAgo(DateTime d, DateTime now) => _day(now).difference(_day(d.toLocal())).inDays;

  /// "Today", "Yesterday", "3 days ago", "12 Oct", "12 Oct 2023".
  /// An unreadable date is "Date unknown", never 1 Jan 1970.
  static String relativeDay(VisitRecord v, DateTime now) {
    if (v.dateInvalid) return 'Date unknown';
    final d = v.date.toLocal();
    final n = daysAgo(d, now);
    if (n == 0) return 'Today';
    if (n == 1) return 'Yesterday';
    if (n > 1 && n < 7) return '$n days ago';
    return shortDate(v, now);
  }

  /// "12 Oct" this year, "12 Oct 2023" otherwise; "Date unknown" if unreadable.
  static String shortDate(VisitRecord v, DateTime now) {
    if (v.dateInvalid) return 'Date unknown';
    final d = v.date.toLocal();
    return d.year == now.year ? DateFormat('d MMM').format(d) : DateFormat('d MMM yyyy').format(d);
  }

  /// "Saturday, 12 October 2024"; "Date unknown" if unreadable.
  static String longDate(VisitRecord v) => v.dateInvalid ? 'Date unknown' : DateFormat('EEEE, d MMMM yyyy').format(v.date.toLocal());

  /// Age as recorded at registration ("34 yrs"). It does not grow with time:
  /// there is no date of birth. Odd stored values are shown as typed.
  static String? age(String raw) {
    final a = raw.trim();
    if (a.isEmpty) return null;
    final n = int.tryParse(a);
    if (n == null) return a;
    return n == 1 ? '1 yr' : '$n yrs';
  }

  /// "34 yrs · Female", skipping empty parts.
  static String patientMeta(Patient p) {
    final parts = <String>[
      if (age(p.age) case final a?) a,
      if (p.gender.trim().isNotEmpty) p.gender.trim(),
    ];
    return parts.join(' · ');
  }

  static String visitsCount(int n) => n == 1 ? '1 visit' : '$n visits';

  static String greeting(DateTime now) {
    final h = now.hour;
    if (h < 12) return 'Good morning';
    if (h < 17) return 'Good afternoon';
    return 'Good evening';
  }

  static String today(DateTime now) => DateFormat('EEEE, d MMMM').format(now);

  /// Display grouping for stored numbers: "+91 98450 12345". Other
  /// countries' numbers are shown as stored, since their grouping varies.
  static String phone(String raw) {
    final t = raw.trim();
    final india = RegExp(r'^\+91(\d{5})(\d{5})$').firstMatch(t);
    if (india != null) return '+91 ${india[1]} ${india[2]}';
    final bare = RegExp(r'^(\d{5})(\d{5})$').firstMatch(t);
    if (bare != null) return '${bare[1]} ${bare[2]}';
    return t;
  }
}
