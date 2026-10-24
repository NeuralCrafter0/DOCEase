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
  ///
  /// The learned list is doctor-wide and synced, so only lines that
  /// [looksLikeMedicine] are kept, plus lines that are exactly a name the
  /// doctor already has in [known] (picked from the suggestions). Free-text
  /// instructions such as "review with sugar report Monday" are never kept.
  static List<String> medicineNames(String prescription, {Iterable<String> dosages = const [], Iterable<String> known = const []}) {
    final skip = {for (final d in dosages) d.trim().toLowerCase()};
    final picked = {for (final k in known) k.trim().toLowerCase()};
    final names = <String>[];
    for (final raw in prescription.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('-')) continue;
      final cut = line.indexOf(dosageSeparator);
      if (cut != -1) line = line.substring(0, cut).trim();
      if (line.isEmpty || skip.contains(line.toLowerCase())) continue;
      if (!looksLikeMedicine(line) && !picked.contains(line.toLowerCase())) continue;
      if (!names.contains(line)) names.add(line);
    }
    return names;
  }

  static final _sentencePunctuation = RegExp(r'[,;:!?"]|\.$|\.\s+\p{Ll}', unicode: true);
  static final _startsWithLetter = RegExp(r'^\p{L}', unicode: true);
  static final _hasDigit = RegExp(r'\d');

  /// Words that turn a line into an instruction or note rather than a drug
  /// name (prepositions, follow-up and timing words).
  static const _instructionWords = {
    'a', 'an', 'the', 'and', 'or', 'if', 'with', 'without', 'on', 'at', 'in',
    'to', 'for', 'of', 'from', 'by', 'after', 'before', 'then', 'when', 'until',
    'next', 'review', 'follow', 'followup', 'follow-up', 'revisit', 'visit',
    'report', 'reports', 'test', 'tests', 'check', 'repeat', 'continue', 'stop',
    'avoid', 'advice', 'advised', 'come', 'call', 'please', 'today', 'tomorrow',
    'day', 'days', 'week', 'weeks', 'month', 'months', 'monday', 'tuesday',
    'wednesday', 'thursday', 'friday', 'saturday', 'sunday',
  };

  /// Whether [name] reads like a drug name ("Azithromycin 500mg",
  /// "Tab. Dolo 650", "Amoxicillin-Clavulanate 625mg") rather than a note:
  /// at most 60 characters, starts with a letter, no sentence punctuation, no
  /// instruction words, at most 6 words (3 when there is no strength digit).
  static bool looksLikeMedicine(String name) {
    final n = name.trim();
    if (n.length < 2 || n.length > 60) return false;
    if (!_startsWithLetter.hasMatch(n) || _sentencePunctuation.hasMatch(n)) return false;
    final words = n.split(RegExp(r'\s+'));
    if (words.length > (_hasDigit.hasMatch(n) ? 6 : 3)) return false;
    return !words.any((w) => _instructionWords.contains(w.toLowerCase().replaceAll('.', '')));
  }

  /// Applies a dosage chip to the last medicine in [text]:
  /// - "Azithromycin 500mg" -> "Azithromycin 500mg - OD (1-0-0)\n"
  /// - a line that already has a dosage gets it replaced, not a second one
  /// - an empty prescription gets the dosage on its own line, never " - OD".
  /// The caret goes to the end, ready for the next medicine.
  static TextEditingValue applyDosage(String text, String dosage) {
    final body = text.replaceFirst(RegExp(r'\s+$'), '');
    final lineStart = body.lastIndexOf('\n') + 1;
    final before = body.substring(0, lineStart);
    var line = body.substring(lineStart).trim();
    final cut = line.indexOf(dosageSeparator);
    if (cut != -1) line = line.substring(0, cut).trim();
    final newLine = line.isEmpty ? dosage : '$line$dosageSeparator$dosage';
    final newText = '$before$newLine\n';
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}
