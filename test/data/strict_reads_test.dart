// Host unit tests for the strict reads (fetchPatientsStrict,
// dirtyPatientsStrict, pendingDeletesStrict) and DbReadException. Read
// failures on an open real SQLCipher database (dropped table, corrupt row)
// are STR-* in integration_test/support/db_suite.dart.
import 'dart:convert';
import 'dart:io';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_fakes.dart';

Matcher readFails(DbReadFailure reason) =>
    throwsA(isA<DbReadException>().having((e) => e.reason, 'reason', reason));

const marker = 'ZZ-PATIENT-MARKER-5b1e';

Map<String, Object?> row(String id,
        {Object? history = '[]', String name = 'Asha', Object? updatedAt = 1}) =>
    {
      'id': id, 'name': name, 'age': '34', 'gender': 'Female',
      'phone': '+91999', 'relation': null, 'history': history,
      'sync_state': 'dirty', 'updated_at': updatedAt,
    };

void main() {
  group('DbReadException', () {
    test('carries only the reason', () {
      expect(DbReadFailure.values.map((v) => v.name),
          ['notOpen', 'readFailed', 'unreadableRow']);
      for (final r in DbReadFailure.values) {
        final e = DbReadException(r);
        expect(e.toString(), 'DbReadException(${r.name})');
        expect(e, DbReadException(r));
      }
    });
  });

  group('patientsFromRowsStrict', () {
    test('readable rows come back complete, in order; empty stays empty', () {
      final visit = {
        'id': 'v1', 'date': '2026-01-01T00:00:00.000', 'visitType': 'Routine',
        'symptoms': 's', 'diagnosis': 'd', 'prescription': 'rx',
        'attachmentPaths': <String>[],
      };
      final out = DatabaseHelper.patientsFromRowsStrict([
        row('p2', history: jsonEncode([visit])),
        row('p1'),
        row('p3', history: null), // legacy NULL history: no visits
      ]);
      expect(out.map((p) => p.id), ['p2', 'p1', 'p3']);
      expect(out.first.history.single.id, 'v1');
      expect(out.first.updatedAt, '1');
      expect(DatabaseHelper.patientsFromRowsStrict(const []), isEmpty);
    });

    test('one row that would come back flagged throws unreadableRow', () {
      for (final bad in <Object?>[
        '{not json',
        '{"id":"v"}', // object, not a list
        jsonEncode([42]), // visit is not an object
        jsonEncode([{'id': 'v', 'date': 'not a date'}]),
      ]) {
        final rows = [row('p1'), row('p2', history: bad, name: marker), row('p3')];
        // The whole answer is refused, without patient data in the error.
        try {
          DatabaseHelper.patientsFromRowsStrict(rows);
          fail('expected DbReadException for $bad');
        } on DbReadException catch (e) {
          expect(e.reason, DbReadFailure.unreadableRow, reason: '$bad');
          expect(e.toString(), isNot(contains(marker)));
        }
      }
    });
  });

  group('tombstoneIdsStrict', () {
    test('ids in order; a non-string or empty id throws unreadableRow', () {
      expect(
          DatabaseHelper.tombstoneIdsStrict([
            {'patient_id': 'b'},
            {'patient_id': 'a'},
          ]),
          ['b', 'a']);
      expect(DatabaseHelper.tombstoneIdsStrict(const []), isEmpty);
      for (final bad in <Object?>[null, '', 7, [0, 1]]) {
        expect(
            () => DatabaseHelper.tombstoneIdsStrict([
                  {'patient_id': 'ok'},
                  {'patient_id': bad},
                ]),
            readFails(DbReadFailure.unreadableRow),
            reason: '$bad');
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
      dir = Directory.systemTemp.createTempSync('docease_strict_');
      keys = MemoryKeyStore();
      opener = RecordingOpener();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> expectStrictNotOpenLenientEmpty(DatabaseHelper h) async {
      await expectLater(
          h.fetchPatientsStrict(), readFails(DbReadFailure.notOpen));
      await expectLater(
          h.dirtyPatientsStrict(), readFails(DbReadFailure.notOpen));
      await expectLater(
          h.pendingDeletesStrict(), readFails(DbReadFailure.notOpen));
      // Lenient behaviour unchanged: empty, no throw.
      expect(await h.fetchPatients(), isEmpty);
      expect(await h.dirtyPatients(), isEmpty);
      expect(await h.pendingDeletes(), isEmpty);
    }

    test('never opened: strict reads throw notOpen, lenient return empty',
        () async {
      await expectStrictNotOpenLenientEmpty(helper());
      expect(opener.calls, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('open failed: strict reads throw notOpen, lenient return empty',
        () async {
      keys.failRead = true;
      final h = helper();
      await expectLater(h.openFor('doctorA'), throwsA(isA<DbOpenException>()));
      expect(h.state, isA<DbFailed>());
      await expectStrictNotOpenLenientEmpty(h);
      expect(opener.calls, isEmpty);
    });
  });

  group('FakeLocalDatabase strict reads', () {
    test('mirror the contract and can be forced to fail', () async {
      final db = FakeLocalDatabase();
      expect(await db.fetchPatientsStrict(), isEmpty);
      expect(await db.pendingDeletesStrict(), isEmpty);
      db.strictReadFailure = DbReadFailure.readFailed;
      await expectLater(
          db.fetchPatientsStrict(), readFails(DbReadFailure.readFailed));
      await expectLater(
          db.dirtyPatientsStrict(), readFails(DbReadFailure.readFailed));
      await expectLater(
          db.pendingDeletesStrict(), readFails(DbReadFailure.readFailed));
      expect(await db.fetchPatients(), isEmpty); // lenient still empty
      db.strictReadFailure = null;
      db.state = const DbOpening('doctorA');
      await expectLater(
          db.fetchPatientsStrict(), readFails(DbReadFailure.notOpen));
    });
  });
}
