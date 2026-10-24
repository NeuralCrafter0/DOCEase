import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../ui/components.dart';

/// One headline number with its caption ("Patients today: 4").
///
/// Screen readers get a single item, "[label]: [value]" (QA a11y suite), so
/// the visible caption can differ from [label] through [caption].
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, required this.icon, this.tone = Tone.primary, this.caption, this.color});

  /// Spoken label, and the caption unless [caption] is set.
  final String label;
  final String value;
  final IconData icon;
  final Tone tone;
  final String? caption;

  /// Kept so #17 callers still compile. Ignored: [tone] sets the colours,
  /// so they follow the theme and dark mode.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: DsCard(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.md + 2, Space.md, Space.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: Space.xxs),
                child: Text(value, maxLines: 1, style: AppText.tabular(context.type.headlineLarge?.copyWith(color: c.ink, height: 1.1))),
              ),
            ),
            IconMedallion(icon: icon, tone: tone, size: 36),
          ]),
          const SizedBox(height: Space.xs),
          Text(caption ?? label, style: context.type.labelLarge?.copyWith(color: c.inkSecondary)),
        ]),
      ),
    );
  }
}
