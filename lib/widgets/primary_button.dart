import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The screen's main action: full width, filled brand colour. While [busy]
/// it shows a spinner and ignores taps (double-tap guard stays with the
/// caller).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false, this.busyLabel});

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  /// Spoken while busy, e.g. "Saving". Defaults to [label].
  final String? busyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    final Widget content = busy
        ? Semantics(
            label: busyLabel ?? label,
            child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.inkMuted)),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: Space.sm)],
            Flexible(child: Text(label, textAlign: TextAlign.center)),
          ]);
    return ElevatedButton(
      onPressed: busy ? null : onPressed,
      style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(double.infinity, 54))),
      child: content,
    );
  }
}
