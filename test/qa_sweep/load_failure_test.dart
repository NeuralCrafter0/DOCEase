// Load-failure contract (security #16 loadFailed) on the merge: #10 strict reads
// (DbReadException/DbReadFailure), #16 3a695b0 PatientProvider.loadFailed/reload(),
// #20 4b2b897 screens. Ported from the pending draft (names confirmed 10:27).
// Every case asserts the agreed behaviour; a failure is a defect.
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart'
    show AttachmentScanFailure, AttachmentScanIncomplete;
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/providers/save_refused_exception.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/patient_load_status.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';
import 'support/app_sweep_wiring.dart';

const ownerA = 'doctorA';
const ownerB = 'doctorB';
const secretName = 'Priya_Sharma';
final firebaseHits = <String>[];

class _TripAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation i) {
    firebaseHits.add('auth.${i.memberName}');
    throw StateError('FirebaseAuth touched');
  }
}

class _TripStorage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    firebaseHits.add('storage.${i.memberName}');
    throw StateError('Storage touched');
  }
}

class _TripHelper extends FakeFirestoreHelper {
  @override
  Future<bool> syncPatient(Patient patient) async => false;
  @override
  Future<bool> deletePatient(String patientId) async => false;
}

VisitRecord _visit(String id, [List<String> photos = const []]) => VisitRecord(
    id: id,
    date: DateTime(2026, 1, 2),
    visitType: 'Consultation',
    symptoms: 'cough',
    diagnosis: 'cold',
    prescription: 'rest',
    attachmentPaths: photos);

Patient _patient(String id, {String? name, List<VisitRecord>? history}) =>
    Patient(
        id: id,
        name: name ?? 'Test $id',
        age: '30',
        gender: 'Female',
        phone: '+9100000',
        history: history ?? [_visit('v-$id')]);

/// Fake whose reads fail while it still reports DbReady (the real-stack
/// failure security reproduced). Lenient fetchPatients() keeps its UI-only
/// behaviour (returns []); the strict read and the key scan throw.
class _FailDb extends FakeLocalDatabase {
  DbReadFailure kind = DbReadFailure.readFailed;
  bool get failReads => strictReadFailure != null;
  set failReads(bool v) => strictReadFailure = v ? kind : null;

  @override
  Future<List<Patient>> fetchPatients() async =>
      failReads ? <Patient>[] : super.fetchPatients();

  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    if (failReads) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.readFailed);
    }
    return super.referencedAttachmentKeys();
  }

  /// Simulates switching the open DB to another doctor's (empty) file.
  void switchTo(String uid, [Iterable<Patient> theirRows = const []]) {
    rows
      ..clear()
      ..addEntries(theirRows.map((r) => MapEntry(r.id, r)));
    dirty.clear();
    state = DbReady(uid);
  }
}

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _FailDb db;

  late PatientLoadStatus status; // shared by provider and sweep, as in the app
  PatientProvider provider() => PatientProvider(
      db: db,
      loadStatus: status,
      cloudSync: false,
      photos: photos,
      firestore: _TripHelper(),
      auth: _TripAuth(),
      storage: _TripStorage());

  setUp(() async {
    firebaseHits.clear();
    root = Directory.systemTemp.createTempSync('qa_loadfail');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _FailDb()..state = const DbReady(ownerA);
    status = PatientLoadStatus();
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('LF provider: loadFailed', () {
    test('LF-01 failed first load: empty list, loadFailed, listeners told',
        () async {
      await db.insertPatient(_patient('p1'));
      db.failReads = true;
      final pp = provider();
      var notified = 0;
      pp.addListener(() => notified++);
      await pp.loadAndSync(ownerA);
      expect(pp.loadFailed, isTrue);
      expect(pp.patients, isEmpty);
      expect(notified, greaterThan(0), reason: 'UI must rebuild');
    });

    test('LF-02 failed reload keeps the old list for the same owner',
        () async {
      await db.insertPatient(_patient('p1'));
      final pp = provider();
      await pp.loadAndSync(ownerA);
      expect(pp.patients.map((x) => x.id), ['p1']);
      db.failReads = true;
      await pp.reload();
      expect(pp.loadFailed, isTrue);
      expect(pp.patients.map((x) => x.id), ['p1'],
          reason: 'a failed reload must never blank the list');
    });

    test('LF-03 owner change during loadFailed shows none of A\'s for B',
        () async {
      await db.insertPatient(_patient('pA', name: secretName));
      final pp = provider();
      await pp.loadAndSync(ownerA);
      db.failReads = true;
      await pp.reload();
      expect(pp.loadFailed, isTrue);

      // B loads fine: A's rows gone, loadFailed cleared.
      db
        ..failReads = false
        ..switchTo(ownerB, [_patient('pB')]);
      await pp.loadAndSync(ownerB);
      expect(pp.patients.map((x) => x.id), ['pB']);
      expect(pp.patients.any((x) => x.name == secretName), isFalse);
      expect(pp.loadFailed, isFalse);
    });

    test('LF-03b owner change where B also fails: empty, never A\'s list',
        () async {
      await db.insertPatient(_patient('pA', name: secretName));
      final pp = provider();
      await pp.loadAndSync(ownerA);
      db
        ..switchTo(ownerB)
        ..failReads = true;
      await pp.loadAndSync(ownerB);
      expect(pp.patients, isEmpty, reason: 'stale list kept across owners');
      expect(pp.loadFailed, isTrue);
    });

    test('LF-04 session end clears the list and loadFailed', () async {
      await db.insertPatient(_patient('p1'));
      final pp = provider();
      await pp.loadAndSync(ownerA);
      db.failReads = true;
      await pp.reload();
      pp.clear();
      expect(pp.patients, isEmpty);
      expect(pp.loadFailed, isFalse);
    });

    test('LF-08 reload succeeds after failing: list back, writes enabled',
        () async {
      await db.insertPatient(_patient('p1'));
      db.failReads = true;
      final pp = provider();
      await pp.loadAndSync(ownerA);
      expect(pp.loadFailed, isTrue);
      db.failReads = false;
      await pp.reload();
      expect(pp.loadFailed, isFalse);
      expect(pp.patients.map((x) => x.id), ['p1']);
      await pp.addRecord('p1', _visit('v2'));
      expect(db.rows['p1']!.history.map((v) => v.id), contains('v2'));
    });
  });

  group('LF-05/06 every write is refused while loadFailed', () {
    late PatientProvider pp;
    late Map<String, String> before;

    setUp(() async {
      await db.insertPatient(_patient('p1'));
      pp = provider();
      await pp.loadAndSync(ownerA);
      db.failReads = true;
      await pp.reload(); // stale list: p1 still shown
      expect(pp.loadFailed, isTrue);
      db.log.clear();
      before = {for (final e in db.rows.entries) e.key: e.value.toJson().toString()};
    });

    void untouched() {
      expect(db.log.where((l) => !l.startsWith('fetch')), isEmpty,
          reason: 'DB written while loadFailed: ${db.log}');
      expect({for (final e in db.rows.entries) e.key: e.value.toJson().toString()},
          before);
      expect(db.tombstones, isEmpty);
    }

    final writes = <String, Future<void> Function(PatientProvider)>{
      'addPatient': (pp) => pp.addPatient(_patient('p9')),
      'updatePatient (stale row)': (pp) =>
          pp.updatePatient(_patient('p1', name: 'Edited')),
      'deletePatient (stale row)': (pp) => pp.deletePatient('p1'),
      'addRecord': (pp) => pp.addRecord('p1', _visit('v9')),
      'updateRecord': (pp) => pp.updateRecord('p1', _visit('v-p1')),
      'deleteRecord': (pp) => pp.deleteRecord('p1', 'v-p1'),
    };
    writes.forEach((name, op) {
      test('LF-05 $name throws SaveRefusedException, DB untouched', () async {
        await expectLater(op(pp), throwsA(isA<SaveRefusedException>()));
        untouched();
        expect(pp.patients.map((x) => x.id), ['p1'],
            reason: 'screen must keep showing what is stored');
      });
    });
  });

  group('LF-07 photo cleanup paused while loadFailed', () {
    String photo(String name) {
      final dir = photos.visitFolderFor(ownerA)!;
      Directory(dir).createSync(recursive: true);
      return (File(p.join(dir, name))..writeAsBytesSync([1])).path;
    }

    test('LF-07a provider deletes no photo while loadFailed', () async {
      final a = photo('0b5e6c1e-1111-4222-8333-944455556666.jpg');
      await db.insertPatient(
          _patient('p1', history: [_visit('v1', [a])]));
      final pp = provider();
      await pp.loadAndSync(ownerA);
      db.failReads = true;
      await pp.reload();
      await expectLater(pp.updateRecord('p1', _visit('v1')),
          throwsA(isA<SaveRefusedException>()));
      await expectLater(pp.deletePatient('p1'),
          throwsA(isA<SaveRefusedException>()));
      expect(File(a).existsSync(), isTrue);
    });

    test('LF-07b the app sweep does not run while reads fail', () async {
      final a = photo('0b5e6c1e-1111-4222-8333-944455556666.jpg');
      final orphan = photo('0b5e6c1e-1111-4222-8333-944455550000.jpg');
      await db.insertPatient(
          _patient('p1', history: [_visit('v1', [a])]));
      final pp = provider();
      db.failReads = true;
      await pp.loadAndSync(ownerA);
      expect(pp.loadFailed, isTrue);
      final r = await appSweep(db, photos, () => DateTime.now().add(const Duration(hours: 1)),
              loadStatus: status)
          .sweep(ownerA);
      expect(r.ran, isFalse);
      expect(File(a).existsSync(), isTrue);
      expect(File(orphan).existsSync(), isTrue);
    });
    test('LF-07c DB recovered but no reload yet: the sweep still skips with reason loadFailed '
        '(gate on PatientLoadStatus, not only the fresh scan)', () async {
      final a = photo('0b5e6c1e-1111-4222-8333-944455557777.jpg');
      final orphan = photo('0b5e6c1e-1111-4222-8333-944455551111.jpg');
      await db.insertPatient(_patient('p1', history: [_visit('v1', [a])]));
      final pp = provider();
      db.failReads = true;
      await pp.loadAndSync(ownerA);
      expect(pp.loadFailed, isTrue);
      expect(status.isFailed(ownerA), isTrue, reason: 'provider publishes the failure');
      db.failReads = false; // scan would now succeed
      final r = await appSweep(db, photos, () => DateTime.now().add(const Duration(hours: 1)),
              loadStatus: status)
          .sweep(ownerA);
      expect(r.ran, isFalse);
      expect(r.reason, 'loadFailed');
      expect(File(orphan).existsSync(), isTrue);
      // After a successful reload the same sweep runs and removes only the orphan.
      await pp.reload();
      expect(pp.loadFailed, isFalse);
      expect(status.isLoaded(ownerA), isTrue);
      final r2 = await appSweep(db, photos, () => DateTime.now().add(const Duration(hours: 1)),
              loadStatus: status)
          .sweep(ownerA);
      expect(r2.ran, isTrue);
      expect(File(orphan).existsSync(), isFalse);
      expect(File(a).existsSync(), isTrue);
    });
  });

  group('DBS strict read (fake-level contract; real stack in the FFI draft)',
      () {
    test('DBS-01 closed DB -> notOpen', () async {
      db.state = const DbClosed();
      await expectLater(
          db.fetchPatientsStrict(),
          throwsA(isA<DbReadException>().having(
              (e) => e.reason, 'reason', DbReadFailure.notOpen)));
    });

    test('DBS-04 error text carries no patient data', () async {
      await db.insertPatient(_patient('p1', name: secretName));
      db
        ..failReads = true
        ..kind = DbReadFailure.unreadableRow;
      try {
        await db.fetchPatientsStrict();
        fail('should throw');
      } on DbReadException catch (e) {
        expect('$e', isNot(contains(secretName)));
        expect('$e', isNot(contains('p1')));
      }
    });

    test('DBS-05 audit: non-UI code never uses the lenient read', () {
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (f.path.contains('${p.separator}screens${p.separator}') ||
            f.path.contains('${p.separator}widgets${p.separator}')) {
          continue;
        }
        final src = f.readAsStringSync();
        if (RegExp(r'\.fetchPatients\(\)').hasMatch(src)) offenders.add(f.path);
      }
      expect(offenders, isEmpty,
          reason: 'lenient fetchPatients() (returns [] on error) used by '
              'non-UI code: $offenders');
      expect(File('lib/services/attachment_keys.dart').existsSync(), isFalse,
          reason: 'stand-ins should be gone');
    });
  });
}
