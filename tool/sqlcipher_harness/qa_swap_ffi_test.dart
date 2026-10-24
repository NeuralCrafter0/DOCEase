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
// Failing-first (security L-2 on 3227338): QA_FAILING_FIRST=true in the env.
final bool _ff = Platform.environment['QA_FAILING_FIRST'] == 'true';
Object? get _ffL2 => _ff
    ? null
    : 'failing-first (L-2 removed photo comes back): set QA_FAILING_FIRST=true until '
        '#10 drops a mapping on a local save without its key or Storage path';
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

    test('SWAP-RS-41 (flipped on 3227338) a stale whole-row save AFTER the swap keeps the '
        'Storage path and the stale save\'s other edits', () async {
      final stale = patient(name: 'Asha Stale'); // built before the swap
      expect(await swapA(), isTrue);
      await db.updatePatient(stale);
      final r = (await db.fetchPatientsStrict()).single;
      expect(r.name, 'Asha Stale');
      expect(r.history.map((v) => v.attachmentPaths).toList(), [
        [storage(u1), oldStorage, localA(u2)],
        [storage(u1)],
      ]);
      expect(await db.referencedAttachmentKeys(), isNot(contains('attachments/$u1.jpg')));
    });
  });

  group('3227338 attachment_swaps (real SQLCipher)', () {
    Future<List<Map<String, Object?>>> swaps() =>
        opener.last!.query('attachment_swaps', orderBy: 'patient_id, local_key');
    Future<bool> hasSwapsTable() async => (await opener.last!.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='attachment_swaps'"))
        .isNotEmpty;

    test('SWQ-QA-01 swap records (patient, local key) -> Storage path in the same write', () async {
      expect(await swaps(), isEmpty);
      expect(await swapA(), isTrue);
      final m = await swaps();
      expect(m, hasLength(1));
      expect(m.single['patient_id'], 'p1');
      expect(m.single['local_key'], 'attachments/$u1.jpg');
      expect(m.single['storage_path'], storage(u1));
    });

    test('SWQ-QA-02 failed swaps (false / ArgumentError) record no mapping', () async {
      expect(await swapA(pid: 'p404'), isFalse);
      await expectLater(swapA(to: storage(u1, ext: 'gif')), throwsArgumentError);
      expect(await swaps(), isEmpty);
    });

    test('SWQ-QA-03 local insertPatient re-applies the mapping; returned version == stored row',
        () async {
      expect(await swapA(), isTrue);
      final v = await db.insertPatient(patient(name: 'Re-inserted')); // stale L copy
      final r = await row('p1');
      expect('${r['updated_at']}', v, reason: 'returned version is the stored row');
      final got = await pathsOf('p1');
      expect(got.first.first, storage(u1));
      expect(got[1], [storage(u1)]);
      expect((await db.fetchPatientsStrict()).single.name, 'Re-inserted');
    });

    test('SWQ-QA-04 cloud apply is never rewritten (cloud copy wins on a synced row)', () async {
      expect(await swapA(), isTrue);
      await markClean('p1');
      final cloud = Patient(
          id: 'p1',
          name: 'Cloud',
          age: '30',
          gender: 'Female',
          phone: '+910000000000',
          updatedAt: '${DateTime.now().millisecondsSinceEpoch + 100000}',
          history: [visit('v1', [localA(u1)])]);
      expect(await db.applyCloudPatient(cloud), isTrue, reason: 'precondition: applied');
      expect((await pathsOf('p1')).single, [localA(u1)],
          reason: 'cloud merges must not consult attachment_swaps');
      expect(await swaps(), hasLength(1), reason: 'cloud apply leaves the mapping');
    });

    test('SWQ-QA-05 the mapping is per patient: same local key in another patient is kept', () async {
      expect(await swapA(), isTrue);
      await db.insertPatient(patient(id: 'p2', history: [visit('v1', [localA(u1)])]));
      expect((await pathsOf('p2')).single, [localA(u1)]);
    });

    test('SWQ-QA-06 a tampered mapping (path outside this owner/patient) is ignored', () async {
      await opener.last!.insert('attachment_swaps', {
        'patient_id': 'p1',
        'local_key': 'attachments/$u1.jpg',
        'storage_path': storage(u1, uid: uidB),
        'swapped_at': DateTime.now().millisecondsSinceEpoch,
      });
      await db.updatePatient(patient(name: 'Tamper'));
      expect((await pathsOf('p1')).first.first, localA(u1));
    });

    test('SWQ-QA-07 a photo removed in the stale copy is not brought back', () async {
      expect(await swapA(), isTrue);
      await db.updatePatient(patient(history: [visit('v1', [oldStorage]), visit('v2', const [])]));
      expect(await pathsOf('p1'), [
        [oldStorage],
        <String>[]
      ]);
    });

    test('SWQ-QA-08 scans ignore the mapping', () async {
      expect(await swapA(), isTrue);
      await db.updatePatient(patient(history: [visit('v1', [localA(u2)])]));
      final k = await db.referencedAttachmentKeys();
      expect(k, isNot(contains('attachments/$u1.jpg')));
      expect(k, contains('attachments/$u2.jpg'));
      expect(await swaps(), hasLength(1));
    });

    test('SWQ-QA-09 cleared with the patient delete (tombstone)', () async {
      expect(await swapA(), isTrue);
      await db.markPendingDelete('p1');
      expect(await swaps(), isEmpty);
    });

    test('SWQ-QA-10 pruned on open after 30 days (31d gone, 29d kept)', () async {
      final now = DateTime.now();
      for (final (k, d) in [('old', 31), ('young', 29)]) {
        await opener.last!.insert('attachment_swaps', {
          'patient_id': 'p1',
          'local_key': 'attachments/$k.jpg',
          'storage_path': 'clinical_attachments/doctorA/p1/$k.jpg',
          'swapped_at': now.subtract(Duration(days: d)).millisecondsSinceEpoch,
        });
      }
      await db.close();
      await db.openFor(uidA);
      expect((await swaps()).map((r) => r['local_key']), ['attachments/young.jpg']);
    });

    test('SWQ-QA-11 migration: an existing v2 DB without the table gets it on open; data intact',
        () async {
      await opener.last!.execute('DROP TABLE attachment_swaps'); // a fed74ca-era v2 file
      final ver = (await opener.last!.rawQuery('PRAGMA user_version')).first.values.first;
      await db.close();
      await db.openFor(uidA);
      expect(await hasSwapsTable(), isTrue);
      expect((await opener.last!.rawQuery('PRAGMA user_version')).first.values.first, ver);
      expect((await db.fetchPatientsStrict()).single.name, 'Asha');
      expect(await swapA(), isTrue);
      await db.updatePatient(patient(name: 'After migration'));
      expect((await pathsOf('p1')).first.first, storage(u1));
    });

    test('SWQ-QA-12 migration: v1 -> v2 upgrade creates attachment_swaps', () async {
      await db.close();
      final dir = Directory(p.join(tmp.path, 'v1'))..createSync();
      final k1 = MemKeys();
      final v1 = DatabaseHelper(
          keyStore: k1, opener: opener, databasesPath: () async => dir.path, schemaVersion: 1);
      await v1.openFor(uidA);
      expect(await hasSwapsTable(), isFalse, reason: 'precondition: v1 has no table');
      await v1.close();
      db = DatabaseHelper(keyStore: k1, opener: opener, databasesPath: () async => dir.path);
      await db.openFor(uidA);
      expect(await hasSwapsTable(), isTrue);
      await db.insertPatient(patient());
      expect(await swapA(), isTrue);
      await db.updatePatient(patient(name: 'v1 upgraded'));
      expect((await pathsOf('p1')).first.first, storage(u1));
    });
  });

  group('L-2 removed photo must not come back (3227338)', () {
    Future<List<Map<String, Object?>>> swaps() =>
        opener.last!.query('attachment_swaps', orderBy: 'patient_id, local_key');
    List<String> flat(List<List<String>> x) => [for (final v in x) ...v];
    // The doctor's refreshed copy after the swap, with the uploaded photo
    // removed from every visit.
    Patient removed() => patient(history: [
          visit('v1', [oldStorage, localA(u2)]),
          visit('v2', const []),
        ]);

    test('RM-01 remove uploaded photo, then a pre-upload copy is saved: photo stays removed '
        '(and is not in the row that gets pushed)', () async {
      final preUpload = patient(name: 'Pre-upload'); // holds L
      expect(await swapA(), isTrue);
      await db.updatePatient(removed());
      expect(flat(await pathsOf('p1')), isNot(contains(storage(u1))), reason: 'precondition');
      await db.updatePatient(preUpload);
      final got = flat(await pathsOf('p1'));
      // ignore: avoid_print
      print('RM-01 observed: $got mappings=${(await swaps()).length}');
      expect(got, isNot(contains(storage(u1))), reason: 'REMOVED PHOTO CAME BACK via mapping');
      final pushed = (await db.dirtyPatientsStrict()).single;
      expect([for (final v in pushed.history) ...v.attachmentPaths], isNot(contains(storage(u1))),
          reason: 'the revived Storage reference would sync');
    }, skip: _ffL2);

    test('RM-02 the removal save drops the mapping in the same transaction', () async {
      expect(await swapA(), isTrue);
      await db.updatePatient(removed());
      expect(await swaps(), isEmpty);
    }, skip: _ffL2);

    test('RM-03 same through a local insertPatient of the pre-upload copy', () async {
      final preUpload = patient(name: 'Pre-upload');
      expect(await swapA(), isTrue);
      await db.insertPatient(removed());
      await db.insertPatient(preUpload);
      expect(flat(await pathsOf('p1')), isNot(contains(storage(u1))));
    }, skip: _ffL2);

    test('RM-04 guard: a save that still holds S keeps the mapping (stale L later rewritten)',
        () async {
      final preUpload = patient(name: 'Pre-upload');
      expect(await swapA(), isTrue);
      final refreshed = (await db.fetchPatientsStrict()).single;
      await db.updatePatient(Patient(
          id: 'p1', name: 'Edited', age: refreshed.age, gender: refreshed.gender,
          phone: refreshed.phone, history: refreshed.history));
      expect(await swaps(), hasLength(1));
      await db.updatePatient(preUpload);
      expect((await pathsOf('p1')).first.first, storage(u1));
    });

    test('RM-05 guard: a save that still holds L keeps the mapping and is rewritten', () async {
      expect(await swapA(), isTrue);
      await db.updatePatient(patient(name: 'Stale'));
      expect(await swaps(), hasLength(1));
      expect(flat(await pathsOf('p1')).where((e) => e == storage(u1)), hasLength(2));
    });

    test('RM-06 guard: removed from one visit only (S still in the other) keeps the mapping',
        () async {
      expect(await swapA(), isTrue);
      await db.updatePatient(patient(history: [
        visit('v1', [oldStorage, localA(u2)]),
        visit('v2', [storage(u1)]),
      ]));
      expect(await swaps(), hasLength(1));
    });

    test('RM-07 guard: removing p1\'s photo leaves p2\'s mapping alone', () async {
      await db.insertPatient(patient(id: 'p2'));
      expect(await swapA(), isTrue);
      expect(await swapA(pid: 'p2'), isTrue);
      await db.updatePatient(removed());
      expect((await swaps()).where((m) => m['patient_id'] == 'p2'), hasLength(1));
    });

    test('RM-08 guard: a cloud apply without the key never drops the mapping', () async {
      expect(await swapA(), isTrue);
      await markClean('p1');
      final cloud = Patient(
          id: 'p1', name: 'Cloud', age: '30', gender: 'Female', phone: '+910000000000',
          updatedAt: '${DateTime.now().millisecondsSinceEpoch + 100000}',
          history: [visit('v1', [oldStorage])]);
      expect(await db.applyCloudPatient(cloud), isTrue);
      expect(await swaps(), hasLength(1));
    });
  });

  group('markSynced backstop, pinned on 3227338 (compare-and-set on updated_at + dirty)', () {
    test('MS-01 a stale updatedAt (the pushed in-memory copy\'s) is refused; row stays dirty, '
        'counter unchanged', () async {
      final memCopy = (await db.fetchPatientsStrict()).single; // what the provider holds
      expect(await swapA(), isTrue); // stored row moves on
      final before = await counter();
      expect(await db.markSynced('p1', memCopy.updatedAt!), isFalse);
      expect((await row('p1'))['sync_state'], isNot(0), reason: 'must stay dirty');
      expect((await db.dirtyPatientsStrict()).map((x) => x.id), ['p1']);
      expect(await counter(), before);
    });

    test('MS-02 the stored updatedAt marks clean and decrements once', () async {
      final before = await counter();
      await markClean('p1');
      expect(await counter(), before! - 1);
      expect(await db.dirtyPatientsStrict(), isEmpty);
    });

    test('MS-03 already clean: refused, no second decrement', () async {
      await markClean('p1');
      final before = await counter();
      expect(await db.markSynced('p1', '${(await row('p1'))['updated_at']}'), isFalse);
      expect(await counter(), before);
    });

    test('MS-04 non-numeric / empty version refused', () async {
      expect(await db.markSynced('p1', 'abc'), isFalse);
      expect(await db.markSynced('p1', ''), isFalse);
      expect((await db.dirtyPatientsStrict()).map((x) => x.id), ['p1']);
    });

    test('MS-05 missing row and tombstoned row refused', () async {
      final v = '${(await row('p1'))['updated_at']}';
      expect(await db.markSynced('p404', v), isFalse);
      await db.markPendingDelete('p1');
      expect(await db.markSynced('p1', v), isFalse);
    });

    test('MS-06 INFO today: after a rewritten save the RETURNED version is accepted even though '
        'the caller pushed different content (DB cannot tell; backstop needs the pushed row\'s '
        'updatedAt)', () async {
      expect(await swapA(), isTrue);
      final memCopy = patient(name: 'Stale'); // pushed copy holds L
      final returned = await db.updatePatient(memCopy);
      expect((await pathsOf('p1')).first.first, storage(u1), reason: 'stored row was rewritten');
      // Backstop with the pushed copy's updatedAt (none/older) -> refused:
      expect(await db.markSynced('p1', memCopy.updatedAt ?? ''), isFalse);
      // Today: the returned version is accepted (row marked clean). Flip if
      // #10 adopts "refuse a rewritten version until the caller re-reads".
      expect(await db.markSynced('p1', returned!), isTrue);
    });
  });
}
