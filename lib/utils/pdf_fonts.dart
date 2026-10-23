import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart' as pw;

/// Fonts for the patient PDF.
///
/// The pdf package's built-in fonts (Helvetica) only cover Latin, so a
/// Hindi name such as 'राम शर्मा' vanished from the report. The bundled
/// Noto Sans Devanagari (SIL Open Font License 1.1, licence next to the
/// font in assets/fonts/) is added as a fallback: Latin text keeps
/// Helvetica, Devanagari characters are drawn with Noto.
///
/// Limitation: the pdf package does no Indic shaping, so conjuncts and the
/// reph (e.g. 'र्म' in 'शर्मा') print as separate letters with a visible
/// halant. Names stay readable and searchable, not typeset perfectly.
class PdfFonts {
  PdfFonts._();

  static const devanagariAsset = 'assets/fonts/NotoSansDevanagari-Regular.ttf';

  static pw.ThemeData? _theme;

  /// Page theme with the Devanagari fallback, or null (pdf defaults) until
  /// [ensureLoaded] has run or when the font could not be loaded.
  static pw.ThemeData? get theme => _theme;

  /// Loads the bundled font once. Never throws: without it the report is
  /// still produced, only Devanagari text is missing.
  static Future<void> ensureLoaded({AssetBundle? bundle}) async {
    if (_theme != null) return;
    try {
      final data = await (bundle ?? rootBundle).load(devanagariAsset);
      _theme = pw.ThemeData.withFont(fontFallback: [pw.Font.ttf(data)]);
    } catch (e) {
      debugPrint('PdfFonts: Devanagari font not loaded (${e.runtimeType})');
    }
  }

  @visibleForTesting
  static void reset() => _theme = null;
}
