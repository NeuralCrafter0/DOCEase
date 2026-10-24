// Shared building blocks for the redesigned screens. Everything here is
// styled from the theme and tokens only.
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Colour role for badges, banners and medallions.
enum Tone { neutral, primary, info, accent, warn, danger }

extension ToneColors on Tone {
  /// Background and foreground for this tone in [c]. Every pair meets 4.5:1.
  ({Color bg, Color fg}) colors(DsColors c) => switch (this) {
        Tone.neutral => (bg: c.sunken, fg: c.inkSecondary),
        Tone.primary => (bg: c.primaryTint, fg: c.onPrimaryTint),
        Tone.info => (bg: c.infoTint, fg: c.info),
        Tone.accent => (bg: c.accentTint, fg: c.accent),
        Tone.warn => (bg: c.warnTint, fg: c.warn),
        Tone.danger => (bg: c.dangerTint, fg: c.danger),
      };
}

/// A card surface with a hairline outline. Tappable when [onTap] is set
/// (then it reads as one button to screen readers, with [semanticLabel]
/// if the visible text is not a good label).
class DsCard extends StatelessWidget {
  const DsCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.lg),
    this.onTap,
    this.onLongPress,
    this.color,
    this.borderColor,
    this.radius = Radii.card,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? color;
  final Color? borderColor;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final content = Padding(padding: padding, child: child);
    return Material(
      color: color ?? c.surface,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: borderColor ?? c.line)),
      clipBehavior: Clip.antiAlias,
      child: onTap == null && onLongPress == null
          ? content
          : InkWell(onTap: onTap, onLongPress: onLongPress, child: content),
    );
  }
}

/// A small rounded square with an icon on a tone tint.
class IconMedallion extends StatelessWidget {
  const IconMedallion({super.key, required this.icon, this.tone = Tone.primary, this.size = 40, this.iconSize});

  final IconData icon;
  final Tone tone;
  final double size;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final t = tone.colors(context.ds);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: t.bg, borderRadius: BorderRadius.circular(size * 0.32)),
        alignment: Alignment.center,
        child: Icon(icon, size: iconSize ?? size * 0.5, color: t.fg),
      ),
    );
  }
}

/// Section title with an optional count and trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.count, this.trailing, this.padding = EdgeInsets.zero});

  final String title;
  final String? count;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(
          child: Row(children: [
            Flexible(
              child: Semantics(
                header: true,
                child: Text(title, style: context.type.titleMedium),
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: Space.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xxs),
                decoration: BoxDecoration(color: c.sunken, borderRadius: const BorderRadius.all(Radius.circular(Radii.pill))),
                child: Text(count!, style: AppText.tabular(context.type.labelMedium?.copyWith(color: c.inkSecondary))),
              ),
            ],
          ]),
        ),
        ?trailing,
      ]),
    );
  }
}

/// Initials on a stable colour picked from the record id. Decorative: the
/// name is always shown next to it, so it is hidden from screen readers.
class Monogram extends StatelessWidget {
  const Monogram({super.key, required this.id, required this.name, this.size = 44});

  final String id;
  final String name;
  final double size;

  static String initialsOf(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
    if (parts.length == 1) return first(parts.first);
    return first(parts.first) + first(parts.last);
  }

  @override
  Widget build(BuildContext context) {
    final tone = context.ds.toneFor(id);
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
        decoration: BoxDecoration(color: tone.bg, shape: BoxShape.circle),
        child: Center(child: MediaQuery.withNoTextScaling(
          child: Text(
            initialsOf(name),
            style: context.type.titleMedium?.copyWith(color: tone.fg, fontSize: size * 0.38, height: 1, letterSpacing: 0.2),
          ),
        )),
        ),
      ),
    );
  }
}

/// Small rounded label (visit type, vitals, relation).
class Tag extends StatelessWidget {
  const Tag({super.key, required this.label, this.tone = Tone.neutral, this.icon, this.tabular = false});

  final String label;
  final Tone tone;
  final IconData? icon;
  final bool tabular;

  @override
  Widget build(BuildContext context) {
    final t = tone.colors(context.ds);
    final style = context.type.labelMedium?.copyWith(color: t.fg);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
      decoration: BoxDecoration(color: t.bg, borderRadius: Radii.chip),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[ExcludeSemantics(child: Icon(icon, size: 14, color: t.fg)), const SizedBox(width: Space.xs)],
        Flexible(child: Text(label, style: tabular ? AppText.tabular(style) : style, overflow: TextOverflow.ellipsis, maxLines: 1)),
      ]),
    );
  }
}

/// Centred empty, error or info state: medallion, title, message, actions.
class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.tone = Tone.primary,
    this.actions = const [],
    this.liveRegion = false,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Tone tone;
  final List<Widget> actions;
  final bool liveRegion;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Space.xxl, vertical: compact ? Space.xxl : Space.huge),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconMedallion(icon: icon, tone: tone, size: compact ? 56 : 72),
            SizedBox(height: compact ? Space.lg : Space.xl),
            Semantics(
              liveRegion: liveRegion,
              header: true,
              child: Text(title, textAlign: TextAlign.center, style: context.type.titleLarge),
            ),
            if (message != null) ...[
              const SizedBox(height: Space.sm),
              Text(message!, textAlign: TextAlign.center, style: context.type.bodyMedium),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: Space.xxl),
              Wrap(alignment: WrapAlignment.center, spacing: Space.md, runSpacing: Space.md, children: actions),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Inline notice for paused editing, stale data or damaged records.
class NoticeBanner extends StatelessWidget {
  const NoticeBanner({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.tone = Tone.warn,
    this.action,
    this.liveRegion = false,
  });

  final IconData icon;
  final String? title;
  final String message;
  final Tone tone;
  final Widget? action;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final t = tone.colors(context.ds);
    final body = context.type.bodyMedium?.copyWith(color: context.ds.ink);
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(Space.lg, Space.md, Space.sm, Space.md),
      decoration: BoxDecoration(color: t.bg, borderRadius: Radii.control),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        ExcludeSemantics(child: Icon(icon, color: t.fg, size: 22)),
        const SizedBox(width: Space.md),
        Expanded(
          child: Semantics(
            liveRegion: liveRegion,
            child: Text.rich(
              TextSpan(children: [
                if (title != null) TextSpan(text: '$title ', style: body?.copyWith(fontWeight: FontWeight.w600)),
                TextSpan(text: message),
              ]),
              style: body,
            ),
          ),
        ),
        if (action != null) ...[const SizedBox(width: Space.xs), action!] else const SizedBox(width: Space.sm),
      ]),
    );
  }
}

/// The one snack bar style for the app (QA inventory row 23). Messages are
/// generic: never patient names, diagnoses or raw errors (S7).
abstract final class AppSnack {
  static void show(BuildContext context, String message, {Tone tone = Tone.neutral, bool replace = true}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final c = context.ds;
    final icon = switch (tone) {
      Tone.danger || Tone.warn => Icons.error_outline_rounded,
      Tone.primary => Icons.check_circle_outline_rounded,
      _ => Icons.info_outline_rounded,
    };
    // The bar is an inverse surface, so the icon uses the other theme's tint.
    final problem = tone == Tone.danger || tone == Tone.warn;
    final iconColor = problem ? (c.isDark ? DsColors.light.danger : DsColors.dark.danger) : c.inversePrimary;
    if (replace) messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
      content: Row(children: [
        ExcludeSemantics(child: Icon(icon, size: 20, color: iconColor)),
        const SizedBox(width: Space.md),
        Expanded(child: Text(message)),
      ]),
    ));
  }
}

/// Centres [child] and caps its width so lines stay readable on tablets.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = Layout.contentMax});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    );
  }
}

/// A titled group of form fields on a card.
class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.children, this.icon, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DsCard(
      padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, Space.xl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (icon != null) ...[IconMedallion(icon: icon!, size: 32), const SizedBox(width: Space.md)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(header: true, child: Text(title, style: context.type.titleMedium)),
              if (subtitle != null) Text(subtitle!, style: context.type.bodySmall),
            ]),
          ),
          ?trailing,
        ]),
        const SizedBox(height: Space.lg),
        ...children,
      ]),
    );
  }
}

/// Bottom bar holding a form's primary action. Sits above the keyboard and
/// the system gesture area, with a hairline on top.
class BottomActionBar extends StatelessWidget {
  const BottomActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return DecoratedBox(
      decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.line))),
      child: SafeArea(
        top: false,
        child: ContentWidth(
          maxWidth: Layout.formMax + Space.xxxl * 2,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.gutter, Space.md),
            child: child,
          ),
        ),
      ),
    );
  }
}
