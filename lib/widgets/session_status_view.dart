import 'package:flutter/material.dart';

import '../services/session_controller.dart';
import '../services/session_platform.dart';
import 'session_db_adapter.dart';

/// What the root shows while the session is not [SessionPhase.ready] (and
/// not signed out): progress, approval, the legacy-data question, or an
/// error with retry / reset. Plain styling; the frontend may restyle it.
///
/// The database phases (opening, migrating, failed) use the frontend's
/// DbOpenStateView through [SessionDbAdapter]: one view per failure, the
/// migration step and progress, and the reset screen with the unsynced
/// count, offered only on a key mismatch.
class SessionStatusView extends StatelessWidget {
  const SessionStatusView({super.key, required this.session});

  final SessionController session;

  @override
  Widget build(BuildContext context) {
    final dbState = SessionDbAdapter.stateOf(session);
    if (dbState != null) return SessionDbAdapter.view(context, session, dbState);
    final body = switch (session.phase) {
      SessionPhase.pendingApproval => _approval(context),
      SessionPhase.legacyDecision => _legacy(context),
      SessionPhase.checkingApproval => _progress('Checking your account...'),
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
}
