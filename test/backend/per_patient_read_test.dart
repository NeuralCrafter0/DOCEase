// Per-patient strict reads (#10 4f3a8ee: LocalDatabase.fetchPatientStrict).
// Every save reads only its own stored row inside the patient's lock. A row
// that is unreadable (DbReadFailure.unreadableRow) blocks only that
// patient: its saves are refused and PatientProvider.isPatientUnreadable
// reports it. notOpen / readFailed still refuse every save. Anything that
// scans every patient (the sweep, the cloud pull) stays all-or-nothing.
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/photo_sweep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

const doctorA = 'doctorA';
const doctorB = 'doctorB';

VisitRecord visit(String id) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: 'd-$id', prescription: 'p', attachmentPaths: const []);

/// A stored row this app version cannot read (a visit with a bad date).
Patient damaged(String id) {
  final row = Patient.fromJson({
    'id': id,
    'name': 'Ravi',
    'age': '40',
    'gender': 'Male',
    'phone': '+91',
    'history': [
      {'id': 'r1', 'date': 'not-a-date', 'diagnosis': 'Dx'}
    ],
  });
  expect(row.hasParseErrors, isTrue);
  return row;
}

/// MergeDb whose attachment scan behaves like the real DB's: it throws
/// unreadableRow when any stored row is unreadable (#10's fake only
/// collects paths).
class _ScanDb extends MergeDb {
  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    if (rows.values.any((p) => p.hasParseErrors)) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.unreadableRow);
    }
    return super.referencedAttachmentKeys();
  }
}

Matcher refusedWith(DbReadFailure reason) => isA<SaveRefusedException>().having(
    (e) => e.error, 'error', isA<DbReadException>().having((e) => e.reason, 'reason', reason));

void main() {
  late Directory root;
  late Directory support;
  late LocalPhotoStore photos;
  late _ScanDb db;
  late CloudFirestoreHelper remote;
  late PatientProvider provider;
  late int notified;

  PatientProvider make({bool cloud = false}) => PatientProvider(
      db: db, firestore: remote, auth: FakeAuth(doctorA), storage: FakeStorage(), photos: photos,
      cloudSync: cloud,
      retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));

  Future<void> start({bool cloud = false}) async {
    provider = make(cloud: cloud);
    await provider.loadAndSync(doctorA);
    await provider.backgroundIdleForTesting();
    notified = 0;
    provider.addListener(() => notified++);
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_one_row');
    support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _ScanDb()..state = const DbReady(doctorA);
    for (final id in ['p1', 'p2']) {
      db.rows[id] = testPatient(id, history: [visit('v-$id')]);
      db.dirty[id] = false;
    }
    remote = CloudFirestoreHelper();
  });

  tearDown(() {
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  List<String> ids(Patient p) => [for (final r in p.history) r.id];

  test('a row damaged after the list loaded blocks only that patient', () async {
    await start();
    expect(provider.patients.map((p) => p.id), containsAll(['p1', 'p2']));
    final broken = damaged('p2');
    db.rows['p2'] = broken; // damaged after a clean load

    // The other patient still saves.
    await provider.addRecord('p1', visit('vNew'));
    await provider.updatePatientDetails('p1', name: 'Asha K');
    expect(ids(db.rows['p1']!), contains('vNew'));
    expect(db.rows['p1']!.name, 'Asha K');
    expect(provider.isPatientUnreadable('p1'), isFalse);

    // The damaged one refuses each save, with the unreadableRow cause.
    await expectLater(provider.addRecord('p2', visit('vX')), throwsA(refusedWith(DbReadFailure.unreadableRow)));
    await expectLater(provider.updatePatientDetails('p2', name: 'X'), throwsA(refusedWith(DbReadFailure.unreadableRow)));
    await expectLater(provider.deleteRecord('p2', 'v-p2'), throwsA(refusedWith(DbReadFailure.unreadableRow)));
    expect(identical(db.rows['p2'], broken), isTrue, reason: 'nothing written over the damaged row');
    expect(provider.isPatientUnreadable('p2'), isTrue);
    expect(notified, greaterThan(0), reason: 'the UI is told p2 is blocked');
    expect(provider.loadFailed, isFalse, reason: 'one patient, not the whole list');
  });

  test('openPatient flips isPatientUnreadable at runtime, and back once readable', () async {
    await start();
    expect(provider.isPatientUnreadable('p2'), isFalse);
    db.rows['p2'] = damaged('p2');
    await provider.openPatient('p2');
    expect(provider.isPatientUnreadable('p2'), isTrue);
    expect(notified, 1);
    await provider.openPatient('p1');
    expect(provider.isPatientUnreadable('p1'), isFalse);
    expect(notified, 1, reason: 'no change, no notification');
    db.rows['p2'] = testPatient('p2', history: [visit('v-p2')]);
    await provider.openPatient('p2');
    expect(provider.isPatientUnreadable('p2'), isFalse);
    expect(notified, 2);
  });

  test('openPatient never throws and keeps the flag on notOpen / readFailed', () async {
    await start();
    db.rows['p2'] = damaged('p2');
    await provider.openPatient('p2');
    for (final reason in [DbReadFailure.readFailed, DbReadFailure.notOpen]) {
      db.fetchStrictThrows = DbReadException(reason);
      await provider.openPatient('p2');
      await provider.openPatient('p1');
      expect(provider.isPatientUnreadable('p2'), isTrue, reason: reason.name);
      expect(provider.isPatientUnreadable('p1'), isFalse, reason: reason.name);
    }
  });

  test('notOpen and readFailed refuse every save and block no single patient', () async {
    await start();
    for (final reason in [DbReadFailure.readFailed, DbReadFailure.notOpen]) {
      db.fetchStrictThrows = DbReadException(reason);
      for (final id in ['p1', 'p2']) {
        await expectLater(provider.addRecord(id, visit('vN-$id')), throwsA(refusedWith(reason)));
        await expectLater(provider.updatePatientDetails(id, name: 'N'), throwsA(refusedWith(reason)));
        expect(provider.isPatientUnreadable(id), isFalse, reason: '${reason.name} is not per-patient');
      }
    }
    db.fetchStrictThrows = null;
    expect(ids(db.rows['p1']!), ['v-p1']);
    expect(db.rows['p2']!.name, 'Asha');
  });

  test('a save racing a local delete sees the pending delete and refuses', () async {
    await start();
    db.tombstones.add('p1'); // deleted locally; memory still lists p1
    final before = db.rows['p1'];
    await expectLater(provider.addRecord('p1', visit('vLate')), throwsA(isA<LocalSaveFailedException>()));
    await expectLater(provider.deleteRecord('p1', 'v-p1'), throwsA(isA<LocalSaveFailedException>()));
    await expectLater(provider.updatePatientDetails('p1', name: 'Late'),
        throwsA(isA<SaveRefusedException>().having((e) => e.error, 'error', isA<StoredPatientMissingException>())));
    expect(identical(db.rows['p1'], before), isTrue, reason: 'no fallback write from memory');
    expect(provider.isPatientUnreadable('p1'), isFalse, reason: 'deleted, not unreadable');
  });

  test('the flag is cleared on clear(), an owner change and a clean reload', () async {
    await start();
    db.rows['p2'] = damaged('p2');
    await provider.openPatient('p2');
    expect(provider.isPatientUnreadable('p2'), isTrue);
    provider.clear();
    expect(provider.isPatientUnreadable('p2'), isFalse);

    db.rows['p2'] = testPatient('p2');
    await provider.loadAndSync(doctorA);
    db.rows['p2'] = damaged('p2');
    await provider.openPatient('p2');
    expect(provider.isPatientUnreadable('p2'), isTrue);
    db.state = const DbReady(doctorB);
    await provider.loadAndSync(doctorB);
    expect(provider.isPatientUnreadable('p2'), isFalse, reason: 'owner change');
  });

  test('the sweep deletes nothing while any row is unreadable (all-or-nothing)', () async {
    await start();
    final folder = photos.visitFolderFor(doctorA)!;
    Directory(folder).createSync(recursive: true);
    final orphan = File(p.join(folder, '0b6f1c2e-7d3a-4e5b-9c8d-1a2b3c4d5e6f.jpg'))..writeAsBytesSync([1, 2, 3]);
    final later = DateTime.now().add(const Duration(hours: 1));
    db.rows['p2'] = damaged('p2');
    final skipped = await PhotoSweep(db: db, photos: photos, now: () => later).sweep(doctorA);
    expect(skipped.ran, isFalse);
    expect(skipped.reason, AttachmentScanFailure.unreadableRow.name);
    expect(orphan.existsSync(), isTrue);
    // Control: once every row reads, the same sweep removes the orphan.
    db.rows['p2'] = testPatient('p2');
    final ran = await PhotoSweep(db: db, photos: photos, now: () => later).sweep(doctorA);
    expect(ran.removed, 1);
    expect(orphan.existsSync(), isFalse);
  });

  test('the cloud pull is all-or-nothing: one unreadable row stops it', () async {
    await start(cloud: true);
    remote.cloud = [testPatient('p1', name: 'Renamed', history: [visit('vC'), visit('v-p1')])];
    db.rows['p2'] = damaged('p2'); // a clean row, damaged after the load
    db.applyLog.clear();
    await provider.syncNowForTesting();
    await provider.backgroundIdleForTesting();
    expect(db.applyLog, isEmpty, reason: 'nothing merged while a row is unreadable');
    expect(ids(db.rows['p1']!), ['v-p1']);
    // Control: with every row readable, the same pull applies p1.
    db.rows['p2'] = testPatient('p2');
    await provider.syncNowForTesting();
    await provider.backgroundIdleForTesting();
    expect(db.applyLog, ['apply:p1']);
    expect(ids(db.rows['p1']!), ['vC', 'v-p1']);
  });

  test('saves read one row: no full-table read on the save path', () async {
    await start();
    final full = db.strictFetches;
    final one = db.strictOneFetches;
    await provider.addRecord('p1', visit('vA'));
    await provider.updatePatientDetails('p1', phone: '+919990001111');
    await provider.deleteRecord('p1', 'vA');
    expect(db.strictFetches, full, reason: 'fetchPatientsStrict never used by a save');
    expect(db.strictOneFetches, greaterThan(one));
  });

  test('registerPickedAttachment signature is frozen (#8 calls it by name)', () {
    // Compile-time pin: this assignment stops compiling if it drifts.
    provider = make();
    final void Function({required String patientId, required String localPath}) f =
        provider.registerPickedAttachment;
    expect(f, isNotNull);
    final src = File('lib/providers/patient_provider.dart').readAsStringSync();
    expect(src, contains('  void registerPickedAttachment({required String patientId, required String localPath})'));
  });
}
