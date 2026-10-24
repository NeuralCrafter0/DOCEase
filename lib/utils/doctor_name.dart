import '../models/doctor.dart';

final RegExp _leadingDr = RegExp(r'^dr\.?\s+', caseSensitive: false);

/// How the doctor is named on share text and on the PDF letterhead:
/// "Dr. John". The profile's title is an honorific (MR / MRS / MS) and is
/// not shown next to "Dr.". A name typed as "Dr John" is not doubled.
/// Returns null when there is no doctor or no name.
String? doctorDisplayName(Doctor? doctor) {
  final name = (doctor?.name ?? '').trim().replaceFirst(_leadingDr, '').trim();
  return name.isEmpty ? null : 'Dr. $name';
}
