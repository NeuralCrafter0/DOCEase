import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bottom-sheet confirmation for destructive actions, copied from the
/// patient-delete sheet: red icon in a tinted circle, bold title, centred
/// message, Cancel and a red confirm button.
///
/// The patient and visit delete sheets switch over once #6 and #8, which
/// edit their buttons, are merged; the visit sheet then gets this richer look
/// too, so that switch is a deliberate (small) visual change.
class ConfirmSheet extends StatelessWidget {
  const ConfirmSheet({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
    this.icon = Icons.delete_forever_rounded,
    this.cancelLabel = 'Cancel',
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final IconData icon;

  /// Shows the sheet. Completes with true only when the confirm button was
  /// tapped (Cancel, a tap outside or back all give false).
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    IconData icon = Icons.delete_forever_rounded,
  }) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      backgroundColor: Colors.white,
      builder: (_) => ConfirmSheet(title: title, message: message, confirmLabel: confirmLabel, icon: icon),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), shape: BoxShape.circle),
            child: Icon(icon, color: Colors.redAccent, size: 40),
          ),
          const SizedBox(height: 24),
          Semantics(header: true, child: Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.ink))),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.muted)),
          const SizedBox(height: 32),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelLabel, style: const TextStyle(fontWeight: FontWeight.bold, color: AppColors.label)))),
            const SizedBox(width: 16),
            Expanded(
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                child: Text(confirmLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
