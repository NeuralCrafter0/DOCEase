// Real SQLCipher via FFI: #10 fed74ca swapAttachmentPath contract (user 08:10).
// Run: QA_FFI_TEST=qa_swap_ffi_test.dart bash tool/sqlcipher_harness/run_qa.sh
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'qa_sweep_ffi_test.dart' show RecOpener;
import 'sqlcipher_ffi_test.dart' show MemKeys;

const uidA = 'doctorA';
const uidB = 'doctorB';
const android = '/data/user/0/com.docease.app/files';
const androidAlias = '/data/data/com.docease.app/files';
const u1 = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
const u2 = '1c8a7d3f-5e2b-4d4c-8f90-3b2c4d5e6f70';
const marker = 'ZZ-SWAP-MARKER-3d7a';
final ownerA = AttachmentRefs.ownerFolderNameFor(uidA);
final ownerB = AttachmentRefs.ownerFolderNameFor(uidB);
String localA(String u, {String root = android}) =>
    '$root/attachments/$ownerA/$u.jpg';
String storage(String u, {String uid = uidA, String pid = 'p1', String ext = 'jpg'}) =>
    'clinical_attachments/$uid/$pid/$u.$ext';
const oldStorage = 'clinical_attachments/doctorA/p1/old.jpg';

VisitRecord visit(String id, List<String> paths, {String diagnosis = 'd'}) =>
    VisitRecord(
        id: id,
        date: DateTime(2026, 1, id == 'v1' ? 2 : 3),
        visitType: 'Consultation',
        symptoms: 's',
        diagnosis: diagnosis,
        prescription: 'r',
        attachmentPaths: paths);

Patient patient({String id = 'p1', String name = 'Asha', List<VisitRecord>? history}) =>
    Patient(
        id: id,
        name: name,
        age: '30',
        gender: 'Female',
        phone: '+910000000000',
        history: history ??
            [
              visit('v1', [localA(u1), oldStorage, localA(u2)]),
              visit('v2', [localA(u1, root: androidAlias)]),
            ]);

void main() {
  late Directory tmp;
  late DatabaseHelper db;
  late RecOpener opener;
  late MemKeys keys;

  Future<Map<String, Object?>> row(String id) async =>
      (await opener.last!.query('patients', where: 'id = ?', whereArgs: [id]))
          .single;
  Future<List<List<String>>> pathsOf(String id) async =>
      (await db.fetchPatientsStrict())
          .singleWhere((x) => x.id == id)
          .history
          .map((v) => v.attachmentPaths)
          .toList();
  // Raw stored counter (unsynced_count_<uid>). unsyncedCount() recounts
  // dirty rows and rewrites it, which would hide an over-bump.
  Future<int?> counter() async => int.tryParse(keys.m['unsynced_count_$uidA'] ?? '');
  Future<int?> reconciled() async => switch (await db.unsyncedCount()) {
        UnsyncedKnown(:final count) => count,
        _ => null,
      };
  Future<String> snapshot() async {
    final pts = await opener.last!.query('patients', orderBy: 'id');
    final tomb = await opener.last!.query('pending_deletes', orderBy: 'patient_id');
    return '$pts|$tomb|${await counter()}';
  }

  Future<void> markClean(String id) async {
    final r = await row(id);
    expect(await db.markSynced(id, '${r['updated_at']}'), isTrue);
  }

  Future<bool> swapA({String pid = 'p1', String? local, String? to}) =>
      db.swapAttachmentPath(
          expectedOwner: uidA,
          patientId: pid,
          localPath: local ?? localA(u1),
          storagePath: to ?? storage(u1, pid: pid));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('qa_swap_');
    Directory(p.join(tmp.path, 'db')).createSync();
    opener = RecOpener();
    keys = MemKeys();
    db = DatabaseHelper(
        keyStore: keys,
        opener: opener,
        databasesPath: () async => p.join(tmp.path, 'db'));
    await db.openFor(uidA);
    await db.insertPatient(patient());
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    tmp.deleteSync(recursive: true);
  });

  test('SWAP-RS-00 this really is SQLCipher', () async {
    final v = await opener.last!.rawQuery('PRAGMA cipher_version');
    expect('${v.first.values.first}', isNotEmpty);
  });

  group('true: swapped atomically', () {
    test('SWAP-RS-01 clean row: every alias of the key swapped, rest kept, dirty, counter +1',
        () async {
      await markClean('p1');
      expect(await counter(), 0, reason: 'raw stored counter');
      final before = await row('p1');
      expect(await swapA(), isTrue);
      expect(await pathsOf('p1'), [
        [storage(u1), oldStorage, localA(u2)],
        [storage(u1)], // /data/data alias of the same photo
      ]);
      final after = await row('p1');
      expect(after['name'], before['name']);
      expect(after['sync_state'], isNot(before['sync_state']), reason: 'now dirty');
      expect(int.parse('${after['updated_at']}'),
          greaterThan(int.parse('${before['updated_at']}')));
      expect(await counter(), 1, reason: 'clean row counted once');
      expect((await db.dirtyPatientsStrict()).map((x) => x.id), ['p1']);
    });

    test('SWAP-RS-02 dirty row: swapped, counter NOT bumped', () async {
      expect(await counter(), 1, reason: 'insert left p1 dirty');
      expect(await swapA(), isTrue);
      expect(await counter(), 1);
      expect((await pathsOf('p1')).first.first, storage(u1));
    });

    test('SWAP-RS-03 file:/// and file://localhost/ forms of the key swapped', () async {
      await db.insertPatient(patient(id: 'p2', history: [
        visit('v1', ['file://${localA(u1)}', 'file://localhost${localA(u1)}', localA(u2)]),
      ]));
      expect(await swapA(pid: 'p2'), isTrue);
      expect(await pathsOf('p2'), [
        [storage(u1, pid: 'p2'), storage(u1, pid: 'p2'), localA(u2)]
      ]);
    });

    test('SWAP-RS-04 persists across close/reopen; reconcile counter == dirty rows',
        () async {
      await markClean('p1');
      expect(await swapA(), isTrue);
      await db.close();
      await db.openFor(uidA);
      expect((await pathsOf('p1')).first.first, storage(u1));
      expect(await counter(), 1);
      expect(await reconciled(), 1);
    });

    test('SWAP-RS-05 swap bumps updated_at, so an in-flight sync of the old row cannot mark it clean',
        () async {
      final sentVersion = '${(await row('p1'))['updated_at']}';
      expect(await swapA(), isTrue);
      expect(await db.markSynced('p1', sentVersion), isFalse);
      expect((await db.dirtyPatientsStrict()).map((x) => x.id), ['p1']);
    });

    test('SWAP-RS-06 reference scan no longer holds the swapped local key', () async {
      expect(await db.referencedAttachmentKeys(),
          containsAll(['attachments/$u1.jpg', 'attachments/$u2.jpg']));
      expect(await swapA(), isTrue);
      final keysNow = await db.referencedAttachmentKeys();
      expect(keysNow, isNot(contains('attachments/$u1.jpg')));
      expect(keysNow, contains('attachments/$u2.jpg'));
    });
  });

  group('false: photo gone, nothing written', () {
    test('SWAP-RS-10 no such row', () async {
      final s = await snapshot();
      expect(await swapA(pid: 'p404'), isFalse);
      expect(await snapshot(), s);
    });
    test('SWAP-RS-11 tombstoned patient', () async {
      await db.markPendingDelete('p1');
      final s = await snapshot();
      expect(await swapA(), isFalse);
      expect(await snapshot(), s);
    });
    test('SWAP-RS-12 no entry with that key (other uuid)', () async {
      final other = '2d9b8e40-6f3c-4e5d-9a01-4c3d5e6f7081';
      final s = await snapshot();
      expect(await swapA(local: localA(other), to: storage(other)), isFalse);
      expect(await snapshot(), s);
    });
    test('SWAP-RS-13 patient with no visits', () async {
      await db.insertPatient(patient(id: 'p3', history: const []));
      final s = await snapshot();
      expect(await swapA(pid: 'p3'), isFalse);
      expect(await snapshot(), s);
    });
  });

  group('ArgumentError (names the parameter, never the value), nothing written', () {
    final cases = <String, (String, String, String, String)>{
      'wrong extension .gif': (uidA, 'p1', localA(u1), storage(u1, ext: 'gif')),
      'wrong extension .heic': (uidA, 'p1', localA(u1), storage(u1, ext: 'heic')),
      'upper-case .JPG (regex is case-sensitive; uploader writes .jpg)':
          (uidA, 'p1', localA(u1), storage(u1, ext: 'JPG')),
      'storage path of another patient': (uidA, 'p1', localA(u1), storage(u1, pid: 'p2')),
      'storage path of another doctor': (uidA, 'p1', localA(u1), storage(u1, uid: uidB)),
      'storage path with ..': (uidA, 'p1', localA(u1), 'clinical_attachments/doctorA/p1/../$marker.jpg'),
      'local photo in another owner folder':
          (uidA, 'p1', '$android/attachments/$ownerB/$marker.jpg', storage(u1)),
      'local path in profile/ (not a visit photo)':
          (uidA, 'p1', '$android/profile/$ownerA/$marker.jpg', storage(u1)),
      'local path is a Storage path': (uidA, 'p1', storage(u1), storage(u1)),
      'empty expectedOwner': ('', 'p1', localA(u1), 'clinical_attachments//p1/$u1.jpg'),
      'empty patientId': (uidA, '', localA(u1), 'clinical_attachments/doctorA//$u1.jpg'),
    };
    for (final c in cases.entries) {
      test('SWAP-RS-2x ${c.key}', () async {
        final (o, pid, l, s) = c.value;
        final snap = await snapshot();
        try {
          await db.swapAttachmentPath(
              expectedOwner: o, patientId: pid, localPath: l, storagePath: s);
          fail('expected ArgumentError');
        } on ArgumentError catch (e) {
          expect(e.name, isNotNull);
          expect('$e', isNot(contains(marker)));
          expect('$e', isNot(contains(ownerA)));
        }
        expect(await snapshot(), snap);
      });
    }
  });

  test('SWAP-RS-29 INFO: nested/non-uuid name under attachments/<owner>/ is accepted as '
      'localPath (app never creates one); with no such entry it returns false, nothing written',
      () async {
    final snap = await snapshot();
    Object? outcome;
    try {
      outcome = await swapA(local: '$android/attachments/$ownerA/profile/$marker.jpg');
    } on ArgumentError {
      outcome = 'ArgumentError';
    }
    // ignore: avoid_print
    print('SWAP-RS-29 outcome=$outcome');
    expect(outcome, anyOf(false, 'ArgumentError'));
    expect(await snapshot(), snap);
  });

  group('DbReadException, nothing written', () {
    test('SWAP-RS-30 DB closed -> notOpen', () async {
      await db.close();
      await expectLater(
          swapA(),
          throwsA(isA<DbReadException>()
              .having((e) => e.reason, 'reason', DbReadFailure.notOpen)));
    });
    test('SWAP-RS-31 owner mismatch (DB open for A, swap for B) -> notOpen', () async {
      final s = await snapshot();
      await expectLater(
          db.swapAttachmentPath(
              expectedOwner: uidB,
              patientId: 'p1',
              localPath: '$android/attachments/$ownerB/$u1.jpg',
              storagePath: storage(u1, uid: uidB)),
          throwsA(isA<DbReadException>()
              .having((e) => e.reason, 'reason', DbReadFailure.notOpen)));
      expect(await snapshot(), s);
    });
    test('SWAP-RS-32 history does not parse -> unreadableRow', () async {
      await opener.last!
          .rawUpdate("UPDATE patients SET history = 'not json' WHERE id = 'p1'");
      final s = await snapshot();
      await expectLater(
          swapA(),
          throwsA(isA<DbReadException>()
              .having((e) => e.reason, 'reason', DbReadFailure.unreadableRow)
              .having((e) => '$e', 'msg', 'DbReadException(unreadableRow)')));
      expect(await snapshot(), s);
    });
    test('SWAP-RS-33 table unreadable -> readFailed', () async {
      await opener.last!.execute('ALTER TABLE patients RENAME TO patients_x');
      await expectLater(
          swapA(),
          throwsA(isA<DbReadException>()
              .having((e) => e.reason, 'reason', DbReadFailure.readFailed)));
    });
  });

  group('ordering under the row write queue', () {
    test('SWAP-RS-40 save queued BEFORE the swap: swap sees it (edit + Storage path kept)',
        () async {
      final edited = patient(name: 'Asha Edited');
      final save = db.updatePatient(edited); // not awaited: queued first
      final swap = swapA();
      await save;
      expect(await swap, isTrue);
      final r = (await db.fetchPatientsStrict()).single;
      expect(r.name, 'Asha Edited');
      expect(r.history.first.attachmentPaths.first, storage(u1));
    });

    test('SWAP-RS-41 GAP until attachment_swaps (b): a stale whole-row save AFTER the swap '
        'restores the local path (characterization of fed74ca)', () async {
      final stale = patient(name: 'Asha Stale'); // built before the swap
      expect(await swapA(), isTrue);
      await db.updatePatient(stale);
      final r = (await db.fetchPatientsStrict()).single;
      expect(r.name, 'Asha Stale');
      expect(r.history.first.attachmentPaths.first, localA(u1),
          reason: 'fed74ca: a stale whole-row save brings the local path back; '
              '(b) attachment_swaps will rewrite it to the Storage path. Flip then.');
    });
  });
}
