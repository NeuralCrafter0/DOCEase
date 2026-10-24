import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A row of mutually exclusive options with a sliding highlight.
///
/// Each option is a button with selected state for screen readers. The row
/// grows with large text (labels wrap to two lines), so nothing clips at
/// 2.0x. A [selected] value that is not in [options] (for example a stored
/// visit type the form doesn't offer) leaves every option unselected.
class SegmentedSelector extends StatelessWidget {
  const SegmentedSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
    this.keyFor,
    this.fontSize,
    this.indicatorShadowOffset,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;
  final bool enabled;

  /// Optional per-option key (QA locators), e.g. `QaKeys.patientFormGender`.
  final Key Function(String option)? keyFor;

  /// Unused; kept so older call sites compile until M2.
  final double? fontSize;
  final Offset? indicatorShadowOffset;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final index = options.indexOf(selected);
    final n = options.length;
    final duration = Motion.of(context, Motion.standard);
    final labelStyle = context.type.labelLarge;

    return AbsorbPointer(
      absorbing: !enabled,
      child: Container(
        padding: const EdgeInsets.all(Space.xs),
        decoration: BoxDecoration(color: c.sunken, borderRadius: Radii.control),
        child: Stack(children: [
          if (index >= 0)
            Positioned.fill(
              child: AnimatedAlign(
                duration: duration,
                curve: Motion.move,
                alignment: Alignment(n == 1 ? 0 : -1 + 2 * index / (n - 1), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: enabled ? c.surface : c.canvas,
                      borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
                      boxShadow: enabled ? Shadows.raised(c) : null,
                    ),
                  ),
                ),
              ),
            ),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final opt in options)
                  Expanded(
                    child: Semantics(
                      key: keyFor?.call(opt),
                      button: true,
                      selected: opt == selected,
                      enabled: enabled,
                      inMutuallyExclusiveGroup: true,
                      child: InkWell(
                        onTap: enabled ? () => onSelected(opt) : null,
                        borderRadius: const BorderRadius.all(Radius.circular(Radii.sm)),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Space.xs, vertical: Space.sm),
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: duration,
                                style: labelStyle!.copyWith(
                                  color: !enabled
                                      ? c.inkMuted
                                      : opt == selected
                                          ? c.ink
                                          : c.inkSecondary,
                                  fontWeight: opt == selected ? FontWeight.w700 : FontWeight.w500,
                                ),
                                child: Text(opt, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
