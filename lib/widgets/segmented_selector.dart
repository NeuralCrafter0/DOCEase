import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Segmented control with one sliding indicator ("Zero Jitter, shared
/// indicator": a single [AnimatedPositioned] moves, so there is no shadow
/// trail between options).
///
/// Extracted from the three `_buildHighPerfSelector` copies. The copies had
/// drifted, so the differences are parameters and each screen keeps its look:
/// [fontSize] (13 on the patient and profile forms, 12 on the clinical note),
/// [indicatorShadowOffset] (only the patient form offsets the shadow) and
/// [enabled] (only the profile form can be locked).
///
/// Each option is exposed to screen readers as a button in a mutually
/// exclusive group, with its selected state.
class SegmentedSelector extends StatelessWidget {
  const SegmentedSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.fontSize = 13,
    this.indicatorShadowOffset = Offset.zero,
    this.enabled = true,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;
  final double fontSize;
  final Offset indicatorShadowOffset;

  /// When false the control ignores taps and greys out its indicator.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = options.indexOf(selected);
    return AbsorbPointer(
      absorbing: !enabled,
      child: Container(
        height: 54,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: AppColors.track, borderRadius: BorderRadius.circular(AppRadii.track)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth / options.length;
            return Stack(
              children: [
                // Moving indicator: one object, so no shadow trail.
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOutCubic,
                  left: selectedIndex * width,
                  top: 0,
                  bottom: 0,
                  width: width,
                  child: Container(
                    decoration: BoxDecoration(
                      color: enabled ? Colors.white : Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(AppRadii.thumb),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 8, offset: indicatorShadowOffset)],
                    ),
                  ),
                ),
                // Labels layer.
                Row(
                  children: options.map((opt) {
                    final isSelected = selected == opt;
                    return Expanded(
                      child: Semantics(
                        button: true,
                        selected: isSelected,
                        enabled: enabled,
                        inMutuallyExclusiveGroup: true,
                        child: GestureDetector(
                          onTap: enabled ? () => onSelected(opt) : null,
                          behavior: HitTestBehavior.opaque,
                          child: Center(
                            child: Text(
                              opt,
                              style: TextStyle(
                                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                                color: isSelected ? AppColors.primary : AppColors.muted,
                                fontSize: fontSize,
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
