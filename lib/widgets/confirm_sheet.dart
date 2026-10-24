import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../ui/components.dart';
import '../ui/qa_keys.dart';

/// Bottom sheet asking the doctor to confirm a destructive step.
/// Returns true only when the confirm button was tapped.
class ConfirmSheet extends StatelessWidget {
  const ConfirmSheet({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.icon = Icons.delete_outline_rounded,
    this.cancelLabel = 'Cancel',
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final IconData icon;

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    IconData icon = Icons.delete_outline_rounded,
  }) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ConfirmSheet(title: title, message: message, confirmLabel: confirmLabel, icon: icon),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.xxl, Space.sm, Space.xxl, Space.xxl),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        IconMedallion(icon: icon, tone: Tone.danger, size: 56),
        const SizedBox(height: Space.lg),
        Semantics(header: true, child: Text(title, textAlign: TextAlign.center, style: context.type.titleLarge)),
        const SizedBox(height: Space.sm),
        Text(message, textAlign: TextAlign.center, style: context.type.bodyMedium),
        const SizedBox(height: Space.xxl),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: Space.md,
          runSpacing: Space.md,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: OutlinedButton(
                key: QaKeys.confirmCancel,
                onPressed: () => Navigator.pop(context, false),
                child: Text(cancelLabel),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 140),
              child: FilledButton(
                key: QaKeys.confirmOk,
                style: ButtonStyle(
                  minimumSize: const WidgetStatePropertyAll(Size(64, 48)),
                  backgroundColor: WidgetStatePropertyAll(c.danger),
                  foregroundColor: WidgetStatePropertyAll(c.onDanger),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmLabel),
              ),
            ),
          ],
        ),
      ]),
    );
  }
}
