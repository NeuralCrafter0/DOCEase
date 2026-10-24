// Widget tests for the local database open states: DbOpenStateView, the
// standalone DbGate host and DbResetScreen. Nothing here touches main.dart
// or a startup flow; DbGate is not wired in on this branch.
import 'dart:async';

import 'package:docease/providers/local_database.dart';
import 'package:docease/screens/db_reset_screen.dart';
import 'package:docease/widgets/db_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const uid = 'doctorA';
const home = 'HOME (patients)';

/// Scriptable LocalDatabase. Members it does not script fall through to
/// noSuchMethod, so new interface members don't break these tests.
class ScriptedDb implements LocalDatabase {
  final _ctrl = StreamController<DbOpenState>.broadcast();
  DbOpenState _state = const DbClosed();
  final openCalls = <String>[];
  int closeCalls = 0;
  final resetAcks = <UnsyncedCount>[];
  UnsyncedCount unsynced = const UnsyncedCount.known(0);

  /// What openFor(uid) ends in.
  DbOpenState Function(String uid) onOpen = (u) => DbReady(u);

  /// If set, the next resetAndResync throws this and deletes nothing.
  ResetNotConfirmedException? nextResetRefusal;

  void emit(DbOpenState s) {
    _state = s;
    _ctrl.add(s);
  }

  // Same shape as DatabaseHelper.states: current state on listen, then
  // every change, nothing lost in between.
  @override
  Stream<DbOpenState> get states {
    StreamSubscription<DbOpenState>? sub;
    late final StreamController<DbOpenState> c;
    c = StreamController<DbOpenState>(
      onListen: () {
        c.add(_state);
        sub = _ctrl.stream.listen(c.add);
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  @override
  DbOpenState get state => _state;

  @override
  Future<void> openFor(String u) async {
    openCalls.add(u);
    emit(DbOpening(u));
    await Future<void>.value();
    final end = onOpen(u);
    emit(end);
    if (end is DbFailed) throw DbOpenException(end.error, uid: u);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    emit(const DbClosed());
  }

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
    emit(DbReady(_state.uid ?? uid));
    await resync?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

late ScriptedDb db;

Future<void> pumpGate(WidgetTester t, {DbOpenState? initial, bool manage = false, String forUid = uid, VoidCallback? onSignOut}) async {
  t.view.physicalSize = const Size(1080, 2400);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  if (initial != null) db.emit(initial);
  await t.pumpWidget(MaterialApp(
    home: DbGate(key: ValueKey(forUid), db: db, uid: forUid, manageLifecycle: manage, onSignOut: onSignOut, child: const Scaffold(body: Text(home))),
  ));
  await t.pump();
  await t.pump();
}

Finder get retryButton => find.widgetWithText(FilledButton, 'Try again');
Finder get resetButton => find.text("Reset this phone's copy...");

void expectRetryOnly() {
  expect(retryButton, findsOneWidget);
  expect(resetButton, findsNothing);
  expect(find.byType(DbResetScreen), findsNothing);
  expect(find.text(home), findsNothing);
}

void main() {
  setUp(() => db = ScriptedDb());

  group('state views', () {
    testWidgets('opening shows a loading view and nothing else', (t) async {
      await pumpGate(t, initial: const DbOpening(uid));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Opening your records...'), findsOneWidget);
      expect(find.byType(FilledButton), findsNothing);
      expect(find.text(home), findsNothing);
    });

    testWidgets('closed (before the open starts) also shows loading', (t) async {
      await pumpGate(t);
      expect(find.text('Opening your records...'), findsOneWidget);
    });

    for (final (step, title) in [
      (DbMigrationStep.encryptingPlaintext, 'Encrypting your records'),
      (DbMigrationStep.rekeyingFromFallback, 'Securing your records'),
      (DbMigrationStep.rekeyingFromLegacyKey, 'Securing your records'),
    ]) {
      testWidgets('migrating ${step.name} shows the step and its progress', (t) async {
        await pumpGate(t, initial: const DbOpening(uid));
        db.emit(DbMigrating(uid, step, 0.42));
        await t.pump();
        expect(find.text(title), findsOneWidget);
        expect(find.text('42%'), findsOneWidget);
        final bar = t.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
        expect(bar.value, closeTo(0.42, 1e-9));
        expect(find.text(home), findsNothing);
        db.emit(DbMigrating(uid, step, 0.9));
        await t.pump();
        expect(find.text('90%'), findsOneWidget);
      });
    }

    testWidgets('ready carries on into the app', (t) async {
      await pumpGate(t, initial: const DbOpening(uid));
      db.emit(const DbReady(uid));
      await t.pump();
      expect(find.text(home), findsOneWidget);
      expect(find.text('Opening your records...'), findsNothing);
    });

    testWidgets('keyUnavailable offers retry only, never a reset', (t) async {
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.keyUnavailable));
      expect(find.text("Can't reach secure storage"), findsOneWidget);
      expectRetryOnly();
      await t.tap(retryButton);
      await t.pump();
      await t.pump();
      expect(db.openCalls, [uid]);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('keyMismatch is the only error that offers the reset screen', (t) async {
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.keyMismatch));
      expect(find.text("Can't unlock your records on this phone"), findsOneWidget);
      expect(retryButton, findsOneWidget);
      expect(resetButton, findsOneWidget);
      await t.tap(resetButton);
      await t.pumpAndSettle();
      expect(find.byType(DbResetScreen), findsOneWidget);
      expect(db.resetAcks, isEmpty, reason: 'opening the reset screen deletes nothing');
    });

    testWidgets('migrationFailed offers a safe retry', (t) async {
      db.onOpen = (u) => DbFailed(u, DbOpenError.migrationFailed);
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.migrationFailed));
      expect(find.text("Couldn't finish updating your records"), findsOneWidget);
      expect(find.textContaining('Nothing was deleted'), findsOneWidget);
      expectRetryOnly();
      await t.tap(retryButton);
      await t.pump();
      await t.pump();
      expect(db.openCalls, [uid]);
      expectRetryOnly();
    });

    testWidgets('storageFull says the phone is out of space', (t) async {
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.storageFull));
      expect(find.text('Your phone is out of space'), findsOneWidget);
      expect(find.textContaining('Free up space'), findsOneWidget);
      expectRetryOnly();
    });

    testWidgets('legacyUnreadable is retry-only and says nothing was changed', (t) async {
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.legacyUnreadable));
      expect(find.text("Can't open records from an earlier version"), findsOneWidget);
      expect(find.textContaining("haven't been changed or deleted"), findsOneWidget);
      expect(find.textContaining("Don't uninstall DOCEase"), findsOneWidget);
      expectRetryOnly();
      await t.tap(retryButton);
      await t.pump();
      await t.pump();
      expect(db.openCalls, [uid]);
    });

    testWidgets('every error has its own message, none falls back to the generic one', (t) async {
      final titles = <String>{};
      for (final e in DbOpenError.values) {
        db = ScriptedDb();
        await t.pumpWidget(const SizedBox());
        await pumpGate(t, initial: DbFailed(uid, e));
        expect(find.text("Can't open your records"), findsNothing, reason: e.name);
        final title = t.widget<Text>(find.descendant(of: find.byWidgetPredicate((w) => w is Semantics && (w.properties.header ?? false)), matching: find.byType(Text))).data!;
        titles.add(title);
      }
      expect(titles, hasLength(DbOpenError.values.length));
    });

    testWidgets('Sign out shows under failures only when the host provides it', (t) async {
      var signedOut = 0;
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.keyUnavailable), onSignOut: () => signedOut++);
      await t.tap(find.widgetWithText(TextButton, 'Sign out'));
      expect(signedOut, 1);
      expect(db.resetAcks, isEmpty, reason: 'signing out deletes nothing');
      await t.pumpWidget(const SizedBox());
      db = ScriptedDb();
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.keyUnavailable));
      expect(find.text('Sign out'), findsNothing);
    });

    testWidgets('the raw cause is never shown', (t) async {
      for (final e in DbOpenError.values) {
        db = ScriptedDb();
        await t.pumpWidget(const SizedBox());
        await pumpGate(t, initial: DbFailed(uid, e, 'MARKER sqlite ATTACH KEY 0123abcd'));
        expect(find.textContaining('MARKER'), findsNothing);
        expect(find.textContaining('0123abcd'), findsNothing);
      }
    });

    testWidgets('only keyMismatch ever shows a reset action', (t) async {
      for (final e in DbOpenError.values) {
        db = ScriptedDb();
        await t.pumpWidget(const SizedBox());
        await pumpGate(t, initial: DbFailed(uid, e));
        expect(resetButton, e == DbOpenError.keyMismatch ? findsOneWidget : findsNothing, reason: e.name);
      }
    });
  });

  group('gate lifecycle', () {
    testWidgets('opens this doctor once after the first frame, then shows the app', (t) async {
      await pumpGate(t, manage: true);
      await t.pump();
      expect(db.openCalls, [uid]);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('does not reopen a database that is already ready', (t) async {
      await pumpGate(t, initial: const DbReady(uid), manage: true);
      expect(db.openCalls, isEmpty);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets("another doctor's states are never shown as this doctor's", (t) async {
      await pumpGate(t, initial: const DbOpening(uid));
      db.emit(const DbReady('doctorB'));
      await t.pump();
      expect(find.text(home), findsNothing);
      db.emit(const DbFailed('doctorB', DbOpenError.keyMismatch));
      await t.pump();
      expect(resetButton, findsNothing);
      expect(find.text('Opening your records...'), findsOneWidget);
    });

    testWidgets('reopens once if the database is closed underneath it', (t) async {
      await pumpGate(t, manage: true);
      await t.pump();
      expect(db.openCalls, [uid]);
      db.emit(const DbClosed());
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
      expect(db.openCalls, [uid, uid]);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('closes the database when removed (sign-out)', (t) async {
      await pumpGate(t, manage: true);
      await t.pump();
      expect(find.text(home), findsOneWidget);
      await t.pumpWidget(const MaterialApp(home: Text('login')));
      expect(db.closeCalls, 1);
    });

    testWidgets('switching doctor closes the old one before opening the new one', (t) async {
      final log = <String>[];
      await pumpGate(t, manage: true);
      await t.pump();
      db.onOpen = (u) {
        log.add('ready:$u');
        return DbReady(u);
      };
      final closesBefore = db.closeCalls;
      await pumpGate(t, manage: true, forUid: 'doctorB');
      await t.pump();
      expect(db.closeCalls, closesBefore + 1);
      expect(db.openCalls, [uid, 'doctorB']);
      expect(log, ['ready:doctorB']);
      expect(find.text(home), findsOneWidget);
    });
  });

  group('reset screen', () {
    Future<void> openReset(WidgetTester t) async {
      await pumpGate(t, initial: const DbFailed(uid, DbOpenError.keyMismatch));
      await t.tap(resetButton);
      await t.pumpAndSettle();
    }

    Finder confirmButton() => find.widgetWithText(FilledButton, 'Reset and download again');
    bool confirmEnabled(WidgetTester t) => t.widget<FilledButton>(confirmButton()).onPressed != null;

    testWidgets('known count above 0 says how many records would be lost', (t) async {
      db.unsynced = const UnsyncedCount.known(3);
      await openReset(t);
      expect(find.text('3 records will be lost'), findsOneWidget);
      expect(find.textContaining("3 records on this phone haven't been saved to the cloud"), findsOneWidget);
      expect(find.text('I understand that 3 records will be permanently deleted.'), findsOneWidget);
    });

    testWidgets('a single record uses the singular', (t) async {
      db.unsynced = const UnsyncedCount.known(1);
      await openReset(t);
      expect(find.text('1 record will be lost'), findsOneWidget);
    });

    testWidgets('unknown count shows the strongest warning', (t) async {
      db.unsynced = UnsyncedCount.unknown;
      await openReset(t);
      expect(find.text("DOCEase can't tell what would be lost"), findsOneWidget);
      expect(find.textContaining('gone for good'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    testWidgets('known 0 still needs confirmation', (t) async {
      await openReset(t);
      expect(find.text('Nothing unsaved on this phone'), findsOneWidget);
      expect(confirmEnabled(t), isFalse);
    });

    testWidgets('reset needs the explicit confirmation and passes the count shown', (t) async {
      db.unsynced = const UnsyncedCount.known(3);
      await openReset(t);
      expect(confirmEnabled(t), isFalse);
      await t.tap(confirmButton());
      await t.pump();
      expect(db.resetAcks, isEmpty);

      await t.tap(find.byType(Checkbox));
      await t.pump();
      expect(confirmEnabled(t), isTrue);
      await t.tap(confirmButton());
      await t.pumpAndSettle();
      expect(db.resetAcks, [const UnsyncedCount.known(3)]);
      expect(find.byType(DbResetScreen), findsNothing);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('unknown is acknowledged as unknown', (t) async {
      db.unsynced = UnsyncedCount.unknown;
      await openReset(t);
      await t.tap(find.byType(Checkbox));
      await t.pump();
      await t.tap(confirmButton());
      await t.pumpAndSettle();
      expect(db.resetAcks, [UnsyncedCount.unknown]);
    });

    testWidgets('if the count got worse nothing is deleted and the doctor confirms again', (t) async {
      db.unsynced = const UnsyncedCount.known(0);
      db.nextResetRefusal = const ResetNotConfirmedException(UnsyncedCount.known(5));
      await openReset(t);
      await t.tap(find.byType(Checkbox));
      await t.pump();
      await t.tap(confirmButton());
      await t.pumpAndSettle();
      expect(find.byType(DbResetScreen), findsOneWidget);
      expect(find.text('5 records will be lost'), findsOneWidget);
      expect(find.textContaining('The number of unsaved records changed'), findsOneWidget);
      expect(confirmEnabled(t), isFalse, reason: 'confirmation cleared');

      await t.tap(find.byType(Checkbox));
      await t.pump();
      await t.tap(confirmButton());
      await t.pumpAndSettle();
      expect(db.resetAcks, [const UnsyncedCount.known(0), const UnsyncedCount.known(5)]);
      expect(find.text(home), findsOneWidget);
    });

    testWidgets('cancel goes back without resetting', (t) async {
      db.unsynced = const UnsyncedCount.known(2);
      await openReset(t);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(db.resetAcks, isEmpty);
      expect(resetButton, findsOneWidget);
    });
  });
}
