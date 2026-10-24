// DOCEase design tokens. Every colour, space, radius and duration used by
// screens and widgets comes from here (or from the ThemeData built in
// app_theme.dart). Screens never write raw Color(0x...) values, Colors.*
// or inline TextStyle(...) (QA plan sections 4 and 8).
//
// Contrast: every text pair below was checked against WCAG 2.1 AA
// (4.5:1 for text, 3:1 for field borders). The numbers are in
// docs/design/DESIGN_SYSTEM.md and pinned by test/ui/tokens_contrast_test.dart.
import 'package:flutter/material.dart';

/// Semantic colours for one brightness. Read with `context.ds` (see
/// [DsContext]) so light and dark themes switch together.
@immutable
class DsColors extends ThemeExtension<DsColors> {
  const DsColors({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.sunken,
    required this.ink,
    required this.inkSecondary,
    required this.inkMuted,
    required this.line,
    required this.lineStrong,
    required this.primary,
    required this.onPrimary,
    required this.primaryTint,
    required this.onPrimaryTint,
    required this.danger,
    required this.onDanger,
    required this.dangerTint,
    required this.warn,
    required this.warnTint,
    required this.accent,
    required this.accentTint,
    required this.info,
    required this.infoTint,
    required this.inverse,
    required this.onInverse,
    required this.inversePrimary,
    required this.scrim,
    required this.shadow,
    required this.avatarTones,
  });

  final Brightness brightness;

  /// Page background behind cards.
  final Color canvas;
  /// Cards, sheets, fields, app chrome.
  final Color surface;
  /// Recessed areas: segmented tracks, chips, empty tiles.
  final Color sunken;

  /// Primary text.
  final Color ink;
  /// Secondary text (subtitles, values in meta rows).
  final Color inkSecondary;
  /// Captions, hints, placeholder text. Still 4.5:1 on every surface.
  final Color inkMuted;

  /// Hairline dividers and card outlines (decorative).
  final Color line;
  /// Field borders and controls that must be seen (3:1 on surface).
  final Color lineStrong;

  /// Brand teal: primary actions, selection, focus.
  final Color primary;
  final Color onPrimary;
  final Color primaryTint;
  final Color onPrimaryTint;

  /// Destructive actions and errors.
  final Color danger;
  final Color onDanger;
  final Color dangerTint;

  /// Warnings (stale data, paused editing).
  final Color warn;
  final Color warnTint;

  /// Warm accent for highlights (today's activity, latest visit).
  final Color accent;
  final Color accentTint;

  /// Neutral information (vitals, sync state).
  final Color info;
  final Color infoTint;

  /// Inverse surfaces: snack bars and tooltips.
  final Color inverse;
  final Color onInverse;
  final Color inversePrimary;

  final Color scrim;
  final Color shadow;

  /// Background/foreground pairs for monogram avatars, picked by a stable
  /// hash of the record id (never the name).
  final List<({Color bg, Color fg})> avatarTones;

  bool get isDark => brightness == Brightness.dark;

  /// Stable tone for an id (a UUID). Never derived from patient data.
  ({Color bg, Color fg}) toneFor(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return avatarTones[h % avatarTones.length];
  }

  static const light = DsColors(
    brightness: Brightness.light,
    canvas: Color(0xFFF6F5F1),
    surface: Color(0xFFFFFFFF),
    sunken: Color(0xFFEFEDE7),
    ink: Color(0xFF17212B),
    inkSecondary: Color(0xFF46525E),
    inkMuted: Color(0xFF5E6A75),
    line: Color(0xFFE3E0D8),
    lineStrong: Color(0xFF8F8A80),
    primary: Color(0xFF0B6B5D),
    onPrimary: Color(0xFFFFFFFF),
    primaryTint: Color(0xFFE1F0EC),
    onPrimaryTint: Color(0xFF08493F),
    danger: Color(0xFFB42318),
    onDanger: Color(0xFFFFFFFF),
    dangerTint: Color(0xFFFCEBE9),
    warn: Color(0xFF7A5200),
    warnTint: Color(0xFFFFF3D6),
    accent: Color(0xFFA34B0B),
    accentTint: Color(0xFFFDF0E3),
    info: Color(0xFF285C8F),
    infoTint: Color(0xFFE6EFF8),
    inverse: Color(0xFF17212B),
    onInverse: Color(0xFFF6F5F1),
    inversePrimary: Color(0xFF7FD6C5),
    scrim: Color(0xFF0B1116),
    shadow: Color(0xFF17212B),
    avatarTones: [
      (bg: Color(0xFFE1F0EC), fg: Color(0xFF08493F)),
      (bg: Color(0xFFE6EFF8), fg: Color(0xFF1F4A75)),
      (bg: Color(0xFFFDF0E3), fg: Color(0xFF7F3B07)),
      (bg: Color(0xFFF1E9F7), fg: Color(0xFF5B2E7A)),
      (bg: Color(0xFFFCEBE9), fg: Color(0xFF8A1C13)),
      (bg: Color(0xFFEEF1E2), fg: Color(0xFF44501A)),
    ],
  );

  static const dark = DsColors(
    brightness: Brightness.dark,
    canvas: Color(0xFF0E1316),
    surface: Color(0xFF151C20),
    sunken: Color(0xFF1C252A),
    ink: Color(0xFFE7ECEE),
    inkSecondary: Color(0xFFB7C1C6),
    inkMuted: Color(0xFF929DA4),
    line: Color(0xFF2A353B),
    lineStrong: Color(0xFF5E6B72),
    primary: Color(0xFF5FC4B1),
    onPrimary: Color(0xFF06302A),
    primaryTint: Color(0xFF123A33),
    onPrimaryTint: Color(0xFFA6E5D8),
    danger: Color(0xFFF4A097),
    onDanger: Color(0xFF2A0D0A),
    dangerTint: Color(0xFF3A1B18),
    warn: Color(0xFFF0C46A),
    warnTint: Color(0xFF33280F),
    accent: Color(0xFFF2A765),
    accentTint: Color(0xFF3A2614),
    info: Color(0xFF8DB8E6),
    infoTint: Color(0xFF16283A),
    inverse: Color(0xFFE7ECEE),
    onInverse: Color(0xFF151C20),
    inversePrimary: Color(0xFF0B6B5D),
    scrim: Color(0xFF000000),
    shadow: Color(0xFF000000),
    avatarTones: [
      (bg: Color(0xFF123A33), fg: Color(0xFFA6E5D8)),
      (bg: Color(0xFF16283A), fg: Color(0xFFB4D2F0)),
      (bg: Color(0xFF3A2614), fg: Color(0xFFF6C9A0)),
      (bg: Color(0xFF2C2038), fg: Color(0xFFD9C2EC)),
      (bg: Color(0xFF3A1B18), fg: Color(0xFFF6BDB6)),
      (bg: Color(0xFF262C16), fg: Color(0xFFD3DCA8)),
    ],
  );

  @override
  DsColors copyWith() => this;

  @override
  DsColors lerp(ThemeExtension<DsColors>? other, double t) {
    if (other is! DsColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return DsColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      canvas: l(canvas, other.canvas),
      surface: l(surface, other.surface),
      sunken: l(sunken, other.sunken),
      ink: l(ink, other.ink),
      inkSecondary: l(inkSecondary, other.inkSecondary),
      inkMuted: l(inkMuted, other.inkMuted),
      line: l(line, other.line),
      lineStrong: l(lineStrong, other.lineStrong),
      primary: l(primary, other.primary),
      onPrimary: l(onPrimary, other.onPrimary),
      primaryTint: l(primaryTint, other.primaryTint),
      onPrimaryTint: l(onPrimaryTint, other.onPrimaryTint),
      danger: l(danger, other.danger),
      onDanger: l(onDanger, other.onDanger),
      dangerTint: l(dangerTint, other.dangerTint),
      warn: l(warn, other.warn),
      warnTint: l(warnTint, other.warnTint),
      accent: l(accent, other.accent),
      accentTint: l(accentTint, other.accentTint),
      info: l(info, other.info),
      infoTint: l(infoTint, other.infoTint),
      inverse: l(inverse, other.inverse),
      onInverse: l(onInverse, other.onInverse),
      inversePrimary: l(inversePrimary, other.inversePrimary),
      scrim: l(scrim, other.scrim),
      shadow: l(shadow, other.shadow),
      avatarTones: t < 0.5 ? avatarTones : other.avatarTones,
    );
  }
}

/// 4-pt spacing scale.
abstract final class Space {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 40;
  static const double giant = 56;

  /// Horizontal page gutter on phones; tablets use [Layout.gutterFor].
  static const double gutter = 20;
}

abstract final class Radii {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double pill = 999;

  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius field = BorderRadius.all(Radius.circular(md));
  static const BorderRadius control = BorderRadius.all(Radius.circular(md));
  static const BorderRadius chip = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xl));
}

/// Durations and curves. Always read through [Motion.of] so reduced motion
/// (`MediaQuery.disableAnimations`) turns every animation into a jump.
abstract final class Motion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration emphasized = Duration(milliseconds: 280);
  static const Duration page = Duration(milliseconds: 280);
  static const Duration pageReverse = Duration(milliseconds: 240);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;
  static const Curve move = Curves.easeInOutCubic;

  static bool reduced(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [d], or zero when the user asked for reduced motion.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}

/// Width classes. Compact phones, medium (large phones in landscape, small
/// tablets) and expanded (tablets, desktop).
enum WidthClass { compact, medium, expanded }

abstract final class Layout {
  static const double mediumMin = 600;
  static const double expandedMin = 960;

  /// Readable column for forms and detail pages.
  static const double contentMax = 760;
  /// Forms read best a little narrower.
  static const double formMax = 640;
  static const double sidebarWidth = 280;

  static WidthClass classOf(double width) => width >= expandedMin
      ? WidthClass.expanded
      : width >= mediumMin
          ? WidthClass.medium
          : WidthClass.compact;

  static WidthClass of(BuildContext context) => classOf(MediaQuery.sizeOf(context).width);

  static double gutterFor(double width) => width >= mediumMin ? Space.xxxl : Space.gutter;
}

/// Elevation is mostly expressed with hairlines; shadows are kept for
/// things that float (FAB, sheets, the pinned search).
abstract final class Shadows {
  static List<BoxShadow> floating(DsColors c) => [
        BoxShadow(color: c.shadow.withValues(alpha: c.isDark ? 0.5 : 0.10), blurRadius: 24, offset: const Offset(0, 8)),
        BoxShadow(color: c.shadow.withValues(alpha: c.isDark ? 0.3 : 0.06), blurRadius: 4, offset: const Offset(0, 1)),
      ];

  static List<BoxShadow> raised(DsColors c) => [
        BoxShadow(color: c.shadow.withValues(alpha: c.isDark ? 0.35 : 0.05), blurRadius: 12, offset: const Offset(0, 3)),
      ];
}

extension DsContext on BuildContext {
  /// The current semantic palette.
  DsColors get ds => Theme.of(this).extension<DsColors>() ?? DsColors.light;

  TextTheme get type => Theme.of(this).textTheme;
}
