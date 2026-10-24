// UI redesign contract §7 G2: PatientProvider.hasLoaded. False after
// clear() and on an owner/session change, until the first load for the
// current owner settles (success or failure). A stale owner's load never
// flips it. Listeners are notified when it flips.
import 'dart:async';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fakes.dart';

const doctorA = 'doctorA';
const doctorB = 'doctorB';

/// MergeDb whose next strict list read can be held until released.
class _GateDb extends MergeDb {
  final List<Completer<void>> gates = [];
  final List<Completer<void>> entered = [];
  @override
  Future<List<Patient>> fetchPatientsStrict() async {
    if (gates.isNotEmpty) {
      final gate = gates.removeAt(0);
      if (entered.isNotEmpty) entered.removeAt(0).complete();
      await gate.future;
    }
    return super.fetchPatientsStrict();
  }
}

void main() {
  late _GateDb db;
  late PatientProvider provider;
  late List<bool> seen; // hasLoaded at every notifyListeners

  PatientProvider make({bool cloud = false}) => PatientProvider(
      db: db, firestore: CloudFirestoreHelper(), auth: FakeAuth(doctorA), storage: FakeStorage(),
      cloudSync: cloud,
      retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));

  /// The values hasLoaded took across notifications, without repeats.
  List<bool> flips() {
    final out = <bool>[];
    for (final v in seen) {
      if (out.isEmpty || out.last != v) out.add(v);
    }
    return out;
  }

  (Completer<void>, Completer<void>) hold() {
    final gate = Completer<void>();
    final entered = Completer<void>();
    db.gates.add(gate);
    db.entered.add(entered);
    return (gate, entered);
  }

  setUp(() {
    db = _GateDb()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1');
    db.dirty['p1'] = false;
    provider = make();
    seen = [];
    provider.addListener(() => seen.add(provider.hasLoaded));
  });

  tearDown(() => provider.dispose());

  test('false until the first load settles; true on success, notified', () async {
    expect(provider.hasLoaded, isFalse);
    final (gate, entered) = hold();
    final load = provider.loadAndSync(doctorA);
    await entered.future;
    expect(provider.hasLoaded, isFalse, reason: 'load still in flight');
    gate.complete();
    await load;
    expect(provider.hasLoaded, isTrue);
    expect(provider.loadFailed, isFalse);
    expect(seen, isNotEmpty);
    expect(seen.last, isTrue);
    expect(flips(), [true]);
  });

  test('a failed first load also settles: hasLoaded and loadFailed both true, list empty', () async {
    db.fetchStrictThrows = const DbReadException(DbReadFailure.readFailed);
    await provider.loadAndSync(doctorA);
    expect(provider.hasLoaded, isTrue);
    expect(provider.loadFailed, isTrue);
    expect(provider.patients, isEmpty);
    expect(seen.last, isTrue);
    // The UI's empty state must not show here (loadFailed).
    final empty = provider.hasLoaded && provider.patients.isEmpty && !provider.loadFailed;
    expect(empty, isFalse);
    // A later reload keeps hasLoaded true (already settled once).
    db.fetchStrictThrows = null;
    await provider.reload();
    expect(provider.hasLoaded, isTrue);
    expect(provider.loadFailed, isFalse);
    expect(flips(), [true]);
  });

  test('a phone with no patients: hasLoaded, empty list, not failed -> the empty state', () async {
    db.rows.clear();
    db.dirty.clear();
    await provider.loadAndSync(doctorA);
    expect(provider.hasLoaded && provider.patients.isEmpty && !provider.loadFailed, isTrue);
  });

  test('clear() resets it and notifies', () async {
    await provider.loadAndSync(doctorA);
    expect(provider.hasLoaded, isTrue);
    seen.clear();
    provider.clear();
    expect(provider.hasLoaded, isFalse);
    expect(seen, [false]);
  });

  test('owner switch resets it and notifies; true again once the new owner loads', () async {
    await provider.loadAndSync(doctorA);
    expect(provider.hasLoaded, isTrue);
    seen.clear();
    db.state = const DbReady(doctorB);
    final (gate, entered) = hold();
    final load = provider.loadAndSync(doctorB);
    expect(provider.hasLoaded, isFalse, reason: 'reset synchronously on the owner change');
    expect(seen, [false]);
    await entered.future;
    expect(provider.hasLoaded, isFalse);
    gate.complete();
    await load;
    expect(provider.hasLoaded, isTrue);
    expect(flips(), [false, true]);
  });

  test('owner switch while the DB is not open yet: stays false (nothing settled)', () async {
    await provider.loadAndSync(doctorA);
    db.state = const DbClosed();
    await provider.loadAndSync(doctorB);
    expect(provider.hasLoaded, isFalse);
  });

  test("a stale owner's load never flips it (success or failure)", () async {
    for (final fail in [false, true]) {
      provider.clear();
      db.state = const DbReady(doctorA);
      final (gateA, enteredA) = hold();
      final loadA = provider.loadAndSync(doctorA);
      await enteredA.future;
      // Switch to B while A's read is in flight; B's read is held too.
      db.state = const DbReady(doctorB);
      final (gateB, enteredB) = hold();
      final loadB = provider.loadAndSync(doctorB);
      await enteredB.future;
      seen.clear();
      if (fail) db.fetchStrictThrows = const DbReadException(DbReadFailure.readFailed);
      gateA.complete();
      await loadA;
      expect(provider.hasLoaded, isFalse, reason: "A's result is stale (fail=$fail)");
      expect(provider.loadFailed, isFalse);
      expect(seen, isEmpty, reason: 'no notification from the stale load');
      db.fetchStrictThrows = null;
      gateB.complete();
      await loadB;
      expect(provider.hasLoaded, isTrue);
      expect(provider.sessionUid, doctorB);
    }
  });

  test('a load cancelled by clear() never flips it', () async {
    final (gate, entered) = hold();
    final load = provider.loadAndSync(doctorA);
    await entered.future;
    provider.clear();
    seen.clear();
    gate.complete();
    await load;
    expect(provider.hasLoaded, isFalse);
    expect(seen, isEmpty);
    expect(provider.patients, isEmpty);
  });

  test('cloud mode: true once the local read settles, before the push and pull finish', () async {
    provider.dispose();
    provider = make(cloud: true);
    seen = [];
    provider.addListener(() => seen.add(provider.hasLoaded));
    final load = provider.loadAndSync(doctorA);
    await load;
    expect(provider.hasLoaded, isTrue);
    expect(seen.first, isTrue, reason: 'the first notification (isSyncing) already reports it');
  });
}
