import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../ui/components.dart';

/// One headline number with its caption ("Patients today: 4").
///
/// Screen readers get a single item, "[label]: [value]" (QA a11y suite), so
/// the visible caption can differ from [label] through [caption].
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, required this.icon, this.tone = Tone.primary, this.caption});

  /// Spoken label, and the caption unless [caption] is set.
  final String label;
  final String value;
  final IconData icon;
  final Tone tone;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: DsCard(
        padding: const EdgeInsets.all(Space.lg),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          IconMedallion(icon: icon, tone: tone, size: 40),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(value, maxLines: 1, style: AppText.tabular(context.type.headlineSmall?.copyWith(color: c.ink))),
              Text(caption ?? label, style: context.type.labelMedium?.copyWith(color: c.inkSecondary)),
            ]),
          ),
        ]),
      ),
    );
  }
}
