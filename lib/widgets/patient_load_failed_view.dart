import 'package:flutter/material.dart';

import '../ui/components.dart';

/// Shown instead of the patient list when the first read failed. Never the
/// empty state: the records exist but couldn't be read (S6).
class PatientLoadFailedView extends StatelessWidget {
  const PatientLoadFailedView({super.key, required this.onRetry, this.retryKey});

  final Future<void> Function() onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    return StatusView(
      icon: Icons.cloud_off_rounded,
      tone: Tone.danger,
      liveRegion: true,
      title: "Couldn't load records",
      message: 'Your patient records could not be read. Nothing was changed. Try again before registering anyone new.',
      actions: [RetryButton(key: retryKey, onRetry: onRetry, filled: true)],
    );
  }
}

/// Above a list kept from an earlier load when a reload failed.
class PatientRefreshFailedBanner extends StatelessWidget {
  const PatientRefreshFailedBanner({super.key, required this.onRetry, this.retryKey});

  final Future<void> Function() onRetry;
  final Key? retryKey;

  @override
  Widget build(BuildContext context) {
    return NoticeBanner(
      icon: Icons.sync_problem_rounded,
      tone: Tone.danger,
      liveRegion: true,
      title: "Couldn't refresh.",
      message: 'Showing the last loaded records. Editing is paused.',
      action: RetryButton(key: retryKey, onRetry: onRetry),
    );
  }
}

/// Retry that ignores taps while a retry is running.
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
        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.refresh_rounded, size: 20);
    const label = Text('Retry');
    final onPressed = _busy ? null : _run;
    return widget.filled
        ? FilledButton.icon(onPressed: onPressed, icon: icon, label: label)
        : TextButton.icon(onPressed: onPressed, icon: icon, label: label);
  }
}
