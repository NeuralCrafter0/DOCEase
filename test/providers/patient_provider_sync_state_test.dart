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
}
