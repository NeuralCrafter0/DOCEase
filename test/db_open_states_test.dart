// Widget tests for the database views plugged into the backend's
// SessionStatusView through SessionDbAdapter. The SessionController is the
// real one, driven by the backend's own fakes (test/backend/fakes.dart).
import 'dart:async';

import 'package:docease/providers/local_database.dart';
import 'package:docease/screens/db_reset_screen.dart';
import 'package:docease/services/session_controller.dart';
import 'package:docease/services/session_platform.dart';
import 'package:docease/widgets/db_open_state_view.dart';
import 'package:docease/widgets/session_status_view.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'backend/fakes.dart';

const uid = 'doctorA';
const home = 'HOME (patients)';
const login = 'LOGIN';

/// The backend's SessionDb plus what the reset path needs: a scripted
/// unsynced count, the acknowledged counts, and an optional refusal.
class ResetSessionDb extends SessionDb {
  UnsyncedCount unsynced = const UnsyncedCount.known(0);
  final resetAcks = <UnsyncedCount>[];
  ResetNotConfirmedException? nextResetRefusal;

  @override
  Future<UnsyncedCount> unsyncedCount() async => unsynced;

  @override
  Future<void> resetAndResync({required UnsyncedCount acknowledgedUnsynced, Future<void> Function()? resync}) async {
    resetAcks.add(acknowledgedUnsynced);
    final refusal = nextResetRefusal;
    if (refusal != null) {
      nextResetRefusal = null;
      unsynced = refusal.current;
      throw refusal;
    }
    return super.resetAndResync(acknowledgedUnsynced: acknowledgedUnsynced, resync: resync);
  }
}

late ResetSessionDb db;
late List<String> log;
late FakeSessionPlatform platform;
late StreamController<User?> auth;
late SessionController session;

Finder get retryButton => find.widgetWithText(FilledButton, 'Try again');
Finder get resetButton => find.text("Reset this phone's copy...");
Finder get signOutButton => find.widgetWithText(TextButton, 'Sign out');

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump();
  }
}

/// Same root switch as main.dart on the session branch.
Future<void> pumpSession(WidgetTester t) async {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  session = SessionController(
    authStateChanges: auth.stream,
    db: db,
    patients: SpyPatients(log),
    doctor: SpyDoctor(log),
    medicines: SpyMedicines(log),
    platform: platform,
    observeAppLifecycle: false,
  );
  addTearDown(session.dispose);
  await t.pumpWidget(MaterialApp(
    home: ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: Consumer<SessionController>(
        builder: (ctx, s, _) => switch (s.phase) {
          SessionPhase.ready => const Scaffold(body: Text(home)),
          SessionPhase.signedOut => const Scaffold(body: Text(login)),
          _ => SessionStatusView(session: s),
        },
      ),
    ),
  ));
  auth.add(FakeUser(uid));
  await settle(t);
}

/// Signs in with the next open failing with [error].
Future<void> pumpFailed(WidgetTester t, DbOpenError error) async {
  db.openError = DbOpenException(error, uid: uid);
  await pumpSession(t);
  expect(session.phase, SessionPhase.failed);
}

int opens() => db.events.where((e) => e == 'open:$uid').length;

void main() {
  setUp(() {
    db = ResetSessionDb();
    log = [];
    platform = FakeSessionPlatform(log);
    auth = StreamController<User?>.broadcast();
  });

  group('session phases use the database views', () {
    testWidgets('opening shows the loading view and nothing else', (t) async {
      db.autoReady = false;
      await pumpSession(t);
      expect(session.phase, SessionPhase.opening);
      expect(find.byType(DbOpenStateView), findsOneWidget);
      expect(find.text('Opening your records...'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.text(home), findsNothing);
    });

    for (final (step, title) in [
      (DbMigrationStep.encryptingPlaintext, 'Encrypting your records'),
      (DbMigrationStep.rekeyingFromFallback, 'Securing your records'),
      (DbMigrationStep.rekeyingFromLegacyKey, 'Securing your records'),
    ]) {
      testWidgets('migrating ${step.name} shows the step and its progress, then the app', (t) async {
        db.autoReady = false;
        await pumpSession(t);
        db.emit(DbMigrating(uid, step, 0.42));
        await settle(t);
        expect(session.phase, SessionPhase.migrating);
        expect(find.text(title), findsOneWidget);
        expect(find.text('42%'), findsOneWidget);
        expect(t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, closeTo(0.42, 1e-9));
        expect(find.text(home), findsNothing);

        db.emit(DbMigrating(uid, step, 0.9));
        await settle(t);
        expect(find.text('90%'), findsOneWidget);

        db.emit(const DbReady(uid));
        await settle(t);
        expect(find.text(home), findsOneWidget);
      });
    }

    for (final (error, title) in [
      (DbOpenError.keyUnavailable, "Can't reach secure storage"),
      (DbOpenError.migrationFailed, "Couldn't finish updating your records"),
      (DbOpenError.storageFull, 'Your phone is out of space'),
    ]) {
      testWidgets('${error.name} has its own view: retry and sign out, never a reset', (t) async {
        await pumpFailed(t, error);
        expect(find.text(title), findsOneWidget);
        expect(retryButton, findsOneWidget);
        expect(signOutButton, findsOneWidget);
        expect(resetButton, findsNothing);
        expect(session.canReset, isFalse);
      });
    }

    testWidgets('keyMismatch has its own view and is the only one with a reset', (t) async {
      await pumpFailed(t, DbOpenError.keyMismatch);
      expect(find.text("Can't unlock your records on this phone"), findsOneWidget);
      expect(retryButton, findsOneWidget);
      expect(resetButton, findsOneWidget);
      expect(signOutButton, findsOneWidget);
    });

    testWidgets('Try again goes through SessionController.retry and reopens', (t) async {
      await pumpFailed(t, DbOpenError.keyUnavailable);
      expect(opens(), 1);
      db.openError = null;
      await t.tap(retryButton);
      await settle(t);
      expect(opens(), 2);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('a retry that fails again stays on the failure view', (t) async {
      await pumpFailed(t, DbOpenError.migrationFailed);
      await t.tap(retryButton);
      await settle(t);
      expect(opens(), 2);
      expect(find.text("Couldn't finish updating your records"), findsOneWidget);
      expect(db.resets, 0);
    });

    testWidgets('Sign out uses the controller and deletes nothing', (t) async {
      await pumpFailed(t, DbOpenError.keyMismatch);
      await t.tap(signOutButton);
      await settle(t);
      expect(log, containsAllInOrder(['google.signOut', 'firebase.signOut']));
      expect(db.resets, 0);
      auth.add(null);
      await settle(t);
      expect(find.text(login), findsOneWidget);
    });

    testWidgets('approval phases keep the backend view', (t) async {
      platform.approval = ApprovalStatus.notApproved;
      await pumpSession(t);
      expect(session.phase, SessionPhase.pendingApproval);
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(find.byType(DbOpenStateView), findsNothing);
      expect(opens(), 0);
    });
  });

  group('reset through the session', () {
    Finder confirmButton() => find.widgetWithText(FilledButton, 'Reset and download again');
    bool confirmEnabled(WidgetTester t) => t.widget<FilledButton>(confirmButton()).onPressed != null;

    Future<void> openReset(WidgetTester t) async {
      await pumpFailed(t, DbOpenError.keyMismatch);
      db.openError = null;
      await t.tap(resetButton);
      await t.pumpAndSettle();
      expect(find.byType(DbResetScreen), findsOneWidget);
    }

    Future<void> confirm(WidgetTester t) async {
      await t.tap(find.byType(Checkbox));
      await t.pump();
      await t.tap(confirmButton());
      await settle(t);
      await t.pumpAndSettle();
    }

    testWidgets('opening the reset screen deletes nothing', (t) async {
      await openReset(t);
      expect(db.resetAcks, isEmpty);
      expect(db.resets, 0);
    });

    testWidgets('reads the count from the controller and needs the explicit confirmation', (t) async {
      db.unsynced = const UnsyncedCount.known(3);
      await openReset(t);
      expect(find.text('3 records will be lost'), findsOneWidget);
      expect(confirmEnabled(t), isFalse);
      await t.tap(confirmButton());
      await t.pump();
      expect(db.resetAcks, isEmpty);

      await confirm(t);
      expect(db.resetAcks, [const UnsyncedCount.known(3)]);
      expect(db.resets, 1);
      expect(find.byType(DbResetScreen), findsNothing);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('unknown is passed through as unknown', (t) async {
      db.unsynced = UnsyncedCount.unknown;
      await openReset(t);
      expect(find.text("DOCEase can't tell what would be lost"), findsOneWidget);
      await confirm(t);
      expect(db.resetAcks, [UnsyncedCount.unknown]);
    });

    testWidgets('a worse count comes back through the controller and must be confirmed again', (t) async {
      db.nextResetRefusal = const ResetNotConfirmedException(UnsyncedCount.known(5));
      await openReset(t);
      await confirm(t);
      expect(find.byType(DbResetScreen), findsOneWidget);
      expect(find.text('5 records will be lost'), findsOneWidget);
      expect(confirmEnabled(t), isFalse);
      expect(db.resets, 0, reason: 'nothing deleted');

      await confirm(t);
      expect(db.resetAcks, [const UnsyncedCount.known(0), const UnsyncedCount.known(5)]);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('cancel goes back to the failure view without resetting', (t) async {
      db.unsynced = const UnsyncedCount.known(2);
      await openReset(t);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(db.resetAcks, isEmpty);
      expect(resetButton, findsOneWidget);
    });
  });

  group('DbOpenStateView on its own', () {
    Future<void> pumpView(WidgetTester t, DbOpenState s, {VoidCallback? onSignOut}) async {
      await t.pumpWidget(MaterialApp(home: DbOpenStateView(state: s, onRetry: () {}, onReset: () {}, onSignOut: onSignOut)));
    }

    testWidgets('the raw cause is never shown', (t) async {
      for (final e in DbOpenError.values) {
        await pumpView(t, DbFailed(uid, e, 'MARKER sqlite ATTACH KEY 0123abcd'));
        expect(find.textContaining('MARKER'), findsNothing, reason: e.name);
        expect(find.textContaining('0123abcd'), findsNothing, reason: e.name);
      }
    });

    testWidgets('only keyMismatch shows a reset even when one is wired', (t) async {
      for (final e in DbOpenError.values) {
        await pumpView(t, DbFailed(uid, e));
        expect(resetButton, e == DbOpenError.keyMismatch ? findsOneWidget : findsNothing, reason: e.name);
      }
    });

    testWidgets('sign out appears only when provided', (t) async {
      await pumpView(t, const DbFailed(uid, DbOpenError.keyUnavailable));
      expect(signOutButton, findsNothing);
      await pumpView(t, const DbFailed(uid, DbOpenError.keyUnavailable), onSignOut: () {});
      expect(signOutButton, findsOneWidget);
    });
  });

  group('DbResetScreen copy', () {
    Future<void> pumpReset(WidgetTester t, UnsyncedCount c) async {
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: DbResetScreen(loadUnsynced: () async => c, reset: (_) async {})));
      await t.pumpAndSettle();
    }

    testWidgets('a single record uses the singular', (t) async {
      await pumpReset(t, const UnsyncedCount.known(1));
      expect(find.text('1 record will be lost'), findsOneWidget);
    });

    testWidgets('unknown shows the strongest warning', (t) async {
      await pumpReset(t, UnsyncedCount.unknown);
      expect(find.textContaining('gone for good'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('known 0 still needs confirmation', (t) async {
      await pumpReset(t, const UnsyncedCount.known(0));
      expect(find.text('Nothing unsaved on this phone'), findsOneWidget);
      expect(t.widget<FilledButton>(find.widgetWithText(FilledButton, 'Reset and download again')).onPressed, isNull);
    });
  });
}
