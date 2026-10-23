import 'package:flutter/widgets.dart';

/// Helpers for the multi-line prescription field, where each line is one
/// medicine. Type-ahead works on the line the caret is on, not on the whole
/// field.
class PrescriptionLines {
  PrescriptionLines._();

  /// Start/end offsets of the line containing [caret] in [text].
  static (int, int) _lineBounds(String text, int caret) {
    final c = caret.clamp(0, text.length);
    final start = c == 0 ? 0 : text.lastIndexOf('\n', c - 1) + 1;
    final nl = text.indexOf('\n', c);
    final end = nl == -1 ? text.length : nl;
    return (start, end);
  }

  static int _caret(TextEditingValue value) =>
      value.selection.isValid ? value.selection.extentOffset : value.text.length;

  /// The text of the line being typed, trimmed. Empty when the caret is on an
  /// empty line.
  static String currentQuery(TextEditingValue value) {
    final (start, end) = _lineBounds(value.text, _caret(value));
    return value.text.substring(start, end).trim();
  }

  /// Medicines matching the current line (case-insensitive substring).
  static List<String> suggestionsFor(TextEditingValue value, Iterable<String> medicines) {
    final q = currentQuery(value).toLowerCase();
    if (q.isEmpty) return const [];
    return medicines.where((m) => m.toLowerCase().contains(q)).toList();
  }

  /// Replaces only the current line with [suggestion]. Earlier and later
  /// lines are kept; the caret goes to the end of the completed line.
  static TextEditingValue applySuggestion(TextEditingValue value, String suggestion) {
    final text = value.text;
    final (start, end) = _lineBounds(text, _caret(value));
    final newText = text.replaceRange(start, end, suggestion);
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + suggestion.length),
    );
  }

  /// Separator the dosage chips put between a medicine and its dosage.
  static const String dosageSeparator = ' - ';

  /// The medicine names to remember from a saved prescription: one per line,
  /// with any dosage after [dosageSeparator] removed. Blank lines, lines that
  /// are only a dosage (one of [dosages], or starting with "-"), and repeats
  /// are skipped.
  static List<String> medicineNames(String prescription, {Iterable<String> dosages = const []}) {
    final skip = {for (final d in dosages) d.trim().toLowerCase()};
    final names = <String>[];
    for (final raw in prescription.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('-')) continue;
      final cut = line.indexOf(dosageSeparator);
      if (cut != -1) line = line.substring(0, cut).trim();
      if (line.isEmpty || skip.contains(line.toLowerCase())) continue;
      if (!names.contains(line)) names.add(line);
    }
    return names;
  }
}
