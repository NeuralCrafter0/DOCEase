// Host unit tests for fetchPatientStrict (the one-row strict read). The
// real-SQLCipher cases (primary-key lookup, tombstones, a corrupt row, a
// dropped table, parity with fetchPatientsStrict) are FPS-01..03 in
// integration_test/support/db_suite.dart.
import 'dart:convert';
import 'dart:io';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/db_fakes.dart';

Matcher readFails(DbReadFailure reason) =>
    throwsA(isA<DbReadException>().having((e) => e.reason, 'reason', reason));

const marker = 'ZZ-FPS-MARKER-3d9a';

Patient patient(String id, {List<String> paths = const [], Object? history}) =>
    Patient.fromJson({
      'id': id, 'name': 'Asha $id', 'age': '34', 'gender': 'Female',
      'phone': '+91999', 'relation': 'Self',
      'history': history ??
          [
            {
              'id': 'v0', 'date': '2026-10-01T10:00:00.000',
              'visitType': 'Follow-up', 'diagnosis': 'URTI',
              'attachmentPaths': paths,
            },
          ],
    });

/// Same patient: every stored field, visits, attachments and version.
String snapshot(Patient p) =>
    jsonEncode({'p': p.toJson(), 'v': p.updatedAt, 'bad': p.hasParseErrors});

void main() {
  group('DatabaseHelper without an open database', () {
    late Directory dir;
    late MemoryKeyStore keys;
    late RecordingOpener opener;
    DatabaseHelper helper() => DatabaseHelper(
        keyStore: keys, opener: opener, databasesPath: () async => dir.path);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('docease_fps_');
      keys = MemoryKeyStore();
      opener = RecordingOpener();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('never opened: notOpen, nothing opened or created', () async {
      final h = helper();
      await expectLater(
          h.fetchPatientStrict(expectedOwner: 'doctorA', patientId: 'p1'),
          readFails(DbReadFailure.notOpen));
      expect(opener.calls, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('open failed: notOpen', () async {
      keys.failRead = true;
      final h = helper();
      await expectLater(h.openFor('doctorA'), throwsA(isA<DbOpenException>()));
      await expectLater(
          h.fetchPatientStrict(expectedOwner: 'doctorA', patientId: 'p1'),
          readFails(DbReadFailure.notOpen));
      expect(opener.calls, isEmpty);
    });

    test('empty owner or patient id is an ArgumentError, before any read',
        () async {
      final h = helper();
      expect(() => h.fetchPatientStrict(expectedOwner: '', patientId: 'p1'),
          throwsArgumentError);
      expect(() => h.fetchPatientStrict(expectedOwner: 'doctorA', patientId: ''),
          throwsArgumentError);
      expect(opener.calls, isEmpty);
    });

    test('the query is a primary-key lookup that excludes tombstones', () {
      const sql = DatabaseHelper.singlePatientSql;
      expect(sql, contains('FROM patients WHERE id = ?'));
      expect(sql, contains('NOT EXISTS (SELECT 1 FROM pending_deletes '
          'WHERE patient_id = ?)'));
      expect(sql, endsWith('LIMIT 1'));
    });

    test('a row decodes exactly as in the strict list read', () {
      Map<String, Object?> row(String id, Object? history) => {
            'id': id, 'name': 'Asha', 'age': '34', 'gender': 'Female',
            'phone': '+91999', 'relation': null, 'history': history,
            'sync_state': 'dirty', 'updated_at': 7,
          };
      final rows = [
        row('p1', jsonEncode([
          {'id': 'v0', 'date': '2026-10-01T10:00:00.000',
            'attachmentPaths': ['clinical_attachments/doctorA/p1/a.jpg']},
        ])),
        row('p2', '[]'),
      ];
      final all = DatabaseHelper.patientsFromRowsStrict(rows);
      for (final (i, r) in rows.indexed) {
        expect(snapshot(DatabaseHelper.patientsFromRowsStrict([r]).single),
            snapshot(all[i]));
      }
      expect(
          () => DatabaseHelper.patientsFromRowsStrict(
              [row('p3', 'not json $marker')]),
          throwsA(isA<DbReadException>()
              .having((e) => e.reason, 'reason', DbReadFailure.unreadableRow)
              .having((e) => e.toString(), 'message',
                  isNot(contains(marker)))));
    });
  });

  group('FakeLocalDatabase.fetchPatientStrict', () {
    Future<Patient?> get(FakeLocalDatabase db, String id,
            {String owner = 'doctorA'}) =>
        db.fetchPatientStrict(expectedOwner: owner, patientId: id);

    Future<FakeLocalDatabase> seeded() async {
      final db = FakeLocalDatabase();
      await db.insertPatient(
          patient('p1', paths: ['clinical_attachments/doctorA/p1/a.jpg']));
      await db.insertPatient(patient('p2'));
      await db.insertPatient(patient('p3', history: const []));
      return db;
    }

    test('found, not found, tombstoned', () async {
      final db = await seeded();
      final p1 = await get(db, 'p1');
      expect(p1, isNotNull);
      expect(p1!.history.single.attachmentPaths,
          ['clinical_attachments/doctorA/p1/a.jpg']);
      expect(await get(db, 'nope'), isNull);
      await db.markPendingDelete('p2');
      expect(await get(db, 'p2'), isNull);
    });

    test('parity with fetchPatientsStrict for every row', () async {
      final db = await seeded();
      final all = await db.fetchPatientsStrict();
      expect(all, hasLength(3));
      for (final p in all) {
        expect(snapshot((await get(db, p.id))!), snapshot(p));
      }
    });

    test('a corrupt row throws unreadableRow for that patient only',
        () async {
      final db = await seeded();
      db.rows['p2'] = patient('p2', history: 'not json $marker');
      expect(db.rows['p2']!.hasParseErrors, isTrue);
      await expectLater(get(db, 'p2'), readFails(DbReadFailure.unreadableRow));
      expect(await get(db, 'p1'), isNotNull);
      expect(await get(db, 'p3'), isNotNull);
      await expectLater(
          db.fetchPatientsStrict(), readFails(DbReadFailure.unreadableRow));
    });

    test('wrong owner, closed DB, failed read; empty ids rejected', () async {
      final db = await seeded();
      await expectLater(
          get(db, 'p1', owner: 'doctorB'), readFails(DbReadFailure.notOpen));
      expect(() => get(db, ''), throwsArgumentError);
      expect(() => get(db, 'p1', owner: ''), throwsArgumentError);
      db.strictReadFailure = DbReadFailure.readFailed;
      await expectLater(get(db, 'p1'), readFails(DbReadFailure.readFailed));
      db.strictReadFailure = null;
      db.state = const DbOpening('doctorA');
      await expectLater(get(db, 'p1'), readFails(DbReadFailure.notOpen));
    });
  });
}
