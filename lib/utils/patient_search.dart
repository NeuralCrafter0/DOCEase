/// Phone matching for the home-screen patient search.
///
/// Numbers are stored like '+919811111111', but doctors type them the way
/// they read them: '98111 11111', '+91 98111-11111' or '098111 11111'.
/// A query that looks like a phone number is compared on digits only, and a
/// leading +91 country code or 0 trunk prefix is ignored on both sides, so
/// a number saved without +91 is still found by a query that has it.
bool phoneMatchesQuery(String phone, String query) {
  final q = query.trim();
  if (!_digit.hasMatch(q)) return false;
  if (phone.contains(q)) return true;
  if (!_phoneLike.hasMatch(q)) return false;
  final digits = q.replaceAll(_nonDigit, '');
  if (digits.isEmpty) return false;
  final phoneDigits = phone.replaceAll(_nonDigit, '');
  if (phoneDigits.contains(digits)) return true;
  final national = _national(digits);
  return national.isNotEmpty && _national(phoneDigits).contains(national);
}

final _phoneLike = RegExp(r'^[+\d\s\-().]+$');
final _digit = RegExp(r'\d');
final _nonDigit = RegExp(r'\D');

/// Drops an Indian country code (91) or trunk prefix (0) from a full number.
String _national(String digits) {
  if (digits.length > 10 && digits.startsWith('91')) return digits.substring(2);
  if (digits.length == 11 && digits.startsWith('0')) return digits.substring(1);
  return digits;
}

/// Whether two stored phone numbers are the same number, for grouping a
/// patient's Family Network. Compared on digits only, ignoring a +91 country
/// code or 0 trunk prefix, so '+91 98111-11111' and '9811111111' match.
/// A number with fewer than [minFamilyPhoneDigits] digits (empty, or a
/// placeholder like '0') never matches anything: patients registered without
/// a phone must not all show up as one family.
bool samePhone(String a, String b) {
  final x = _familyDigits(a);
  final y = _familyDigits(b);
  if (x.length < minFamilyPhoneDigits || y.length < minFamilyPhoneDigits) return false;
  return x == y;
}

/// National digits of a stored number: an explicit +91 is dropped first, so
/// '+91 12345' counts as 5 digits, not 7.
String _familyDigits(String phone) {
  final t = phone.trim();
  final digits = t.replaceAll(_nonDigit, '');
  if (t.startsWith('+91')) return digits.substring(2);
  return _national(digits);
}

/// Shortest phone number that can link patients as one family.
const int minFamilyPhoneDigits = 7;
