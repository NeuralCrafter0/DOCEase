// DOCEase theme: typography, colour scheme and component themes built from
// the tokens in tokens.dart. Screens style themselves through Theme.of /
// context.ds / context.type only.
import 'package:flutter/material.dart';

import 'tokens.dart';

export 'tokens.dart';

/// Legacy names from #17/#19, kept only until the M2 screens are rebuilt.
/// They now point at the new palette so old and new screens match.
/// New code uses `context.ds` instead.
abstract final class AppColors {
  static const primary = Color(0xFF0B6B5D);
  static const ink = Color(0xFF17212B);
  static const page = Color(0xFFF6F5F1);
  static const track = Color(0xFFEFEDE7);
  static const border = Color(0xFFE3E0D8);
  static const label = Color(0xFF46525E);
  static const muted = Color(0xFF5E6A75);
  static const success = Color(0xFF0B6B5D);
}

/// Legacy radii (see [AppColors]). New code uses [Radii].
abstract final class AppRadii {
  static const double field = Radii.md;
  static const double button = Radii.md;
  static const double track = Radii.md;
  static const double thumb = Radii.sm;
}

/// Type helpers on top of the theme's TextTheme.
abstract final class AppText {
  static const String family = 'Figtree';

  /// Tabular (fixed-width) digits for numbers that change or line up:
  /// counts, vitals, dates in lists.
  static TextStyle tabular(TextStyle? s) =>
      (s ?? const TextStyle()).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  // Legacy (see [AppColors]).
  static const label = TextStyle(fontFamily: family, fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.label);
  static const button = TextStyle(fontFamily: family, fontWeight: FontWeight.w600, fontSize: 16);
}

/// Page transition: a short fade with a small horizontal glide. Under
/// reduced motion the new page is drawn in its final place on the first
/// frame, and the duration is zero when [AppTheme] was built with
/// `reduceMotion`.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder({this.reduceMotion = false});

  final bool reduceMotion;

  @override
  Duration get transitionDuration => reduceMotion ? Duration.zero : Motion.page;

  @override
  Duration get reverseTransitionDuration => reduceMotion ? Duration.zero : Motion.pageReverse;

  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    if (reduceMotion || Motion.reduced(context)) return child;
    final enter = CurvedAnimation(parent: animation, curve: Motion.enter, reverseCurve: Motion.exit);
    final under = CurvedAnimation(parent: secondaryAnimation, curve: Motion.move);
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.7, curve: Curves.easeOut)),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.06, 0), end: Offset.zero).animate(enter),
        child: SlideTransition(
          position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.03, 0)).animate(under),
          child: child,
        ),
      ),
    );
  }
}

abstract final class AppTheme {
  /// Kept for older call sites; same as `light().colorScheme`.
  static ColorScheme get colorScheme => _scheme(DsColors.light);

  static ThemeData light({bool reduceMotion = false}) => _build(DsColors.light, reduceMotion: reduceMotion);

  static ThemeData dark({bool reduceMotion = false}) => _build(DsColors.dark, reduceMotion: reduceMotion);

  static ColorScheme _scheme(DsColors c) => ColorScheme(
        brightness: c.brightness,
        primary: c.primary,
        onPrimary: c.onPrimary,
        primaryContainer: c.primaryTint,
        onPrimaryContainer: c.onPrimaryTint,
        secondary: c.info,
        onSecondary: c.surface,
        secondaryContainer: c.infoTint,
        onSecondaryContainer: c.info,
        tertiary: c.accent,
        onTertiary: c.surface,
        tertiaryContainer: c.accentTint,
        onTertiaryContainer: c.accent,
        error: c.danger,
        onError: c.onDanger,
        errorContainer: c.dangerTint,
        onErrorContainer: c.danger,
        surface: c.surface,
        onSurface: c.ink,
        onSurfaceVariant: c.inkSecondary,
        surfaceDim: c.sunken,
        surfaceBright: c.surface,
        surfaceContainerLowest: c.surface,
        surfaceContainerLow: c.surface,
        surfaceContainer: c.surface,
        surfaceContainerHigh: c.surface,
        surfaceContainerHighest: c.sunken,
        outline: c.lineStrong,
        outlineVariant: c.line,
        shadow: c.shadow,
        scrim: c.scrim,
        inverseSurface: c.inverse,
        onInverseSurface: c.onInverse,
        inversePrimary: c.inversePrimary,
        surfaceTint: c.surface.withValues(alpha: 0),
      );

  /// Figtree type scale. Sizes stay at or above 12 so nothing drops below
  /// the readable floor at 1.0x.
  static TextTheme _type(DsColors c) {
    TextStyle s(double size, double height, FontWeight w, {double ls = 0, Color? color}) => TextStyle(
          fontFamily: AppText.family,
          fontSize: size,
          height: height / size,
          fontWeight: w,
          letterSpacing: ls,
          color: color ?? c.ink,
          leadingDistribution: TextLeadingDistribution.even,
        );
    return TextTheme(
      displayLarge: s(44, 52, FontWeight.w600, ls: -1.0),
      displayMedium: s(36, 44, FontWeight.w600, ls: -0.8),
      displaySmall: s(30, 38, FontWeight.w600, ls: -0.6),
      headlineLarge: s(28, 36, FontWeight.w600, ls: -0.5),
      headlineMedium: s(25, 32, FontWeight.w600, ls: -0.4),
      headlineSmall: s(22, 28, FontWeight.w600, ls: -0.25),
      titleLarge: s(19, 26, FontWeight.w600, ls: -0.1),
      titleMedium: s(16, 22, FontWeight.w600),
      titleSmall: s(14, 20, FontWeight.w600),
      bodyLarge: s(16, 24, FontWeight.w400),
      bodyMedium: s(14.5, 21, FontWeight.w400, color: c.inkSecondary),
      bodySmall: s(13, 18, FontWeight.w400, color: c.inkMuted),
      labelLarge: s(15, 20, FontWeight.w600, ls: 0.1),
      labelMedium: s(13, 18, FontWeight.w600, ls: 0.1),
      labelSmall: s(12, 16, FontWeight.w600, ls: 0.4, color: c.inkMuted),
    );
  }

  static ThemeData _build(DsColors c, {required bool reduceMotion}) {
    final scheme = _scheme(c);
    final type = _type(c);
    const controlShape = RoundedRectangleBorder(borderRadius: Radii.control);
    final transitions = AppPageTransitionsBuilder(reduceMotion: reduceMotion);
    final clear = c.surface.withValues(alpha: 0);

    WidgetStateProperty<Color?> overlay(Color base) => WidgetStateProperty.resolveWith((s) {
          if (s.contains(WidgetState.pressed)) return base.withValues(alpha: 0.12);
          if (s.contains(WidgetState.focused)) return base.withValues(alpha: 0.12);
          if (s.contains(WidgetState.hovered)) return base.withValues(alpha: 0.06);
          return null;
        });

    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(borderRadius: Radii.field, borderSide: BorderSide(color: color, width: width));

    final filledStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(64, 52)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.xxl)),
      shape: const WidgetStatePropertyAll(controlShape),
      elevation: const WidgetStatePropertyAll(0),
      textStyle: WidgetStatePropertyAll(type.labelLarge),
      backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.sunken : c.primary),
      foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.inkMuted : c.onPrimary),
      overlayColor: overlay(c.onPrimary),
      iconSize: const WidgetStatePropertyAll(20),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      colorScheme: scheme,
      fontFamily: AppText.family,
      textTheme: type,
      primaryTextTheme: type,
      scaffoldBackgroundColor: c.canvas,
      canvasColor: c.surface,
      dividerColor: c.line,
      splashFactory: InkRipple.splashFactory,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      extensions: [c],
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values) p: transitions,
      }),
      iconTheme: IconThemeData(color: c.inkSecondary, size: 22),
      appBarTheme: AppBarTheme(
        backgroundColor: c.canvas,
        foregroundColor: c.ink,
        surfaceTintColor: clear,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: Space.lg,
        titleTextStyle: type.titleLarge,
        iconTheme: IconThemeData(color: c.ink, size: 24),
        actionsIconTheme: IconThemeData(color: c.inkSecondary, size: 24),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filledStyle),
      filledButtonTheme: FilledButtonThemeData(style: filledStyle),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.xl)),
          shape: const WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(type.labelLarge),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.inkMuted : c.ink),
          side: WidgetStateProperty.resolveWith((s) => BorderSide(color: s.contains(WidgetState.disabled) ? c.line : c.lineStrong)),
          backgroundColor: WidgetStatePropertyAll(c.surface),
          overlayColor: overlay(c.ink),
          iconSize: const WidgetStatePropertyAll(20),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: Space.md)),
          shape: const WidgetStatePropertyAll(controlShape),
          textStyle: WidgetStatePropertyAll(type.labelLarge),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.inkMuted : c.primary),
          overlayColor: overlay(c.primary),
          iconSize: const WidgetStatePropertyAll(20),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled) ? c.inkMuted : c.inkSecondary),
          overlayColor: overlay(c.ink),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        elevation: 3,
        focusElevation: 4,
        hoverElevation: 4,
        highlightElevation: 6,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.lg))),
        extendedTextStyle: type.labelLarge,
        extendedPadding: const EdgeInsetsDirectional.only(start: Space.xl, end: Space.xxl),
        extendedIconLabelSpacing: Space.sm,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.lg),
        hintStyle: type.bodyLarge?.copyWith(color: c.inkMuted),
        labelStyle: type.bodyLarge?.copyWith(color: c.inkSecondary),
        floatingLabelStyle: type.labelLarge?.copyWith(color: c.primary),
        helperStyle: type.bodySmall,
        errorStyle: type.bodySmall?.copyWith(color: c.danger, fontWeight: FontWeight.w600),
        errorMaxLines: 3,
        prefixIconColor: WidgetStateColor.resolveWith((s) => s.contains(WidgetState.focused) ? c.primary : c.inkMuted),
        suffixIconColor: WidgetStateColor.resolveWith((s) => s.contains(WidgetState.focused) ? c.primary : c.inkMuted),
        border: border(c.lineStrong),
        enabledBorder: border(c.lineStrong),
        focusedBorder: border(c.primary, 2),
        errorBorder: border(c.danger, 1.5),
        focusedErrorBorder: border(c.danger, 2),
        disabledBorder: border(c.line),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.primary,
        selectionColor: c.primary.withValues(alpha: 0.25),
        selectionHandleColor: c.primary,
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        surfaceTintColor: clear,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: Radii.card, side: BorderSide(color: c.line)),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
        minVerticalPadding: Space.md,
        horizontalTitleGap: Space.md,
        minLeadingWidth: 24,
        iconColor: c.inkSecondary,
        textColor: c.ink,
        titleTextStyle: type.titleMedium,
        subtitleTextStyle: type.bodyMedium,
        leadingAndTrailingTextStyle: type.bodySmall,
        selectedColor: c.onPrimaryTint,
        selectedTileColor: c.primaryTint,
        shape: const RoundedRectangleBorder(borderRadius: Radii.control),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.sunken,
        selectedColor: c.primaryTint,
        disabledColor: c.sunken,
        side: BorderSide.none,
        shape: const RoundedRectangleBorder(borderRadius: Radii.chip),
        labelStyle: type.labelMedium?.copyWith(color: c.ink),
        secondaryLabelStyle: type.labelMedium?.copyWith(color: c.onPrimaryTint),
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
        iconTheme: IconThemeData(color: c.inkSecondary, size: 18),
        checkmarkColor: c.onPrimaryTint,
        elevation: 0,
        pressElevation: 0,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: clear,
        scrimColor: c.scrim.withValues(alpha: 0.45),
        width: 304,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(Radii.xl))),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        modalBackgroundColor: c.surface,
        surfaceTintColor: clear,
        elevation: 0,
        modalElevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheet),
        showDragHandle: true,
        dragHandleColor: c.lineStrong,
        dragHandleSize: const Size(36, 4),
        modalBarrierColor: c.scrim.withValues(alpha: 0.45),
        clipBehavior: Clip.antiAlias,
        constraints: const BoxConstraints(maxWidth: Layout.formMax),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: clear,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.xl))),
        titleTextStyle: type.titleLarge,
        contentTextStyle: type.bodyMedium,
        barrierColor: c.scrim.withValues(alpha: 0.45),
        actionsPadding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.inverse,
        contentTextStyle: type.bodyMedium?.copyWith(color: c.onInverse),
        actionTextColor: c.inversePrimary,
        closeIconColor: c.onInverse,
        elevation: 0,
        insetPadding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
        shape: const RoundedRectangleBorder(borderRadius: Radii.control),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: c.inverse, borderRadius: const BorderRadius.all(Radius.circular(Radii.xs))),
        textStyle: type.labelMedium?.copyWith(color: c.onInverse),
        waitDuration: const Duration(milliseconds: 500),
        padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs + 2),
      ),
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.primary,
        linearTrackColor: c.sunken,
        circularTrackColor: clear,
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : clear),
        checkColor: WidgetStatePropertyAll(c.onPrimary),
        side: WidgetStateBorderSide.resolveWith((s) => s.contains(WidgetState.selected)
            ? BorderSide(color: c.primary, width: 2)
            : BorderSide(color: c.lineStrong, width: 1.5)),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(5))),
      ),
      radioTheme: RadioThemeData(fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : c.lineStrong)),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onPrimary : c.lineStrong),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : c.sunken),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : c.lineStrong),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: clear,
        elevation: 0,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(Radii.xl))),
        headerBackgroundColor: c.primaryTint,
        headerForegroundColor: c.onPrimaryTint,
        headerHeadlineStyle: type.headlineSmall,
        headerHelpStyle: type.labelMedium,
        dayStyle: AppText.tabular(type.bodyMedium),
        yearStyle: AppText.tabular(type.bodyLarge),
        weekdayStyle: type.labelMedium?.copyWith(color: c.inkMuted),
        todayBorder: BorderSide(color: c.primary, width: 1.5),
        todayForegroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onPrimary : c.primary),
        dayForegroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? c.inkMuted.withValues(alpha: 0.5)
            : s.contains(WidgetState.selected)
                ? c.onPrimary
                : c.ink),
        dayBackgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.primary : null),
        confirmButtonStyle: ButtonStyle(foregroundColor: WidgetStatePropertyAll(c.primary), textStyle: WidgetStatePropertyAll(type.labelLarge)),
        cancelButtonStyle: ButtonStyle(foregroundColor: WidgetStatePropertyAll(c.inkSecondary), textStyle: WidgetStatePropertyAll(type.labelLarge)),
        dividerColor: c.line,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.surface,
        surfaceTintColor: clear,
        elevation: 6,
        shadowColor: c.shadow.withValues(alpha: 0.2),
        shape: RoundedRectangleBorder(borderRadius: Radii.control, side: BorderSide(color: c.line)),
        textStyle: type.bodyLarge,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(c.lineStrong.withValues(alpha: 0.6)),
        radius: const Radius.circular(Radii.pill),
        thickness: const WidgetStatePropertyAll(4),
      ),
    );
  }
}
