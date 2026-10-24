// PatientProvider marks rows dirty on local writes and clean only after a
// confirmed Firestore write of that exact version. Fakes only (no Firebase).
import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_fakes.dart';

void main() {
  late FakeLocalDatabase db;
  late FakeFirestoreHelper fs;
  late PatientProvider provider;

  setUp(() {
    db = FakeLocalDatabase();
    fs = FakeFirestoreHelper();
    provider = PatientProvider(db: db, firestore: fs);
  });

  test('local add is dirty, then clean after Firestore confirms', () async {
    await provider.addPatient(testPatient('p1'));
    await flushMicrotasks();
    expect(db.log, ['insert:p1:dirty', 'markSynced:p1:1']);
    expect(db.dirty['p1'], isFalse);
    expect(await db.unsyncedCount(), const UnsyncedCount.known(0));
  });

  test('unconfirmed Firestore write leaves the row dirty and counted (SYNC-05)',
      () async {
    fs.syncResult = false;
    await provider.addPatient(testPatient('p1'));
    await flushMicrotasks();
    expect(db.log, ['insert:p1:dirty']);
    expect(db.dirty['p1'], isTrue);
    expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
  });

  test('edit during flight: the older confirmation does not clean the newer '
      'edit', () async {
    fs.manual = true;
    await provider.addPatient(testPatient('p1', name: 'Asha'));
    await provider.updatePatient(testPatient('p1', name: 'Asha K'));
    await flushMicrotasks();
    expect(fs.inFlight, hasLength(2));

    // The first write (version 1) is confirmed after the edit (version 2).
    fs.inFlight[0].complete(true);
    await flushMicrotasks();
    expect(db.log.last, 'markSynced:p1:1');
    expect(db.dirty['p1'], isTrue, reason: 'newer edit must stay dirty');
    expect(await db.unsyncedCount(), const UnsyncedCount.known(1));

    // The newer write is confirmed: now clean.
    fs.inFlight[1].complete(true);
    await flushMicrotasks();
    expect(db.log.last, 'markSynced:p1:2');
    expect(db.dirty['p1'], isFalse);
  });

  test('visit delete is pushed and only then marked clean', () async {
    await provider.addPatient(testPatient('p1', history: [
      VisitRecord(
          id: 'r1',
          date: DateTime(2026, 1, 1),
          visitType: 'Routine',
          symptoms: 's',
          diagnosis: 'URTI',
          prescription: 'rx'),
    ]));
    await flushMicrotasks();
    await provider.deleteRecord('p1', 'r1');
    expect(db.log, [
      'insert:p1:dirty',
      'markSynced:p1:1',
      'update:p1:dirty',
      'markSynced:p1:2',
    ]);
    expect(db.dirty['p1'], isFalse);
  });

  test('a refused save (counter unavailable) is not shown as saved', () async {
    db.refuseWrites = true;
    await expectLater(provider.addPatient(testPatient('p1')),
        throwsA(isA<UnsyncedCounterException>()));
    expect(provider.patients, isEmpty);
    expect(fs.synced, isEmpty);
  });

  test('a refused update restores the previous version', () async {
    await provider.addPatient(testPatient('p1', name: 'Asha'));
    await flushMicrotasks();
    db.refuseWrites = true;
    await expectLater(provider.updatePatient(testPatient('p1', name: 'Changed')),
        throwsA(isA<UnsyncedCounterException>()));
    expect(provider.patients.single.name, 'Asha');
  });

  test('a patient that failed to parse is never written or synced', () async {
    final broken = Patient.fromJson({
      'id': 'p9',
      'name': 'Ravi',
      'age': '40',
      'gender': 'Male',
      'phone': '+91',
      'history': [
        {'id': 'r1', 'date': 'not-a-date', 'diagnosis': 'Dx'}
      ],
    });
    expect(broken.hasParseErrors, isTrue);
    expect(() => provider.addPatient(broken),
        throwsA(isA<UnreadablePatientException>()));
    await flushMicrotasks();
    expect(db.log, isEmpty);
    expect(fs.synced, isEmpty);
  });

  // The merge loop itself is the backend engineer's (fixed on their stacked
  // branch); it calls insertPatient(fromCloud: true), which goes through the
  // DB-layer guard (applyCloudPatient). These tests pin that guard: the
  // stored row, its sync state and the counter. In-memory list handling is
  // the loop's concern and is not asserted here.
  group('cloud merge (review item 5)', () {
    VisitRecord visit(String id) => VisitRecord(
        id: id,
        date: DateTime(2026, 1, 1),
        visitType: 'Routine',
        symptoms: 's',
        diagnosis: 'Dx',
        prescription: 'rx');

    test('never overwrites a dirty local row or marks it synced; counter '
        'unchanged', () async {
      fs.syncResult = false; // the local edit never reached Firestore
      await provider.addPatient(testPatient('p1', name: 'Local edit'));
      await flushMicrotasks();
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));

      // The cloud copy has more history, which the old merge treated as
      // "newer" and wrote over the local row as synced.
      fs.cloud = [testPatient('p1', name: 'Cloud', history: [visit('r1')])];
      await provider.syncNowForTesting();

      expect(db.rows['p1']!.name, 'Local edit');
      expect(db.dirty['p1'], isTrue);
      expect(db.log, contains('cloudSkipped:p1'));
      expect(db.log.where((l) => l.startsWith('markSynced')), isEmpty);
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
    });

    test('a clean row and a new patient are still taken from the cloud',
        () async {
      await provider.addPatient(testPatient('p1', name: 'Old'));
      await flushMicrotasks();
      fs.cloud = [
        testPatient('p1', name: 'Cloud', history: [visit('r1')]),
        testPatient('p2', name: 'New'),
      ];
      await provider.syncNowForTesting();
      expect({for (final p in provider.patients) p.id: p.name},
          {'p1': 'Cloud', 'p2': 'New'});
      expect(db.dirty['p1'], isFalse);
      expect(db.dirty['p2'], isFalse);
      expect(await db.unsyncedCount(), const UnsyncedCount.known(0));
    });

    test('a pending delete is never resurrected by the cloud copy', () async {
      await provider.addPatient(testPatient('p1'));
      await flushMicrotasks();
      fs.deleteResult = false; // offline: delete not confirmed
      await provider.deletePatient('p1');
      expect(db.tombstones, {'p1'});
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));

      // The cloud still has p1 at the next sync.
      fs.cloud = [testPatient('p1', name: 'Cloud')];
      await provider.syncNowForTesting();
      expect(db.rows.containsKey('p1'), isFalse);
      expect(db.tombstones, {'p1'});
      expect(db.log, contains('cloudSkipped:p1'));
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
    });
  });

  group('deletes are unsynced changes (review low item)', () {
    test('delete counts until Firestore confirms it', () async {
      await provider.addPatient(testPatient('p1'));
      await flushMicrotasks();
      expect(await db.unsyncedCount(), const UnsyncedCount.known(0));
      fs.deleteResult = false;
      await provider.deletePatient('p1');
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
      expect(db.log, isNot(contains('clearTombstone:p1')));
    });

    test('a refused delete restores the patient and never deletes in the '
        'cloud', () async {
      await provider.addPatient(testPatient('p1'));
      await flushMicrotasks();
      db.refuseDeletes = true;
      await expectLater(
          provider.deletePatient('p1'), throwsA(isA<DbOpenException>()));
      expect(provider.patients.single.id, 'p1');
      expect(fs.deleted, isEmpty);

      db.refuseDeletes = false;
      db.refuseWrites = true;
      await expectLater(provider.deletePatient('p1'),
          throwsA(isA<UnsyncedCounterException>()));
      expect(provider.patients.single.id, 'p1');
      expect(fs.deleted, isEmpty);
    });

    test('sync does nothing unless the database is ready', () async {
      db.state = const DbFailed('doctorA', DbOpenError.keyUnavailable);
      fs.cloud = [testPatient('p1')];
      await provider.syncNowForTesting();
      expect(db.log, isEmpty);
      expect(fs.deleted, isEmpty);
    });
  });
}
