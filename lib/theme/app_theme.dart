import 'package:flutter/material.dart';

/// Colours the screens already use (Tailwind slate / indigo / emerald).
///
/// Each value is the exact literal found inline in `lib/screens/`, so using a
/// token instead of the literal never changes what is drawn.
abstract final class AppColors {
  /// indigo-500: accents, icons, selected text.
  static const primary = Color(0xFF6366F1);

  /// slate-800: titles, values and the dark primary buttons.
  static const ink = Color(0xFF1E293B);

  /// slate-50: page background.
  static const page = Color(0xFFF8FAFC);

  /// slate-100: selector track and locked (read-only) fields.
  static const track = Color(0xFFF1F5F9);

  /// slate-200: card and field borders.
  static const border = Color(0xFFE2E8F0);

  /// slate-600: field labels.
  static const label = Color(0xFF475569);

  /// slate-500: secondary text, unselected options.
  static const muted = Color(0xFF64748B);

  /// emerald-500: success and "visits" accents.
  static const success = Color(0xFF10B981);
}

/// Corner radii the shared widgets use.
abstract final class AppRadii {
  /// Text fields.
  static const double field = 20;

  /// Primary buttons and stat cards.
  static const double button = 24;

  /// Segmented selector track.
  static const double track = 18;

  /// Segmented selector indicator.
  static const double thumb = 14;
}

/// Text styles shared by the extracted widgets.
abstract final class AppText {
  /// Bold 14px slate-600 label above a field or selector.
  static const label = TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppColors.label);

  /// Label on the dark primary button.
  static const button = TextStyle(fontWeight: FontWeight.bold, fontSize: 18);
}

/// The app theme.
///
/// [light] is the exact `ThemeData` that `main.dart` builds inline today
/// (Material 3, indigo seed, slate-50 surface). Component styles live in the
/// shared widgets (`lib/widgets/`) rather than in global component themes, so
/// screens that rely on Material defaults (the login form) keep their look.
abstract final class AppTheme {
  static final ColorScheme colorScheme = ColorScheme.fromSeed(seedColor: AppColors.primary, surface: AppColors.page);

  static ThemeData light() => ThemeData(useMaterial3: true, colorScheme: colorScheme);
}
