import 'dart:async';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/services/current_owner.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:docease/services/session_platform.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// CurrentOwner is the seam PR #8's photo picker reads
/// (`AttachmentStorage.currentOwnerId = () => CurrentOwner.id`): it must name
/// the owner only while that owner's session is ready, and never outlive it.
void main() {
  late List<String> log;
  late SessionDb db;
  late StreamController<User?> auth;
  late FakeSessionPlatform platform;
  late SessionController c;

  SessionController build() => SessionController(
        authStateChanges: auth.stream,
        db: db,
        patients: SpyPatients(log),
        doctor: SpyDoctor(log),
        medicines: SpyMedicines(log),
        platform: platform,
        observeAppLifecycle: false,
      );

  Future<void> settle(SessionController s) async {
    for (var i = 0; i < 5; i++) {
      await flushMicrotasks();
      await s.idle;
    }
  }

  setUp(() {
    log = [];
    db = SessionDb();
    auth = StreamController<User?>.broadcast();
    platform = FakeSessionPlatform(log);
    c = build();
  });

  tearDown(() async {
    c.dispose();
    await auth.close();
    expect(CurrentOwner.id, isNull, reason: 'dispose clears the owner');
  });

  test('null while starting and signed out', () async {
    expect(CurrentOwner.id, isNull);
    auth.add(null);
    await settle(c);
    expect(c.phase, SessionPhase.signedOut);
    expect(CurrentOwner.id, isNull);
    expect(c.ownerId, isNull);
  });

  test('set only once the DB for that uid is ready', () async {
    db.autoReady = false;
    auth.add(FakeUser('a'));
    await settle(c);
    expect(c.phase, SessionPhase.opening);
    expect(CurrentOwner.id, isNull);
    db.emit(const DbMigrating('a', DbMigrationStep.encryptingPlaintext, 0.5));
    await settle(c);
    expect(CurrentOwner.id, isNull, reason: 'not while migrating');
    db.emit(const DbReady('a'));
    await settle(c);
    expect(c.phase, SessionPhase.ready);
    expect(CurrentOwner.id, 'a');
    expect(c.ownerId, 'a');
  });

  test('null while approval is pending', () async {
    platform.approval = ApprovalStatus.notApproved;
    auth.add(FakeUser('a'));
    await settle(c);
    expect(c.phase, SessionPhase.pendingApproval);
    expect(CurrentOwner.id, isNull);
  });

  test('cleared on sign-out', () async {
    auth.add(FakeUser('a'));
    await settle(c);
    expect(CurrentOwner.id, 'a');
    auth.add(null);
    await settle(c);
    expect(CurrentOwner.id, isNull);
  });

  test('account switch: null from teardown until B is ready, never A again', () async {
    auth.add(FakeUser('a'));
    await settle(c);
    expect(CurrentOwner.id, 'a');
    db.autoReady = false;
    final seen = <String?>[];
    c.addListener(() => seen.add(CurrentOwner.id));
    auth.add(FakeUser('b'));
    await settle(c);
    expect(CurrentOwner.id, isNull, reason: 'B is still opening');
    db.emit(const DbReady('b'));
    await settle(c);
    expect(CurrentOwner.id, 'b');
    expect(seen, isNot(contains('a')));
  });

  test('cleared at the very start of teardown, before providers are cleared', () async {
    auth.add(FakeUser('a'));
    await settle(c);
    String? ownerDuringClear = 'unset';
    final probe = _ProbePatients(log, () => ownerDuringClear = CurrentOwner.id);
    final s = SessionController(
      authStateChanges: auth.stream,
      db: SessionDb(),
      patients: probe,
      doctor: SpyDoctor(log),
      medicines: SpyMedicines(log),
      platform: platform,
      observeAppLifecycle: false,
    );
    addTearDown(s.dispose);
    auth.add(FakeUser('x'));
    await settle(s);
    expect(CurrentOwner.id, 'x');
    auth.add(null);
    await settle(s);
    expect(ownerDuringClear, isNull);
  });

  test('disposing an old controller does not clear a newer one', () async {
    auth.add(FakeUser('a'));
    await settle(c);
    final old = c;
    final auth2 = StreamController<User?>.broadcast();
    final newer = SessionController(
      authStateChanges: auth2.stream,
      db: SessionDb(),
      patients: SpyPatients(log),
      doctor: SpyDoctor(log),
      medicines: SpyMedicines(log),
      platform: platform,
      observeAppLifecycle: false,
    );
    auth2.add(FakeUser('b'));
    await settle(newer);
    expect(CurrentOwner.id, 'b');
    old.dispose();
    expect(CurrentOwner.id, 'b');
    newer.dispose();
    await auth2.close();
    expect(CurrentOwner.id, isNull);
    c = build(); // for tearDown
  });

  test('dev mode (localOnly): owner is "local"; folder hash matches PR #8', () async {
    final s = SessionController.localOnly(
      db: SessionDb(),
      patients: SpyPatients(log),
      doctor: SpyDoctor(log),
      medicines: SpyMedicines(log),
      observeAppLifecycle: false,
    );
    await settle(s);
    expect(s.phase, SessionPhase.ready);
    expect(CurrentOwner.id, kLocalOwnerId);
    // PR #8's AttachmentStorage.ownerFolderName uses the same
    // sha256(owner)[:32]; pin it so either side notices a change.
    expect(LocalPhotoStore.ownerFolderName(kLocalOwnerId), '25bf8e1a2393f1108d37029b3df55932');
    s.dispose();
    expect(CurrentOwner.id, isNull);
  });
}

/// Records CurrentOwner.id at the moment the session clears patients.
class _ProbePatients extends SpyPatients {
  _ProbePatients(super.log, this.onClear);
  final void Function() onClear;
  @override
  void clear() {
    onClear();
    super.clear();
  }
}
