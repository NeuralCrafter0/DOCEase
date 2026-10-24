import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Small white card with an icon, a big value and a caption ("Daily Pulse").
///
/// Screen readers hear it as one item, for example "Today Visits: 3".
/// Insights' `_buildSmallStatCard` is a separate vertical design and moves
/// here after #11 (which edits it) is merged.
class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, required this.icon, required this.color});

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(AppRadii.button), border: Border.all(color: AppColors.border)),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.ink)),
            Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.grey.shade500)),
          ]),
        ]),
      ),
    );
  }
}
