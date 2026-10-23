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
