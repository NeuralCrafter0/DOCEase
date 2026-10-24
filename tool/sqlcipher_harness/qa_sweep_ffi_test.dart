// QA photo-sweep cases on the REAL stack: DatabaseHelper on real SQLCipher
// through FFI (same opener as #10's harness). Host only:
//   QA_FFI_TEST=qa_sweep_ffi_test.dart bash tool/sqlcipher_harness/run_qa.sh
// run_qa.sh copies the repo to a temp dir and places this file in test/.
//
// SWP-RS-02/03 reproduce security's #16 finding (P1/P2): a read fails while
// the helper still reports the DB open; the lenient fetchPatients() returns
// [], and a sweep built on it deleted in-use photos (2313ff8). Every case
// runs through the app's wiring (test/qa_sweep/support/app_sweep_wiring.dart,
// mirrors PhotoSweep.forApp()). Skip reasons and the skip log line
// ("Photos: sweep skipped (<reason name>)") are asserted exactly.
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/photo_sweep.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart'
    show Database, OnDatabaseCreateFn, OnDatabaseVersionChangeFn;

import 'qa_sweep/support/app_sweep_wiring.dart';
import 'sqlcipher_ffi_test.dart' show FfiOpener, MemKeys;

const uid = 'doctorA';

/// #10's FfiOpener, keeping the last raw handle so a test can break reads
/// behind the helper's back.
class RecOpener implements CipherDatabaseOpener {
  final _inner = FfiOpener();
  Database? last;
  @override
  Future<Database> openPlaintext(String path,
          {int? version, OnDatabaseCreateFn? onCreate}) async =>
      last = await _inner.openPlaintext(path,
          version: version, onCreate: onCreate);
  @override
  Future<Database> open(String path,
          {required String key,
          int? version,
          OnDatabaseCreateFn? onCreate,
          OnDatabaseVersionChangeFn? onUpgrade,
          OnDatabaseVersionChangeFn? onDowngrade}) async =>
      last = await _inner.open(path,
          key: key,
          version: version,
          onCreate: onCreate,
          onUpgrade: onUpgrade,
          onDowngrade: onDowngrade);
}

enum Wiring { app }

DateTime _later() => DateTime.now().add(const Duration(hours: 1));

void main() {
  late Directory tmp;
  late DatabaseHelper db;
  late RecOpener opener;
  late LocalPhotoStore photos;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('qa_sweep_ffi_');
    Directory(p.join(tmp.path, 'db')).createSync();
    Directory(p.join(tmp.path, 'support')).createSync();
    opener = RecOpener();
    db = DatabaseHelper(
        keyStore: MemKeys(),
        opener: opener,
        databasesPath: () async => p.join(tmp.path, 'db'));
    photos = LocalPhotoStore(
        supportDir: () async => Directory(p.join(tmp.path, 'support')));
    await photos.init();
    await db.openFor(uid);
  });

  tearDown(() async {
    try {
      await db.close();
    } catch (_) {}
    tmp.deleteSync(recursive: true);
  });

  String photo(String name) {
    final dir = photos.visitFolderFor(uid)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, name))..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]))
        .path;
  }

  Future<({String used, String orphan})> seed() async {
    final used = photo('0b5e6c1e-1111-4222-8333-944455556666.jpg');
    final orphan = photo('0b5e6c1e-1111-4222-8333-944455550000.jpg');
    await db.insertPatient(Patient(
        id: 'p1',
        name: 'Test',
        age: '30',
        gender: 'Female',
        phone: '+910000000000',
        history: [
          VisitRecord(
              id: 'v1',
              date: DateTime(2026, 1, 2),
              visitType: 'Consultation',
              symptoms: 's',
              diagnosis: 'd',
              prescription: 'r',
              attachmentPaths: [used]),
        ]));
    return (used: used, orphan: orphan);
  }

  PhotoSweep sweepFor(Wiring w) => appSweep(db, photos, _later);

  test('SWP-RS-00 this really is SQLCipher', () async {
    final v = await opener.last!.rawQuery('PRAGMA cipher_version');
    expect(v, isNotEmpty);
    expect('${v.first.values.first}', isNotEmpty);
    // ignore: avoid_print
    print('SWP-RS-00 cipher_version=${v.first.values.first} '
        'appWiring=$appWiringHead');
  });

  for (final w in Wiring.values) {
    group('[${w.name}]', () {
      test('SWP-RS-01 control: healthy DB keeps used, removes orphan',
          () async {
        final s = await seed();
        final r = await sweepFor(w).sweep(uid);
        expect(r.ran, isTrue, reason: '${r.reason}');
        expect(File(s.used).existsSync(), isTrue);
        expect(File(s.orphan).existsSync(), isFalse);
      });

      test('SWP-RS-02 table unreadable while DB open (P1): no deletes',
          () async {
        final s = await seed();
        await opener.last!.execute('ALTER TABLE patients RENAME TO patients_x');
        expect(db.openUid, uid, reason: 'precondition: helper still open');
        final lenient = await db.fetchPatients();
        await expectLater(db.referencedAttachmentKeys(),
            throwsA(isA<AttachmentScanIncomplete>()));
        final r = await sweepFor(w).sweep(uid);
        // ignore: avoid_print
        print('SWP-RS-02 [${w.name}] fetchPatients=${lenient.length} '
            'ran=${r.ran} reason=${r.reason} removed=${r.removed}');
        expect(File(s.used).existsSync(), isTrue,
            reason: 'DATA LOSS: in-use photo deleted after a failed read');
        expect(File(s.orphan).existsSync(), isTrue);
        expect(r.ran, isFalse);
        expect(r.reason, 'readFailed');
      });

      test('SWP-RS-03 raw handle closed while helper says ready (P2)',
          () async {
        final s = await seed();
        await opener.last!.close();
        expect(db.openUid, uid, reason: 'precondition: helper still open');
        final r = await sweepFor(w).sweep(uid);
        // ignore: avoid_print
        print('SWP-RS-03 [${w.name}] ran=${r.ran} reason=${r.reason} '
            'removed=${r.removed}');
        expect(File(s.used).existsSync(), isTrue,
            reason: 'DATA LOSS: in-use photo deleted after the handle died');
        expect(File(s.orphan).existsSync(), isTrue);
        expect(r.ran, isFalse);
        expect(r.reason, 'readFailed');
      });

      test('SWP-RS-04 one corrupt history row: no deletes', () async {
        final s = await seed();
        await opener.last!.rawUpdate(
            "UPDATE patients SET history = 'not json' WHERE id = 'p1'");
        final r = await sweepFor(w).sweep(uid);
        // ignore: avoid_print
        print('SWP-RS-04 [${w.name}] ran=${r.ran} reason=${r.reason} '
            'removed=${r.removed}');
        expect(File(s.used).existsSync(), isTrue,
            reason: 'DATA LOSS: photo of an unreadable row deleted');
        expect(File(s.orphan).existsSync(), isTrue);
        expect(r.reason, anyOf('unreadableRow', 'unreadableAttachmentList'));
      });

      test('SWP-RS-06 a stored file://evil/ path: scan throws, nothing '
          'deleted, log names the reason', () async {
        final s = await seed();
        await opener.last!.rawUpdate(
            'UPDATE patients SET history = replace(history, ?, ?) '
            "WHERE id = 'p1'",
            [s.used, 'file://evil${s.used}']);
        final logs = <String>[];
        final saved = debugPrint;
        debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
        final PhotoSweepResult r;
        try {
          r = await sweepFor(w).sweep(uid);
        } finally {
          debugPrint = saved;
        }
        expect(r.ran, isFalse);
        expect(r.reason, 'unrecognisedPath');
        expect(logs, contains('Photos: sweep skipped (unrecognisedPath)'),
            reason: '$logs');
        expect(File(s.used).existsSync(), isTrue);
        expect(File(s.orphan).existsSync(), isTrue);
      });

      for (final prefix in ['file://', 'file://localhost']) {
        test('SWP-RS-07 a "$prefix" row protects the photo (real scan)',
            () async {
          final s = await seed();
          await opener.last!.rawUpdate(
              'UPDATE patients SET history = replace(history, ?, ?) '
              "WHERE id = 'p1'",
              [s.used, '$prefix${s.used}']);
          final r = await sweepFor(w).sweep(uid);
          expect(r.ran, isTrue, reason: '${r.reason}');
          expect(File(s.used).existsSync(), isTrue);
          expect(File(s.orphan).existsSync(), isFalse);
        });
      }

      test('SWP-RS-05 closed DB: skipped', () async {
        final s = await seed();
        await db.close();
        final r = await sweepFor(w).sweep(uid);
        expect(r.ran, isFalse);
        expect(File(s.used).existsSync(), isTrue);
        expect(File(s.orphan).existsSync(), isTrue);
      });
    });
  }
}
