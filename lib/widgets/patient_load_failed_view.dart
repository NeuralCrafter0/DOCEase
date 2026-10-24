import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Shown instead of the patient list when the first load failed. It never
/// says "no patients": an empty-looking list after a failed read invites the
/// doctor to register someone who already exists.
class PatientLoadFailedView extends StatelessWidget {
  const PatientLoadFailedView({super.key, required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline_rounded, size: 40, color: Colors.redAccent),
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            header: true,
            child: const Text("Couldn't load records", textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.ink)),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your patient records could not be read. Nothing was changed. Try again before registering anyone new.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: AppColors.muted),
          ),
          const SizedBox(height: 20),
          RetryButton(onRetry: onRetry, filled: true),
        ]),
      ),
    );
  }
}

/// Shown above a stale list when a reload failed: the list is the last one
/// that loaded, and it is read-only until a reload succeeds.
class PatientRefreshFailedBanner extends StatelessWidget {
  const PatientRefreshFailedBanner({super.key, required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(AppRadii.field),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(children: [
        const Icon(Icons.sync_problem_rounded, color: Colors.redAccent, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            liveRegion: true,
            child: const Text.rich(
              TextSpan(children: [
                TextSpan(text: "Couldn't refresh. ", style: TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: 'Showing the last loaded records. Editing is paused.'),
              ]),
              style: TextStyle(fontSize: 13, color: AppColors.ink),
            ),
          ),
        ),
        RetryButton(onRetry: onRetry),
      ]),
    );
  }
}

/// Retry that can't be double-tapped: disabled with a spinner while running.
/// A failed retry leaves the provider's loadFailed set, so the caller's view
/// stays up; the error itself is not shown again here.
class RetryButton extends StatefulWidget {
  const RetryButton({super.key, required this.onRetry, this.filled = false});

  final Future<void> Function() onRetry;
  final bool filled;

  @override
  State<RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<RetryButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } catch (_) {
      // loadFailed stays true and the failure view or banner stays visible.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final icon = _busy
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.refresh_rounded, size: 18);
    const label = Text('Retry', style: TextStyle(fontWeight: FontWeight.bold));
    final onPressed = _busy ? null : _run;
    return widget.filled
        ? FilledButton.icon(onPressed: onPressed, icon: icon, label: label, style: FilledButton.styleFrom(backgroundColor: AppColors.ink))
        : TextButton.icon(onPressed: onPressed, icon: icon, label: label);
  }
}
