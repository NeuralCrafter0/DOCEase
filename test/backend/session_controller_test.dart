import 'dart:async';

import 'package:docease/providers/local_database.dart';
import 'package:docease/services/session_controller.dart';
import 'package:docease/services/session_platform.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late List<String> log;
  late SessionDb db;
  late StreamController<User?> auth;
  late FakeSessionPlatform platform;
  late SpyPatients patients;
  late SpyDoctor doctor;
  late SpyMedicines medicines;
  late SessionController c;

  SessionController build({SessionDb? withDb}) => SessionController(
        authStateChanges: auth.stream,
        db: withDb ?? db,
        patients: patients,
        doctor: doctor,
        medicines: medicines,
        platform: platform,
        observeAppLifecycle: false,
      );

  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await flushMicrotasks();
      await c.idle;
    }
  }

  Future<void> signIn(String uid) async {
    auth.add(FakeUser(uid));
    await settle();
  }

  Future<void> signOut() async {
    auth.add(null);
    await settle();
  }

  void setUpWith(SessionDb d) {
    log = [];
    db = d;
    db.events.clear();
    auth = StreamController<User?>.broadcast();
    platform = FakeSessionPlatform(log);
    patients = SpyPatients(log);
    doctor = SpyDoctor(log);
    medicines = SpyMedicines(log);
    c = build();
  }

  setUp(() => setUpWith(SessionDb()));
  tearDown(() async {
    c.dispose();
    await auth.close();
  });

  List<String> loads() => log.where((l) => l.contains('.load:')).toList();

  group('start and sign-in', () {
    test('signed out: nothing opens or loads; legacy Firestore cache wiped once', () async {
      expect(c.phase, SessionPhase.starting);
      await signOut();
      expect(c.phase, SessionPhase.signedOut);
      expect(db.events, isEmpty);
      expect(loads(), isEmpty);
      expect(log.where((l) => l == 'firestore.clearCache').length, 1);

      // Next launch: flag set, no second wipe.
      c.dispose();
      log.clear();
      c = build();
      await signOut();
      expect(log, isNot(contains('firestore.clearCache')));
    });

    test('approved sign-in opens the DB for that uid, then loads patients, profile and medicines', () async {
      await signIn('a');
      expect(c.phase, SessionPhase.ready);
      expect(c.uid, 'a');
      expect(db.events, ['open:a']);
      expect(loads(), unorderedEquals(['patients.load:a', 'doctor.load:a', 'medicines.load:a']));
      expect(patients.lastToken, isNotNull);
      expect(log.indexOf('approval:a'), lessThan(log.indexOf('patients.load:a')));
    });

    test('sync waits until the DB reports ready for the current uid', () async {
      db.autoReady = false;
      await signIn('a');
      expect(c.phase, SessionPhase.opening);
      expect(loads(), isEmpty);

      db.emit(const DbMigrating('a', DbMigrationStep.encryptingPlaintext, 0.5));
      expect(c.phase, SessionPhase.migrating);
      expect(c.migrationStep, DbMigrationStep.encryptingPlaintext);
      expect(c.migrationProgress, 0.5);

      db.emit(const DbReady('b')); // someone else's DB
      await settle();
      expect(loads(), isEmpty);

      db.emit(const DbReady('a'));
      await settle();
      expect(c.phase, SessionPhase.ready);
      expect(loads(), unorderedEquals(['patients.load:a', 'doctor.load:a', 'medicines.load:a']));

      db.emit(const DbReady('a')); // duplicate event: no second load
      await settle();
      expect(loads().length, 3);
    });

    test('token refreshes for the same uid do nothing', () async {
      await signIn('a');
      log.clear();
      await signIn('a');
      expect(log, isEmpty);
      expect(db.events, ['open:a']);
    });
  });

  group('sign-out and account switch', () {
    test('sign-out clears every provider, cancels sync, closes the DB and drops caches', () async {
      await signIn('a');
      final token = patients.lastToken!;
      log.clear();
      await signOut();
      expect(c.phase, SessionPhase.signedOut);
      expect(c.uid, isNull);
      expect(token.isCancelled, isTrue);
      expect(log, containsAll(['patients.clear', 'doctor.clear', 'medicines.clear',
          'google.signOut', 'firestore.clearCache', 'images.clear']));
      expect(db.events.last, 'close');
      expect(db.state, isA<DbClosed>());
    });

    test('switching accounts tears down A before B opens or loads', () async {
      await signIn('a');
      final tokenA = patients.lastToken!;
      log.clear();
      db.events.clear();
      await signIn('b');

      expect(tokenA.isCancelled, isTrue);
      expect(db.events, ['close', 'open:b']);
      final firstLoadB = log.indexWhere((l) => l.endsWith('.load:b'));
      for (final clear in ['patients.clear', 'doctor.clear', 'medicines.clear', 'firestore.clearCache']) {
        expect(log.indexOf(clear), inInclusiveRange(0, firstLoadB - 1), reason: clear);
      }
      expect(log, isNot(contains('google.signOut')), reason: 'not a full sign-out');
      expect(loads(), unorderedEquals(['patients.load:b', 'doctor.load:b', 'medicines.load:b']));
      expect(c.uid, 'b');
    });

    test('a late DB event for the old account is ignored', () async {
      await signIn('a');
      db.autoReady = false;
      log.clear();
      await signIn('b');
      db.emit(const DbReady('a'));
      await settle();
      expect(loads(), isEmpty);
      expect(c.phase, SessionPhase.opening);
    });

    test('signOut() signs out of Google and Firebase and clears providers at once', () async {
      await signIn('a');
      log.clear();
      await c.signOut();
      expect(log, containsAllInOrder(['patients.clear', 'google.signOut', 'firebase.signOut']));
      expect(patients.lastToken!.isCancelled, isTrue);
    });
  });

  group('approval', () {
    for (final status in [ApprovalStatus.notApproved, ApprovalStatus.emailNotVerified, ApprovalStatus.unknown]) {
      test('$status: no DB is opened and nothing loads', () async {
        platform.approval = status;
        await signIn('a');
        expect(c.phase, SessionPhase.pendingApproval);
        expect(c.approvalStatus, status);
        expect(db.events, isEmpty);
        expect(loads(), isEmpty);
      });
    }

    test('retry() after approval proceeds to ready', () async {
      platform.approval = ApprovalStatus.notApproved;
      await signIn('a');
      platform.approval = ApprovalStatus.approved;
      c.retry();
      await settle();
      expect(c.phase, SessionPhase.ready);
      expect(db.events, ['open:a']);
    });

    test('offline start trusts the last approval for the same uid only', () async {
      await signIn('a'); // approved, remembered
      await signOut();
      platform.approval = ApprovalStatus.unknown;
      await signIn('a');
      expect(c.phase, SessionPhase.ready);
      await signOut();
      await signIn('b');
      expect(c.phase, SessionPhase.pendingApproval);
    });

    test('a revoked approval forgets the cached answer', () async {
      await signIn('a');
      await signOut();
      platform.approval = ApprovalStatus.notApproved;
      await signIn('a');
      await signOut();
      platform.approval = ApprovalStatus.unknown;
      await signIn('a');
      expect(c.phase, SessionPhase.pendingApproval);
    });
  });

  group('open failures', () {
    test('key mismatch: failed with reset offered; reset then loads', () async {
      db.openError = DbOpenException(DbOpenError.keyMismatch, uid: 'a');
      await signIn('a');
      expect(c.phase, SessionPhase.failed);
      expect(c.failure, DbOpenError.keyMismatch);
      expect(c.canReset, isTrue);
      expect(loads(), isEmpty);

      await c.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown);
      await settle();
      expect(db.resets, 1);
      expect(c.phase, SessionPhase.ready);
      expect(loads(), contains('patients.load:a'));
    });

    test('other failures never offer reset; retry() reopens', () async {
      db.openError = DbOpenException(DbOpenError.keyUnavailable, uid: 'a');
      await signIn('a');
      expect(c.phase, SessionPhase.failed);
      expect(c.canReset, isFalse);
      expect(() => c.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown), throwsStateError);

      db.openError = null;
      c.retry();
      await settle();
      expect(c.phase, SessionPhase.ready);
      expect(db.events, ['open:a', 'open:a']);
    });
  });

  group('legacy unscoped database', () {
    late InspectableSessionDb ldb;
    setUp(() {
      c.dispose();
      ldb = InspectableSessionDb()..legacy = true;
      setUpWith(ldb);
    });

    test('claimed silently when every legacy patient is in this doctor\'s Firestore', () async {
      ldb.legacyIds = {'p1', 'p2'};
      platform.cloudIds = {'p1', 'p2', 'p3'};
      await signIn('a');
      expect(ldb.events, ['claim:a']);
      expect(c.phase, SessionPhase.ready);
    });

    test('mismatch asks first; nothing is claimed or loaded until answered', () async {
      ldb.legacyIds = {'p1', 'p2'};
      platform.cloudIds = {'p1'};
      await signIn('a');
      expect(c.phase, SessionPhase.legacyDecision);
      final prompt = c.legacyPrompt!;
      expect(prompt.uid, 'a');
      expect(prompt.legacyPatientCount, 2);
      expect(prompt.matchingCloudCount, 1);
      expect(prompt.cloudCheckFailed, isFalse);
      expect(ldb.events, isEmpty);
      expect(loads(), isEmpty);

      await c.resolveLegacyMerge(LegacyMergeChoice.merge);
      await settle();
      expect(ldb.events, ['claim:a']);
      expect(c.phase, SessionPhase.ready);
    });

    test('keepSeparate opens the doctor\'s own DB and is remembered', () async {
      ldb.legacyIds = {'p9'};
      platform.cloudIds = {};
      await signIn('a');
      await c.resolveLegacyMerge(LegacyMergeChoice.keepSeparate);
      await settle();
      expect(ldb.events, ['open:a']);
      expect(ldb.legacy, isTrue, reason: 'legacy file left untouched');
      expect(c.phase, SessionPhase.ready);

      await signOut();
      ldb.events.clear();
      await signIn('a');
      expect(c.phase, SessionPhase.ready, reason: 'not asked again');
      expect(ldb.events, ['open:a']);
    });

    test('cloud unreachable: asks and says ownership is unknown', () async {
      ldb.legacyIds = {'p1'};
      platform.cloudIds = null;
      await signIn('a');
      expect(c.phase, SessionPhase.legacyDecision);
      expect(c.legacyPrompt!.cloudCheckFailed, isTrue);
    });

    test('signing out while the question is open drops it', () async {
      ldb.legacyIds = {'p1'};
      platform.cloudIds = {};
      await signIn('a');
      await signOut();
      expect(c.legacyPrompt, isNull);
      await c.resolveLegacyMerge(LegacyMergeChoice.merge);
      await settle();
      expect(ldb.events, ['close']);
    });
  });

  test('without the legacy-id inspector the user is asked (ids unknown)', () async {
    db.legacy = true;
    await signIn('a');
    expect(c.phase, SessionPhase.legacyDecision);
    expect(c.legacyPrompt!.legacyPatientCount, isNull);
  });
}
