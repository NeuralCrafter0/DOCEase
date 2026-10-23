import 'package:flutter/material.dart';

import '../providers/local_database.dart';
import '../services/session_controller.dart';
import '../services/session_platform.dart';

/// What the root shows while the session is not [SessionPhase.ready] (and
/// not signed out): progress, approval, the legacy-data question, or an
/// error with retry / reset. Plain styling; the frontend may restyle it.
class SessionStatusView extends StatelessWidget {
  const SessionStatusView({super.key, required this.session});

  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final body = switch (session.phase) {
      SessionPhase.migrating => _progress(
          _migrationText(session.migrationStep),
          value: session.migrationProgress > 0 ? session.migrationProgress : null),
      SessionPhase.pendingApproval => _approval(context),
      SessionPhase.legacyDecision => _legacy(context),
      SessionPhase.failed => _failed(context),
      SessionPhase.checkingApproval => _progress('Checking your account...'),
      SessionPhase.opening => _progress('Opening your records...'),
      _ => _progress(null),
    };
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

  Widget _progress(String? text, {double? value}) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          value == null ? const CircularProgressIndicator() : LinearProgressIndicator(value: value),
          if (text != null) ...[const SizedBox(height: 16), Text(text, textAlign: TextAlign.center)],
        ],
      );

  static String _migrationText(DbMigrationStep? step) => switch (step) {
        DbMigrationStep.encryptingPlaintext => 'Encrypting your records on this phone...',
        DbMigrationStep.rekeyingFromFallback ||
        DbMigrationStep.rekeyingFromLegacyKey =>
          'Securing your records with a new key...',
        null => 'Updating your records...',
      };

  Widget _message(String title, String text, List<Widget> actions) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          ...actions.expand((w) => [w, const SizedBox(height: 8)]),
        ],
      );

  Widget _signOut() => TextButton(onPressed: session.signOut, child: const Text('Sign out'));

  Widget _approval(BuildContext context) {
    final (title, text) = switch (session.approvalStatus) {
      ApprovalStatus.emailNotVerified => (
          'Verify your email',
          'Open the verification link sent to your email address, then tap Check again.'
        ),
      ApprovalStatus.notApproved => (
          'Waiting for approval',
          'Your account has not been approved for DOCEase yet. Contact your administrator.'
        ),
      _ => (
          'Can\'t check your account',
          'Connect to the internet to confirm your account, then tap Check again.'
        ),
    };
    return _message(title, text, [
      FilledButton(onPressed: session.retry, child: const Text('Check again')),
      _signOut(),
    ]);
  }

  Widget _legacy(BuildContext context) {
    final p = session.legacyPrompt;
    final count = p?.legacyPatientCount;
    final String detail;
    if (count == null) {
      detail = 'Records from an earlier version of DOCEase were found on this phone. '
          'We could not check whether they belong to your account.';
    } else if (p!.cloudCheckFailed) {
      detail = 'Records of $count patients from an earlier version were found on this phone. '
          'We could not reach the cloud to check whether they are yours.';
    } else {
      detail = 'Records of $count patients from an earlier version were found on this phone. '
          '${p.matchingCloudCount} of them are in your account.';
    }
    return _message('Records found on this phone',
        '$detail\n\nAdd them to your account only if they are your patients.', [
      FilledButton(
          onPressed: () => session.resolveLegacyMerge(LegacyMergeChoice.merge),
          child: const Text('Add to my account')),
      OutlinedButton(
          onPressed: () => session.resolveLegacyMerge(LegacyMergeChoice.keepSeparate),
          child: const Text('Keep them separate')),
      _signOut(),
    ]);
  }

  Widget _failed(BuildContext context) {
    final text = switch (session.failure) {
      DbOpenError.keyUnavailable =>
        'The phone\'s secure storage is not available right now. Try again.',
      DbOpenError.keyMismatch =>
        'Your records on this phone can\'t be unlocked with this phone\'s key. You can reset '
            'them and download your records again from the cloud.',
      DbOpenError.storageFull => 'Your phone is out of storage. Free some space and try again.',
      _ => 'Your records could not be opened. Nothing was deleted. Try again.',
    };
    return _message('Can\'t open your records', text, [
      FilledButton(onPressed: session.retry, child: const Text('Try again')),
      if (session.canReset)
        OutlinedButton(onPressed: () => _confirmReset(context), child: const Text('Reset this phone\'s copy')),
      _signOut(),
    ]);
  }

  Future<void> _confirmReset(BuildContext context) async {
    final count = await session.unsyncedCount();
    if (!context.mounted) return;
    final warning = switch (count) {
      UnsyncedKnown(:final count) when count == 0 =>
        'All your changes are saved in the cloud. Nothing will be lost.',
      UnsyncedKnown(:final count) =>
        '$count changes on this phone are not in the cloud yet and will be lost.',
      _ => 'Some changes on this phone may not be in the cloud yet and would be lost.',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset this phone\'s copy?'),
        content: Text(warning),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.resetAndResync(acknowledgedUnsynced: count);
    } on ResetNotConfirmedException {
      if (context.mounted) await _confirmReset(context); // count got worse: ask again
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Reset failed. Nothing was deleted.')));
      }
    }
  }
}
