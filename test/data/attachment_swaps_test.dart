// Host unit tests for attachment_swaps: the pure rewrite applied to local
// whole-row saves, and the fake's contract (stale saves keep the Storage
// path, other patients untouched, delete clears mappings, cloud merges are
// never rewritten). Real SQLCipher round trips (table in fresh v2 and
// v1 -> v2, transactions, prune on open, scans ignoring mappings) are
// SWQ-* in integration_test/support/db_suite.dart.
import 'dart:convert';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_fakes.dart';

const ownerA = '82c10fd937b1ded72e4f454cb41fcc15'; // sha256('doctorA')[:32]
const uuid = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
const android = '/data/user/0/com.docease.app/files';
const local = '$android/attachments/$ownerA/$uuid.jpg';
const newPhoto = '$android/attachments/$ownerA/new.jpg';
const storage = 'clinical_attachments/doctorA/p1/$uuid.jpg';
const localKey = 'attachments/$uuid.jpg';

Map<String, Object?> visit(String id, List<Object?>? paths,
        {String diagnosis = 'd'}) =>
    {
      'id': id, 'date': '2026-01-01T00:00:00.000', 'visitType': 'Routine',
      'symptoms': 's-$id', 'diagnosis': diagnosis, 'prescription': 'rx',
      'notes': null, 'attachmentPaths': paths, 'bp': '120/80',
    };

Patient patientWith(String id, List<List<String>> visits,
        {String diagnosis = 'd'}) =>
    Patient.fromJson({
      'id': id, 'name': 'Asha', 'age': '34', 'gender': 'Female',
      'phone': '+91999', 'relation': 'Self',
      'history': [
        for (final (i, paths) in visits.indexed)
          visit('v$i', paths, diagnosis: diagnosis),
      ],
    });

(String, int) apply(Object history, Map<String, String> swaps,
        {String uid = 'doctorA', String patient = 'p1'}) =>
    AttachmentRefs.applySwapsToHistoryJson(
        history is String ? history : jsonEncode(history), swaps,
        uid: uid, patientId: patient);

List<List<String>> pathsOf(Patient p) =>
    [for (final v in p.history) v.attachmentPaths];

void main() {
  group('applySwapsToHistoryJson', () {
    test('rewrites every entry keying to a recorded local key, including '
        'aliases and repeats across visits; keeps everything else', () {
      final hist = [
        visit('a', [local, newPhoto, 'https://x/y.jpg', '']),
        visit('b', ['file://localhost$local',
            '/data/data/com.docease.app/files/attachments/$ownerA/$uuid.jpg']),
        visit('c', null),
        {'id': 'd', 'unknownKey': 1},
      ];
      final (out, n) = apply(hist, {localKey: storage});
      expect(n, 3);
      final decoded = jsonDecode(out) as List;
      expect(decoded[0]['attachmentPaths'],
          [storage, newPhoto, 'https://x/y.jpg', '']);
      expect(decoded[1]['attachmentPaths'], [storage, storage]);
      expect(decoded[2], hist[2]);
      expect(decoded[3], hist[3]);
      for (final f in ['id', 'date', 'symptoms', 'diagnosis', 'bp']) {
        expect(decoded[0][f], hist[0][f], reason: f);
      }
    });

    test('nothing recorded, nothing keying, or no valid mapping: the input '
        'string is returned unchanged', () {
      final s = jsonEncode([visit('a', [local, newPhoto])]);
      expect(apply(s, {}), (s, 0));
      expect(apply(s, {'attachments/other.jpg': storage}), (s, 0));
      expect(apply(jsonEncode([visit('a', [newPhoto])]), {localKey: storage}).$2,
          0);
    });

    test('a mapping whose path left the owner/patient folder is ignored', () {
      final s = jsonEncode([visit('a', [local])]);
      for (final bad in [
        'clinical_attachments/doctorA/p2/$uuid.jpg',
        'clinical_attachments/doctorB/p1/$uuid.jpg',
        'clinical_attachments/doctorA/p1/../p2/$uuid.jpg',
        'doctor_profiles/doctorA/$uuid.jpg',
        'https://example.com/$uuid.jpg',
        local,
      ]) {
        expect(apply(s, {localKey: bad}), (s, 0), reason: bad);
      }
      // The same mapping applies only to the patient it was recorded for.
      expect(apply(s, {localKey: storage}, patient: 'p2'), (s, 0));
      expect(apply(s, {localKey: storage}, uid: 'doctorB'), (s, 0));
    });

    test('never throws on a structure it does not expect', () {
      for (final s in ['not json', '{"a":1}', '[1, "x", null]',
          jsonEncode([{'attachmentPaths': 'notalist'}])]) {
        expect(apply(s, {localKey: storage}), (s, 0), reason: s);
      }
    });
  });

  group('FakeLocalDatabase mappings', () {
    Future<FakeLocalDatabase> swapped() async {
      final db = FakeLocalDatabase();
      db.rows['p1'] = patientWith('p1', [[local, newPhoto]]);
      db.dirty['p1'] = false;
      expect(
          await db.swapAttachmentPath(
              expectedOwner: 'doctorA', patientId: 'p1',
              localPath: local, storagePath: storage),
          isTrue);
      expect(db.swaps, {'p1': {localKey: storage}});
      return db;
    }

    test('a stale updatePatient / insertPatient keeps the Storage path',
        () async {
      final db = await swapped();
      final stale = patientWith('p1', [[local, newPhoto]]);
      expect(await db.updatePatient(stale), isNotNull);
      expect(pathsOf(db.rows['p1']!), [[storage, newPhoto]]);
      expect(await db.insertPatient(stale), isNotNull);
      expect(pathsOf(db.rows['p1']!), [[storage, newPhoto]]);
    });

    test('a stale save that changed a diagnosis keeps both', () async {
      final db = await swapped();
      expect(
          await db.updatePatient(
              patientWith('p1', [[local]], diagnosis: 'Dengue, revised')),
          isNotNull);
      expect(pathsOf(db.rows['p1']!), [[storage]]);
      expect(db.rows['p1']!.history.single.diagnosis, 'Dengue, revised');
      expect(await db.unsyncedCount(), const UnsyncedCount.known(1));
    });

    test('a different patient is not affected', () async {
      final db = await swapped();
      expect(await db.insertPatient(patientWith('p2', [[local]])), isNotNull);
      expect(pathsOf(db.rows['p2']!), [[local]]);
    });

    test('deleting the patient clears its mappings', () async {
      final db = await swapped();
      await db.markPendingDelete('p1');
      expect(db.swaps, isEmpty);
      expect(await db.insertPatient(patientWith('p1', [[local]])), isNotNull);
      expect(pathsOf(db.rows['p1']!), [[local]]);
    });

    test('a cloud merge is never rewritten', () async {
      final db = await swapped();
      db.dirty['p1'] = false;
      final cloud = patientWith('p1', [[local]]);
      expect(await db.applyCloudPatient(cloud), isTrue);
      expect(pathsOf(db.rows['p1']!), [[local]]);
      db.dirty['p1'] = false;
      expect(await db.insertPatient(cloud, fromCloud: true), isNotNull);
      expect(pathsOf(db.rows['p1']!), [[local]]);
    });
  });

  group('security regression: edit-details stale copy', () {
    test('after a swap, a details save from the stale copy keeps S, the new '
        'name/phone and every visit; the scan drops L', () async {
      final db = FakeLocalDatabase();
      await db.insertPatient(patientWith('p1', [[local], [newPhoto]]));
      final stale = db.rows['p1']!; // the details screen's copy
      expect(
          await db.swapAttachmentPath(
              expectedOwner: 'doctorA', patientId: 'p1',
              localPath: local, storagePath: storage),
          isTrue);
      final edited = Patient.fromJson(
          {...stale.toJson(), 'name': 'Asha Renamed', 'phone': '+910000000001'});
      expect(edited.history.first.attachmentPaths, [local]);
      expect(await db.updatePatient(edited), isNotNull);
      final stored = db.rows['p1']!;
      expect(stored.name, 'Asha Renamed');
      expect(stored.phone, '+910000000001');
      expect(pathsOf(stored), [[storage], [newPhoto]]);
      expect(stored.history.map((v) => v.id), stale.history.map((v) => v.id));
      final keys = await db.referencedAttachmentKeys();
      expect(keys, isNot(contains(localKey)));
      expect(keys, {'attachments/new.jpg'});
    });

    test('characterization: a copy captured before the visit existed drops '
        'the visit (backend details-save change, not fixed in the DB)',
        () async {
      final db = FakeLocalDatabase();
      await db.insertPatient(patientWith('p1', []));
      final stale = db.rows['p1']!;
      await db.updatePatient(patientWith('p1', [[local]]));
      expect(
          await db.swapAttachmentPath(
              expectedOwner: 'doctorA', patientId: 'p1',
              localPath: local, storagePath: storage),
          isTrue);
      await db.updatePatient(
          Patient.fromJson({...stale.toJson(), 'name': 'Asha Renamed'}));
      expect(db.rows['p1']!.name, 'Asha Renamed');
      expect(db.rows['p1']!.history, isEmpty);
      expect(await db.referencedAttachmentKeys(), isEmpty);
    });
  });

  test('DatabaseHelper prunes mappings after 30 days', () {
    expect(DatabaseHelper.attachmentSwapRetention, const Duration(days: 30));
  });
}
