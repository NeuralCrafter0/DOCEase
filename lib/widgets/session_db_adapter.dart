import 'package:flutter/material.dart';

import '../providers/local_database.dart';
import '../screens/db_reset_screen.dart';
import '../services/session_controller.dart';
import 'db_open_state_view.dart';

/// Adapts [SessionController] to the frontend's database views without
/// changing the controller: its database phases become a [DbOpenState]
/// for [DbOpenStateView], and its reset goes through [DbResetScreen].
abstract final class SessionDbAdapter {
  /// The [DbOpenState] to show for [session], or null when the phase is not
  /// about the local database (approval, legacy question, signed out,
  /// ready), which [SessionStatusView] keeps handling itself.
  static DbOpenState? stateOf(SessionController session) {
    final uid = session.uid ?? '';
    switch (session.phase) {
      case SessionPhase.opening:
        return DbOpening(uid);
      case SessionPhase.migrating:
        final step = session.migrationStep;
        // No step reported yet: a plain loading view, not a guessed step.
        return step == null ? DbOpening(uid) : DbMigrating(uid, step, session.migrationProgress);
      case SessionPhase.failed:
        // The controller always sets a failure here; if it ever does not,
        // fall back to the retry-only "nothing was deleted" view.
        return DbFailed(uid, session.failure ?? DbOpenError.migrationFailed);
      case SessionPhase.starting:
      case SessionPhase.signedOut:
      case SessionPhase.checkingApproval:
      case SessionPhase.pendingApproval:
      case SessionPhase.legacyDecision:
      case SessionPhase.ready:
        return null;
    }
  }

  /// [DbOpenStateView] for [state], wired to [session]: Try again is
  /// [SessionController.retry]; reset is offered only while
  /// [SessionController.canReset] (key mismatch) and opens [DbResetScreen];
  /// failures keep the controller's Sign out.
  static Widget view(BuildContext context, SessionController session, DbOpenState state) {
    return DbOpenStateView(
      state: state,
      onRetry: session.retry,
      onReset: session.canReset ? () => openReset(context, session) : null,
      onSignOut: state is DbFailed ? session.signOut : null,
    );
  }

  /// Pushes [DbResetScreen]. It reads the unsynced count from the
  /// controller and passes the exact count the doctor confirmed to
  /// [SessionController.resetAndResync]; a worse count comes back as
  /// [ResetNotConfirmedException] and the screen asks again.
  static Future<bool?> openReset(BuildContext context, SessionController session) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DbResetScreen(
          loadUnsynced: session.unsyncedCount,
          reset: (acknowledged) => session.resetAndResync(acknowledgedUnsynced: acknowledged),
        ),
      ),
    );
  }
}
