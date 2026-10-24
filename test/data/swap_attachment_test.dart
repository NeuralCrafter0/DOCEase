// Host unit tests for swapAttachmentPath: argument and Storage-layout
// validation, key-based matching over the raw stored history, the fake's
// contract, and DatabaseHelper failing closed without an open database.
// Real SQLCipher round trips (concurrent edits through the row queue,
// tombstones, counter, keyed scan) are SWP-* in
// integration_test/support/db_suite.dart.
import 'dart:convert';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_fakes.dart';

const ownerA = '82c10fd937b1ded72e4f454cb41fcc15'; // sha256('doctorA')[:32]
const ownerB = 'd19d2eb1dc5a8cab475fa8b4ee958454'; // sha256('doctorB')[:32]
const uuid = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
const android = '/data/user/0/com.docease.app/files';
const androidAlias = '/data/data/com.docease.app/files';
const local = '$android/attachments/$ownerA/$uuid.jpg';
const storage = 'clinical_attachments/doctorA/p1/$uuid.jpg';
const marker = 'ZZ-SWAP-MARKER-3d7a';

Matcher readFails(DbReadFailure reason) =>
    throwsA(isA<DbReadException>().having((e) => e.reason, 'reason', reason));

Matcher argFails(String name) =>
    throwsA(isA<ArgumentError>().having((e) => e.name, 'name', name));

String key(String localPath, {String owner = 'doctorA', String patient = 'p1'}) =>
    AttachmentRefs.swapKeyFor(
        expectedOwner: owner,
        patientId: patient,
        localPath: localPath,
        storagePath: 'clinical_attachments/$owner/$patient/$uuid.jpg');

Map<String, Object?> visit(String id, List<Object?>? paths,
        {Map<String, Object?> extra = const {}}) =>
    {
      'id': id, 'date': '2026-01-0${id.length}T00:00:00.000',
      'visitType': 'Routine', 'symptoms': 's-$id', 'diagnosis': 'd',
      'prescription': 'rx', 'notes': null, 'attachmentPaths': paths,
      'bp': '120/80', ...extra,
    };

String? swap(Object history, {String k = 'attachments/$uuid.jpg'}) =>
    AttachmentRefs.swapInHistoryJson(
        history is String ? history : jsonEncode(history),
        key: k,
        ownerFolderName: ownerA,
        storagePath: storage);

void main() {
  group('isPatientStoragePath (uploader layout)', () {
    bool ok(String p, {String uid = 'doctorA', String patient = 'p1'}) =>
        AttachmentRefs.isPatientStoragePath(p, uid: uid, patientId: patient);

    test('exactly clinical_attachments/<uid>/<patientId>/<file>', () {
      for (final ext in ['jpg', 'jpeg', 'png', 'webp']) {
        expect(ok('clinical_attachments/doctorA/p1/$uuid.$ext'), isTrue);
      }
      expect(ok('clinical_attachments/doctorA/p1/a_B-9.jpg'), isTrue);
    });

    test('other patient, other uid, traversal and malformed are rejected', () {
      for (final bad in [
        'clinical_attachments/doctorA/p2/$uuid.jpg', // other patient
        'clinical_attachments/doctorB/p1/$uuid.jpg', // other uid
        'clinical_attachments/doctorA/../doctorB/p1/$uuid.jpg',
        'clinical_attachments/doctorA/p1/../$uuid.jpg',
        'clinical_attachments/doctorA/p1/..',
        'clinical_attachments/doctorA/./p1/$uuid.jpg',
        'clinical_attachments/doctorA/p1/x/$uuid.jpg', // extra segment
        'clinical_attachments//p1/$uuid.jpg',
        'clinical_attachments/doctorA//$uuid.jpg',
        'clinical_attachments/doctorA/p1/',
        '/clinical_attachments/doctorA/p1/$uuid.jpg',
        'clinical_attachments/doctorA/p1/$uuid.jpg/',
        'doctor_profiles/doctorA/$uuid.jpg',
        'gs://bucket/clinical_attachments/doctorA/p1/$uuid.jpg',
        'https://firebasestorage.googleapis.com/v0/b/x/o/clinical_attachments%2FdoctorA%2Fp1%2F$uuid.jpg',
        'clinical_attachments/doctorA/p1/$uuid.gif',
        'clinical_attachments/doctorA/p1/a b.jpg',
        'clinical_attachments/doctorA/p1/${'a' * 129}.jpg',
        'clinical_attachments/doctorA/p1/%2e%2e.jpg',
        'Clinical_attachments/doctorA/p1/$uuid.jpg',
        '',
      ]) {
        expect(ok(bad), isFalse, reason: bad);
      }
      // A uid/patient that is itself a path trick never matches.
      expect(ok('clinical_attachments/../p1/$uuid.jpg', uid: '..'), isFalse);
      expect(ok('clinical_attachments/doctorA/./$uuid.jpg', patient: '.'),
          isFalse);
      expect(ok('clinical_attachments//p1/$uuid.jpg', uid: ''), isFalse);
    });
  });

  group('swapKeyFor (argument validation)', () {
    test('aliased local forms give the same visit-photo key', () {
      final enc = Uri.file(local).path;
      for (final p in [
        local,
        '$androidAlias/attachments/$ownerA/$uuid.jpg',
        'file://$enc',
        'file://localhost$enc',
      ]) {
        expect(key(p), 'attachments/$uuid.jpg', reason: p);
      }
    });

    test('bad arguments throw ArgumentError naming only the parameter', () {
      final cases = <(String, String, String, String, String)>[
        ('', 'p1', local, 'clinical_attachments//p1/$uuid.jpg', 'expectedOwner'),
        ('doctorA', '', local, 'clinical_attachments/doctorA//$uuid.jpg', 'patientId'),
        ('doctorA', 'p1', local, 'clinical_attachments/doctorA/p2/$uuid.jpg', 'storagePath'),
        ('doctorA', 'p1', local, 'clinical_attachments/doctorB/p1/$uuid.jpg', 'storagePath'),
        ('doctorA', 'p1', local, 'clinical_attachments/doctorA/p1/../$marker.jpg', 'storagePath'),
        ('doctorA', 'p1', local, 'https://example.com/$marker.jpg', 'storagePath'),
        // Not a local photo of this owner (or not a visit photo):
        ('doctorA', 'p1', '$android/attachments/$ownerB/$marker.jpg', storage, 'localPath'),
        ('doctorA', 'p1', '$android/profile/$ownerA/avatar_$marker.png', storage, 'localPath'),
        ('doctorA', 'p1', '/storage/emulated/0/DCIM/$marker.jpg', storage, 'localPath'),
        ('doctorA', 'p1', 'file://evil$android/attachments/$ownerA/$marker.jpg', storage, 'localPath'),
        ('doctorA', 'p1', '$android/attachments/$ownerA/../$ownerA/$marker.jpg', storage, 'localPath'),
        ('doctorA', 'p1', 'clinical_attachments/doctorA/p1/$marker.jpg', storage, 'localPath'),
        ('doctorA', 'p1', 'https://x.example/$marker.jpg', storage, 'localPath'),
        ('doctorA', 'p1', '', storage, 'localPath'),
      ];
      for (final (owner, patient, lp, sp, name) in cases) {
        try {
          AttachmentRefs.swapKeyFor(
              expectedOwner: owner,
              patientId: patient,
              localPath: lp,
              storagePath: sp);
          fail('expected ArgumentError for $name: $lp / $sp');
        } on ArgumentError catch (e) {
          expect(e.name, name, reason: '$lp / $sp');
          expect(e.toString(), isNot(contains(marker)));
          expect(e.toString(), isNot(contains(uuid)));
          expect(e.toString(), isNot(contains('doctorA')));
        }
      }
    });
  });

  group('swapInHistoryJson', () {
    test('the path in two visits: both swapped; aliases swapped too', () {
      final enc = Uri.file(local).path;
      final history = [
        visit('v1', [local, 'clinical_attachments/doctorA/p1/old.jpg']),
        visit('v22', ['file://localhost$enc']),
        visit('v333', ['$androidAlias/attachments/$ownerA/$uuid.jpg', 'file://$enc']),
      ];
      final out = jsonDecode(swap(history)!) as List;
      expect(out[0]['attachmentPaths'],
          [storage, 'clinical_attachments/doctorA/p1/old.jpg']);
      expect(out[1]['attachmentPaths'], [storage]);
      expect(out[2]['attachmentPaths'], [storage, storage]);
    });

    test('every other field, visit and entry is kept exactly as stored', () {
      final other = '$android/attachments/$ownerA/other.jpg';
      final history = [
        visit('v1', [other, ''], extra: {'zzUnknown': {'k': [1, 2.5]}}),
        visit('v22', [
          '/storage/emulated/0/DCIM/legacy.jpg', // cannot be keyed: kept
          local,
          '$android/attachments/$ownerB/$uuid.jpg', // other owner: kept
          'https://x.example/a.jpg',
        ], extra: {'aFirst': true, 'notes': 'n'}),
        visit('v333', null),
        {'id': 'v4444', 'date': '2026-01-04T00:00:00.000'}, // no paths key
      ];
      final out = jsonDecode(swap(history)!) as List;
      expect(out[0], history[0]);
      expect(out[2], history[2]);
      expect(out[3], history[3]);
      final v2 = Map<String, Object?>.from(history[1] as Map);
      v2['attachmentPaths'] = [
        '/storage/emulated/0/DCIM/legacy.jpg',
        storage,
        '$android/attachments/$ownerB/$uuid.jpg',
        'https://x.example/a.jpg',
      ];
      expect(out[1], v2);
      // Byte-level: untouched visits re-encode to the same JSON, key order
      // included.
      expect(jsonEncode(out[0]), jsonEncode(history[0]));
      expect((out[1] as Map).keys.toList(), (history[1] as Map).keys.toList());
    });

    test('no entry with that key (photo removed): null', () {
      expect(swap([visit('v1', ['$android/attachments/$ownerA/other.jpg'])]),
          isNull);
      expect(swap([visit('v1', null), visit('v22', [])]), isNull);
      expect(swap(<Object?>[]), isNull);
      expect(swap([visit('v1', [local])], k: 'attachments/else.jpg'), isNull);
    });

    test('a corrupt history throws FormatException with no data', () {
      for (final bad in <String>[
        '{not json $marker',
        '{"id":"$marker"}',
        '"$marker"',
        jsonEncode([marker]),
        jsonEncode([visit('v1', [local]), 'x']),
        jsonEncode([{'attachmentPaths': marker}]),
        jsonEncode([{'attachmentPaths': [local, 7]}]),
        jsonEncode([{'attachmentPaths': [null]}]),
      ]) {
        try {
          swap(bad);
          fail('expected FormatException: $bad');
        } on FormatException catch (e) {
          expect(e.toString(), isNot(contains(marker)));
          expect(e.source, isNull);
        }
      }
    });
  });

  group('DatabaseHelper without an open database', () {
    late Directory dir;
    late MemoryKeyStore keys;
    late RecordingOpener opener;
    DatabaseHelper helper() => DatabaseHelper(
        keyStore: keys, opener: opener, databasesPath: () async => dir.path);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('docease_swap_');
      keys = MemoryKeyStore();
      opener = RecordingOpener();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<bool> run(DatabaseHelper h,
            {String owner = 'doctorA', String sp = storage}) =>
        h.swapAttachmentPath(
            expectedOwner: owner,
            patientId: 'p1',
            localPath: local,
            storagePath: sp);

    test('never opened: throws notOpen (never false), opens nothing',
        () async {
      final h = helper();
      await expectLater(run(h), readFails(DbReadFailure.notOpen));
      expect(opener.calls, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('open failed: throws notOpen', () async {
      keys.failRead = true;
      final h = helper();
      await expectLater(h.openFor('doctorA'), throwsA(isA<DbOpenException>()));
      await expectLater(run(h), readFails(DbReadFailure.notOpen));
    });

    test('bad arguments are an ArgumentError future, checked first', () async {
      final h = helper();
      await expectLater(run(h, sp: 'clinical_attachments/doctorB/p1/$uuid.jpg'),
          argFails('storagePath'));
      await expectLater(
          h.swapAttachmentPath(
              expectedOwner: 'doctorA',
              patientId: 'p1',
              localPath: '$android/attachments/$ownerB/$uuid.jpg',
              storagePath: storage),
          argFails('localPath'));
    });
  });

  group('FakeLocalDatabase.swapAttachmentPath', () {
    Patient patientWith(String id, List<List<String>> visits,
            {String name = 'Asha'}) =>
        Patient.fromJson({
          'id': id, 'name': name, 'age': '34', 'gender': 'Female',
          'phone': '+91999', 'relation': 'Self',
          'history': [
            for (final (i, paths) in visits.indexed)
              visit('v${'x' * (i + 1)}', paths),
          ],
        });

    Future<bool> run(FakeLocalDatabase db,
            {String owner = 'doctorA', String patient = 'p1'}) =>
        db.swapAttachmentPath(
            expectedOwner: owner,
            patientId: patient,
            localPath: local,
            storagePath: 'clinical_attachments/$owner/$patient/$uuid.jpg');

    test('swaps by key, marks dirty once, keeps the rest', () async {
      final db = FakeLocalDatabase();
      db.rows['p1'] = patientWith('p1', [[local], ['file://localhost$local', 'keep.jpg']]);
      db.dirty['p1'] = false;
      expect(await db.unsyncedCount(), const UnsyncedCount.known(0));
      expect(await run(db), isTrue);
      final p = db.rows['p1']!;
      expect(p.history[0].attachmentPaths, [storage]);
      expect(p.history[1].attachmentPaths, [storage, 'keep.jpg']);
      expect(p.name, 'Asha');
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
      expect(p.updatedAt, db.versions['p1']);
      // Already swapped: the photo is gone, false, nothing changes.
      final v = db.versions['p1'];
      expect(await run(db), isFalse);
      expect(db.versions['p1'], v);
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
    });

    test('missing or tombstoned patient: false', () async {
      final db = FakeLocalDatabase();
      expect(await run(db), isFalse);
      db.rows['p1'] = patientWith('p1', [[local]]);
      await db.markPendingDelete('p1');
      expect(await run(db), isFalse);
    });

    test('wrong or no owner: notOpen; unparseable row: unreadableRow',
        () async {
      final db = FakeLocalDatabase();
      db.rows['p1'] = patientWith('p1', [[local]]);
      await expectLater(run(db, owner: 'doctorB'),
          throwsA(anyOf(isA<ArgumentError>(), isA<DbReadException>())));
      db.state = const DbReady('doctorB');
      await expectLater(run(db), readFails(DbReadFailure.notOpen));
      db.state = const DbOpening('doctorA');
      await expectLater(run(db), readFails(DbReadFailure.notOpen));
      db.state = const DbReady('doctorA');
      db.rows['p2'] = Patient.fromJson({'id': 'p2', 'history': marker});
      await expectLater(
          run(db, patient: 'p2'), readFails(DbReadFailure.unreadableRow));
      expect(db.rows['p1']!.history.single.attachmentPaths, [local]);
    });
  });
}
