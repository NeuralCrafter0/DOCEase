import 'package:flutter/material.dart';

import '../providers/local_database.dart';

/// What the doctor sees while their local database is not ready: a loading
/// view, a migration with its step and progress, or one view per
/// [DbOpenError].
///
/// Only [DbFailed.canReset] (a key mismatch) shows the reset action. Every
/// other failure offers a retry only. [DbFailed.cause] is never shown.
class DbOpenStateView extends StatelessWidget {
  const DbOpenStateView({
    super.key,
    required this.state,
    required this.onRetry,
    this.onReset,
  });

  final DbOpenState state;

  /// Opens the database again (the API's retry path after any failure).
  final VoidCallback onRetry;

  /// Opens the reset screen. Used only for `DbFailed(keyMismatch)`.
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final Widget body;
    if (s is DbMigrating) {
      body = _MigratingBody(state: s);
    } else if (s is DbFailed) {
      body = _FailedBody(state: s, onRetry: onRetry, onReset: s.canReset ? onReset : null);
    } else {
      // DbClosed, DbOpening, and the frame before a DbReady is acted on.
      body = const _OpeningBody();
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: body),
          ),
        ),
      ),
    );
  }
}

class _OpeningBody extends StatelessWidget {
  const _OpeningBody();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: 'Opening your records',
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 20),
          Text('Opening your records...', textAlign: TextAlign.center, style: TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}

class _MigratingBody extends StatelessWidget {
  const _MigratingBody({required this.state});

  final DbMigrating state;

  static (String, String) copyFor(DbMigrationStep step) {
    switch (step) {
      case DbMigrationStep.encryptingPlaintext:
        return (
          'Encrypting your records',
          'DOCEase is encrypting the patient records stored on this phone. This only happens once.',
        );
      case DbMigrationStep.rekeyingFromFallback:
      case DbMigrationStep.rekeyingFromLegacyKey:
        return (
          'Securing your records',
          'DOCEase is moving the patient records on this phone to your own encryption key. This only happens once.',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final (title, text) = copyFor(state.step);
    final progress = state.progress.isNaN ? 0.0 : state.progress.clamp(0.0, 1.0);
    final percent = (progress * 100).round();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.enhanced_encryption_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Semantics(
          label: '$title, $percent percent',
          liveRegion: true,
          child: ExcludeSemantics(
            child: Column(
              children: [
                LinearProgressIndicator(value: progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
                const SizedBox(height: 8),
                Text('$percent%', style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Text('Keep DOCEase open until this finishes.', textAlign: TextAlign.center),
      ],
    );
  }
}

class _FailureCopy {
  const _FailureCopy(this.icon, this.title, this.text);
  final IconData icon;
  final String title;
  final String text;
}

class _FailedBody extends StatelessWidget {
  const _FailedBody({required this.state, required this.onRetry, this.onReset});

  final DbFailed state;
  final VoidCallback onRetry;
  final VoidCallback? onReset;

  static _FailureCopy copyFor(DbOpenError error) {
    if (error == DbOpenError.keyUnavailable) {
      return const _FailureCopy(
        Icons.lock_clock_outlined,
        "Can't reach secure storage",
        "Your records are safe, but this phone's secure storage didn't respond, so DOCEase "
            "couldn't unlock them. Try again in a moment. If it keeps happening, restart your phone.",
      );
    }
    if (error == DbOpenError.keyMismatch) {
      return const _FailureCopy(
        Icons.key_off_outlined,
        "Can't unlock your records on this phone",
        "The records stored on this phone can't be opened with this phone's key. Try again. "
            "If that doesn't work, you can reset this phone's copy and download your records from the cloud.",
      );
    }
    if (error == DbOpenError.migrationFailed) {
      return const _FailureCopy(
        Icons.sync_problem_outlined,
        "Couldn't finish updating your records",
        'Nothing was deleted. Your records are still on this phone as they were. Try again.',
      );
    }
    if (error == DbOpenError.storageFull) {
      return const _FailureCopy(
        Icons.sd_card_alert_outlined,
        'Your phone is out of space',
        'DOCEase needs some free space to open your records. Nothing was deleted. '
            'Free up space on your phone, then try again.',
      );
    }
    // Any error added later: safe default, retry only.
    return const _FailureCopy(
      Icons.error_outline,
      "Can't open your records",
      'Nothing was deleted. Try again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final copy = copyFor(state.error);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(copy.icon, size: 48, color: scheme.error),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(copy.title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
        ),
        const SizedBox(height: 8),
        Text(copy.text, textAlign: TextAlign.center),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
        if (onReset != null) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onReset,
            style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
            child: const Text("Reset this phone's copy..."),
          ),
        ],
      ],
    );
  }
}
