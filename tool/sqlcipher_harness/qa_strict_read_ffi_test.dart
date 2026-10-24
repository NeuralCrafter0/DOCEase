// Real SQLCipher via FFI. #10 9a8d31b strict-read contract (final names):
// fetchPatientsStrict / dirtyPatientsStrict / pendingDeletesStrict are
// complete or throw DbReadException(reason), reason in DbReadFailure
// { notOpen, readFailed, unreadableRow }; message "DbReadException(<reason>)"
// and never patient data. Never [] on failure.
// Run: QA_FFI_TEST=qa_strict_read_ffi_test.dart bash tool/sqlcipher_harness/run_qa.sh
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/local_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'qa_sweep_ffi_test.dart' show RecOpener;
import 'sqlcipher_ffi_test.dart' show MemKeys;

const uid = 'doctorA';
const secretName = 'Priya_Sharma';

Matcher _reason(DbReadFailure r) => throwsA(isA<DbReadException>()
    .having((e) => e.reason, 'reason', r)
    .having((e) => '$e', 'message', 'DbReadException(${r.name})'));

void main() {
  late Directory tmp;
  late DatabaseHelper db;
  late RecOpener opener;

  final reads = <String, Future<List<Object>> Function()>{
    'fetchPatientsStrict': () => db.fetchPatientsStrict(),
    'dirtyPatientsStrict': () => db.dirtyPatientsStrict(),
    'pendingDeletesStrict': () => db.pendingDeletesStrict(),
  };

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('qa_strict_');
    Directory(p.join(tmp.path, 'db')).createSync();
    opener = RecOpener();
    db = DatabaseHelper(
        keyStore: MemKeys(),
        opener: opener,
        databasesPath: () async => p.join(tmp.path, 'db'));
    await db.openFor(uid);
    for (final id in ['p1', 'p2']) {
      await db.insertPatient(Patient(
          id: id,
          name: secretName,
          age: '30',
          gender: 'Female',
          phone: '+910000000000',
          history: const []));
    }
    await db.markPendingDelete('p2'); // one tombstone
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    tmp.deleteSync(recursive: true);
  });

  test('DBS-RS-00 healthy: each strict read returns complete data', () async {
    expect((await db.fetchPatientsStrict()).map((x) => x.id), ['p1']);
    expect((await db.dirtyPatientsStrict()).map((x) => x.id), ['p1']);
    expect(await db.pendingDeletesStrict(), ['p2']);
  });

  for (final e in reads.entries) {
    group('${e.key}', () {
      test('DBS-RS-01 closed -> notOpen', () async {
        await db.close();
        await expectLater(e.value(), _reason(DbReadFailure.notOpen));
      });

      test('DBS-RS-03 handle closed while helper ready (P2) -> readFailed',
          () async {
        await opener.last!.close();
        await expectLater(e.value(), _reason(DbReadFailure.readFailed));
      });
    });
  }

  group('DBS-RS-02 table unreadable while open (P1) -> readFailed', () {
    test('patients gone: fetch + dirty', () async {
      await opener.last!.execute('ALTER TABLE patients RENAME TO patients_x');
      await expectLater(
          db.fetchPatientsStrict(), _reason(DbReadFailure.readFailed));
      await expectLater(
          db.dirtyPatientsStrict(), _reason(DbReadFailure.readFailed));
    });
    test('pending_deletes gone: pendingDeletesStrict', () async {
      await opener.last!
          .execute('ALTER TABLE pending_deletes RENAME TO pending_x');
      await expectLater(
          db.pendingDeletesStrict(), _reason(DbReadFailure.readFailed));
    });
  });

  group('DBS-RS-04 corrupt row -> unreadableRow, no patient data', () {
    for (final name in ['fetchPatientsStrict', 'dirtyPatientsStrict']) {
      test(name, () async {
        await opener.last!.rawUpdate(
            "UPDATE patients SET history = 'not json' WHERE id = 'p1'");
        try {
          await reads[name]!();
          fail('should throw');
        } on DbReadException catch (e) {
          expect(e.reason, DbReadFailure.unreadableRow);
          expect('$e', 'DbReadException(unreadableRow)');
          expect('$e', isNot(contains(secretName)));
        }
      });
    }
    // SQLite lets a TEXT PRIMARY KEY hold NULL (rowid table quirk).
    for (final bad in ['NULL', "''"]) {
      test('pendingDeletesStrict tombstone id $bad', () async {
        await opener.last!.rawInsert(
            'INSERT INTO pending_deletes (patient_id, deleted_at) VALUES ($bad, 1)');
        await expectLater(
            db.pendingDeletesStrict(), _reason(DbReadFailure.unreadableRow));
      });
    }
  });

  test('DBS-RS-05 lenient reads unchanged (UI-only, documented)', () async {
    await opener.last!.execute('ALTER TABLE patients RENAME TO patients_x');
    expect(await db.fetchPatients(), isEmpty);
    expect(await db.dirtyPatients(), isEmpty);
  });
}
