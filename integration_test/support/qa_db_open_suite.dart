// QA additions to the real-SQLCipher DatabaseHelper suite (#10 db_suite.dart).
// Same harness contract (DbSuiteHarness + one extra method), so it runs
//  * on an emulator/device: integration_test/qa_db_open_classification_test.dart
//  * on the host (system libsqlcipher via FFI): tool/sqlcipher_harness/run_qa.sh
//
// Only NEW coverage lives here; cases #10 already has (KCV-01/02/03/04,
// CLS-*, SET-03/06, MIG-*) are not repeated. IDs follow the QA regression
// draft (DOCEase_regression_cases_DRAFT.md):
//   KCV-03  transient open failure + matching KCV -> retryable, retry opens
//           (three error shapes: Android plugin, host FFI, opaque)
//   KCV-05  stored key missing, DB + KCV present -> keyUnavailable, both kept
//   KCV-08  KCV after a legacy claim matches the doctor key; reopen keeps it
//   KCV-09  KCV after reset matches the NEW stored key, never the old one
//   KCV-10  crash during CREATE                      (SKIPPED: needs DB hooks)
//   KCV-11  crash during CLAIM at every checkpoint: no keyMismatch, rows kept
//   KCV-12  crash during RESET + lock on next start  (SKIPPED: needs DB hooks)
//   KCV-13  tampered (well-formed, wrong) KCV + healthy DB: opens, rewritten
//   KCV-14  KCV copied from another doctor + healthy DB: opens, rewritten
//   KCV-15  malformed KCV + failed open: retryable, never keyMismatch
//   KCV-16  well-formed wrong KCV + failed open: keyMismatch BY DESIGN
//   KCV-17  KCV path is a directory (unreadable): retryable; good open works
//   SET-ENC-01 side files (-journal/-wal/-shm/.kcv) never hold a setting,
//              checked WHILE the DB is open (#10 SET-06 checks after close)
//   SET-ENC-02 no file in any app-private dir holds a setting value
//
// Uses only DatabaseHelper's public API, its @visibleForTesting keyCheckBytes
// and the harness opener. Touches only the qa_* doctor ids it creates.
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/local_database.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart'
    show Database, OnDatabaseCreateFn, OnDatabaseVersionChangeFn;

import 'db_suite.dart' show DbSuiteHarness;

/// DbSuiteHarness plus the app's private directories (for SET-ENC-02).
abstract class QaDbSuiteHarness implements DbSuiteHarness {
  /// Every directory the app can write to besides [databasesPath]
  /// (device: support, documents, cache/temp, and the app data root).
  Future<List<String>> appPrivateDirs();
}

const _uid = 'qaKcvA';
const _uidOther = 'qaKcvOther';
const _wrongKey =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _otherKey =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';

/// Error shapes a transient open failure can take (none is a wrong key).
final Map<String, Object Function(String path)> _errorShapes = {
  // sqflite_sqlcipher on Android reports locks/CANTOPEN/IO like a wrong key.
  'android': (path) => PlatformException(
      code: 'sqlite_error',
      message: 'open_failed $path',
      details: 'android.database.sqlite.SQLiteCantOpenDatabaseException'),
  // sqflite_common_ffi on the host.
  'host': (path) => Exception('SqfliteFfiException(sqlite_error: 5, '
      'SqliteException(5): database is locked) open_failed $path'),
  'opaque': (_) => StateError('boom'),
};

/// Wraps the harness opener; fails the next [failures] encrypted opens of
/// [path] with [error] before touching the file.
class _FlakyOpener implements CipherDatabaseOpener {
  _FlakyOpener(this.inner);
  final CipherDatabaseOpener inner;
  int failures = 0;
  String? path;
  Object Function(String path) error = _errorShapes['opaque']!;

  @override
  Future<Database> open(String path,
      {required String key,
      int? version,
      OnDatabaseCreateFn? onCreate,
      OnDatabaseVersionChangeFn? onUpgrade,
      OnDatabaseVersionChangeFn? onDowngrade}) async {
    if (failures > 0 && (this.path == null || p.equals(this.path!, path))) {
      failures--;
      throw error(path);
    }
    return inner.open(path,
        key: key,
        version: version,
        onCreate: onCreate,
        onUpgrade: onUpgrade,
        onDowngrade: onDowngrade);
  }

  @override
  Future<Database> openPlaintext(String path,
          {int? version, OnDatabaseCreateFn? onCreate}) =>
      inner.openPlaintext(path, version: version, onCreate: onCreate);
}

class _Crash implements Exception {
  _Crash(this.at);
  final MigrationCheckpoint at;
  @override
  String toString() => 'simulated crash at ${at.name}';
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// The KCV text #10 writes: 'v1:' + hex(HMAC(raw key bytes, uid tag)).
String kcvFor(String key, String uid) =>
    'v1:${_hex(DatabaseHelper.keyCheckBytes(key, uid))}';

const _v1Ddl = 'CREATE TABLE patients (id TEXT PRIMARY KEY, name TEXT, '
    'age TEXT, gender TEXT, phone TEXT, relation TEXT, history TEXT)';

void runQaDbOpenSuite(QaDbSuiteHarness h) {
  late String dir;
  late String dbPath;
  late String kcvPath;
  late _FlakyOpener opener;
  MigrationCheckpoint? crashAt;
  final crashed = <MigrationCheckpoint>[];

  DatabaseHelper make() => DatabaseHelper(
        keyStore: h.keys,
        opener: opener,
        databasesPath: h.databasesPath,
        migrationHook: (cp, _) async {
          if (cp == crashAt) {
            crashed.add(cp);
            throw _Crash(cp);
          }
        },
      );
  late DatabaseHelper db;

  Future<String?> storedKey() => h.keys.read(DatabaseHelper.keyNameFor(_uid));
  String? sidecar() =>
      File(kcvPath).existsSync() ? File(kcvPath).readAsStringSync().trim() : null;
  Future<String> expectedKcv() async => kcvFor((await storedKey())!, _uid);

  Future<void> wipe() async {
    dir = await h.databasesPath();
    await Directory(dir).create(recursive: true);
    dbPath = p.join(dir, DatabaseHelper.dbFileNameFor(_uid));
    kcvPath = DatabaseHelper.kcvPathFor(dbPath);
    final mine = {
      p.basename(dbPath),
      p.basename(DatabaseHelper.legacyDbFileName),
    };
    for (final e in Directory(dir).listSync()) {
      final n = p.basename(e.path);
      if (!mine.any(n.startsWith)) continue;
      if (e is Directory) {
        e.deleteSync(recursive: true);
      } else {
        e.deleteSync();
      }
    }
    for (final k in [
      DatabaseHelper.keyNameFor(_uid),
      DatabaseHelper.unsyncedCounterKeyFor(_uid),
      DatabaseHelper.keyNameFor(_uidOther),
      DatabaseHelper.legacyKeyName,
    ]) {
      await h.keys.delete(k);
    }
    crashAt = null;
    crashed.clear();
    opener = _FlakyOpener(h.opener);
    db = make();
  }

  /// Fresh doctor DB with one patient, closed, KCV present.
  Future<void> fresh() async {
    await wipe();
    await db.openFor(_uid);
    await db.insertPatient(Patient(
        id: 'p1', name: 'Cls', age: '1', gender: 'M', phone: '1', history: []));
    await db.close();
    opener.path = dbPath;
  }

  Future<DbFailed> failedOpen() async {
    await expectLater(db.openFor(_uid), throwsA(isA<DbOpenException>()));
    return db.state as DbFailed;
  }

  void expectRetryable(DbFailed s) {
    expect(s.error, isNot(DbOpenError.keyMismatch),
        reason: 'a retryable failure must never offer a reset');
    expect(s.canReset, isFalse);
  }

  Future<void> expectOpensWithP1() async {
    await db.openFor(_uid);
    expect(db.state, isA<DbReady>());
    expect((await db.fetchPatients()).map((e) => e.id), contains('p1'));
    await db.close();
  }

  Future<void> seedLegacyPlaintext({int rows = 2}) async {
    final legacy = p.join(dir, DatabaseHelper.legacyDbFileName);
    final ldb = await h.opener.openPlaintext(legacy,
        version: 1, onCreate: (d, _) => d.execute(_v1Ddl));
    for (var i = 0; i < rows; i++) {
      await ldb.insert('patients', {
        'id': 'L$i', 'name': 'Legacy $i', 'age': '3$i', 'gender': 'F',
        'phone': '9$i', 'relation': 'Self', 'history': '[]',
      });
    }
    await ldb.close();
  }

  // ---------------------------------------------------------------- KCV-03
  for (final shape in _errorShapes.entries) {
    h.define(
        'KCV-03 [${shape.key}] transient open failure + matching KCV: '
        'retryable, retry opens with data', () async {
      await fresh();
      opener
        ..failures = 1
        ..error = shape.value;
      expectRetryable(await failedOpen());
      await expectLater(
          db.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
          throwsA(isA<StateError>()),
          reason: 'reset must be refused after a retryable failure');
      await expectOpensWithP1();
      expect(sidecar(), await expectedKcv());
    });
  }

  // ---------------------------------------------------------------- KCV-05
  h.define(
      'KCV-05 stored key missing, DB + KCV present: keyUnavailable '
      '(retry-only), DB bytes and KCV untouched, no new key invented', () async {
    await fresh();
    final before = File(dbPath).readAsBytesSync();
    final kcv = sidecar();
    await h.keys.delete(DatabaseHelper.keyNameFor(_uid));
    final s = await failedOpen();
    expect(s.error, DbOpenError.keyUnavailable);
    expect(s.canReset, isFalse);
    expect(File(dbPath).readAsBytesSync(), before);
    expect(sidecar(), kcv);
    expect(await storedKey(), isNull,
        reason: 'a key must not be created for an existing encrypted file');
  });

  // ---------------------------------------------------------------- KCV-08
  h.define(
      'KCV-08 after a legacy claim the KCV matches the doctor key; '
      'a reopen leaves it unchanged', () async {
    await wipe();
    await seedLegacyPlaintext();
    expect(await db.claimLegacyDb(_uid), isTrue);
    await db.close();
    final k1 = sidecar();
    expect(k1, await expectedKcv());
    await db.openFor(_uid);
    expect((await db.fetchPatients()).length, 2);
    await db.close();
    expect(sidecar(), k1);
  });

  // ---------------------------------------------------------------- KCV-09
  h.define(
      'KCV-09 after reset the KCV matches the NEW stored key, never the old; '
      'the new file opens', () async {
    await fresh();
    final oldKcv = sidecar();
    await h.keys.write(DatabaseHelper.keyNameFor(_uid), _wrongKey);
    expect((await failedOpen()).error, DbOpenError.keyMismatch);
    await db.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown);
    await db.close();
    expect(sidecar(), isNot(oldKcv));
    expect(sidecar(), await expectedKcv());
    db = make();
    await db.openFor(_uid);
    expect(db.state, isA<DbReady>());
    await db.close();
  });

  // ------------------------------------------- KCV-10 / KCV-12 (need hooks)
  // Invariant: after a crash at any point, the next start either opens with
  // all data or is retryable; keyMismatch is never offered while the stored
  // key decrypts the file; the KCV is missing or equals KCV(stored key).
  // Neither _createFresh nor resetAndResync calls the MigrationHook today,
  // so these crash points cannot be reached. Hooks needed: see
  // /workspace/qa/reports/it_compile/DB_HOOKS_NEEDED.md.
  const kcvHooksSkip = 'needs DB hooks: MigrationHook is only called in '
      'recovery migrations; _createFresh/resetAndResync have no checkpoint '
      '(see DB_HOOKS_NEEDED.md)';
  h.define('KCV-10 crash during CREATE (after KCV written / after DB created, '
      'before afterOpen): next start opens, KCV consistent [SKIP: $kcvHooksSkip]',
      () async => markTestSkipped(kcvHooksSkip));
  h.define('KCV-12 crash during RESET (after new key stored / after file moved '
      'aside / after KCV written) + lock on the next start: never keyMismatch '
      'on a file the stored key opens [SKIP: $kcvHooksSkip]',
      () async => markTestSkipped(kcvHooksSkip));

  // ---------------------------------------------------------------- KCV-11
  for (final cp in MigrationCheckpoint.values) {
    h.define(
        'KCV-11 [${cp.name}] crash during CLAIM: next start never offers '
        'keyMismatch, legacy rows kept, KCV missing-or-consistent', () async {
      await wipe();
      await seedLegacyPlaintext();
      crashAt = cp;
      await expectLater(db.claimLegacyDb(_uid), throwsA(anything));
      expect(crashed, [cp], reason: 'checkpoint ${cp.name} was not reached');
      crashAt = null;
      try {
        await db.close();
      } catch (_) {}
      db = make(); // "restart"
      if (await db.hasLegacyDb()) {
        expect(await db.claimLegacyDb(_uid), isTrue);
      } else {
        try {
          await db.openFor(_uid);
        } on DbOpenException {
          expectRetryable(db.state as DbFailed);
          rethrow;
        }
      }
      expect(db.state, isA<DbReady>());
      expect((await db.fetchPatients()).map((e) => e.id).toSet(), {'L0', 'L1'});
      await db.close();
      final kcv = sidecar();
      expect(kcv == null || kcv == await expectedKcv(), isTrue,
          reason: 'stale KCV after claim crash at ${cp.name}');
    });
  }

  // ---------------------------------------------------------- KCV-13 / 14
  h.define(
      'KCV-13 tampered KCV (well-formed, wrong value) + healthy DB: opens, '
      'no keyMismatch, KCV rewritten', () async {
    await fresh();
    File(kcvPath).writeAsStringSync(kcvFor(_otherKey, 'someoneElse'));
    await expectOpensWithP1();
    expect(sidecar(), await expectedKcv());
  });

  h.define('KCV-14 KCV copied from another doctor + healthy DB: opens, rewritten',
      () async {
    await fresh();
    File(kcvPath).writeAsStringSync(kcvFor((await storedKey())!, _uidOther));
    await expectOpensWithP1();
    expect(sidecar(), await expectedKcv());
  });

  // ---------------------------------------------------------------- KCV-15
  final malformed = <String, String>{
    'empty': '',
    'short': 'zz',
    'non-hex': 'v1:${'g' * 64}',
    'no prefix, 64 hex': 'a' * 64,
    'wrong version': 'v2:${'a' * 64}',
    'truncated': 'v1:df0a02cfb579c55dc2257914fa4ef749',
  };
  for (final m in malformed.entries) {
    h.define(
        'KCV-15 malformed KCV (${m.key}) + failed open: retryable (ambiguous), '
        'never keyMismatch', () async {
      await fresh();
      File(kcvPath).writeAsStringSync(m.value);
      opener.failures = 1;
      expectRetryable(await failedOpen());
      await expectOpensWithP1();
      expect(sidecar(), await expectedKcv(), reason: 'repaired on good open');
    });
  }

  // ---------------------------------------------------------------- KCV-16
  h.define(
      'KCV-16 well-formed wrong KCV + failed open: keyMismatch BY DESIGN '
      '(two faults; reset still gated by the unsynced count)', () async {
    await fresh();
    File(kcvPath).writeAsStringSync(kcvFor(_otherKey, 'someoneElse'));
    opener.failures = 1;
    final s = await failedOpen();
    expect(s.error, DbOpenError.keyMismatch);
    expect(s.canReset, isTrue);
    // The gate still holds: the counter says 1 unsynced, so a reset that
    // acknowledges 0 must be refused.
    await expectLater(
        db.resetAndResync(acknowledgedUnsynced: const UnsyncedCount.known(0)),
        throwsA(isA<ResetNotConfirmedException>()));
    expect(File(dbPath).existsSync(), isTrue);
  });

  // ---------------------------------------------------------------- KCV-17
  h.define(
      'KCV-17 KCV path is a directory (unreadable): failed open is retryable; '
      'a good open still works', () async {
    await fresh();
    File(kcvPath).deleteSync();
    Directory(kcvPath).createSync();
    try {
      opener.failures = 1;
      expectRetryable(await failedOpen());
      await expectOpensWithP1();
    } finally {
      if (Directory(kcvPath).existsSync()) {
        Directory(kcvPath).deleteSync(recursive: true);
      }
    }
  });

  // ---------------------------------------------------------- SET-ENC-01/02
  bool fileHas(File f, String s) {
    final List<int> b;
    try {
      b = f.readAsBytesSync();
    } catch (_) {
      return false; // unreadable (e.g. a socket); cannot leak through us
    }
    final n = s.codeUnits;
    outer:
    for (var i = 0; i + n.length <= b.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (b[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  List<File> sideFiles() => [
        for (final suffix in ['-journal', '-wal', '-shm', '.kcv', '.kcv.tmp'])
          if (File('$dbPath$suffix').existsSync()) File('$dbPath$suffix'),
      ];

  h.define(
      'SET-ENC-01 side files (-journal/-wal/-shm/.kcv) never hold a setting, '
      'checked while the DB is open and after close', () async {
    await wipe();
    final marker = 'QA_SET_MARKER_${DateTime.now().microsecondsSinceEpoch}';
    await db.openFor(_uid);
    for (var i = 0; i < 50; i++) {
      await db.putSetting('qa_k$i', '{"name":"$marker","i":$i}');
    }
    final whileOpen = [
      for (final f in [File(dbPath), ...sideFiles()])
        if (fileHas(f, marker)) p.basename(f.path)
    ];
    expect(await db.getSetting('qa_k7'), contains(marker));
    await db.close();
    final afterClose = [
      for (final f in [File(dbPath), ...sideFiles()])
        if (fileHas(f, marker)) p.basename(f.path)
    ];
    expect(whileOpen, isEmpty, reason: 'plaintext setting while open');
    expect(afterClose, isEmpty, reason: 'plaintext setting after close');
  });

  h.define('SET-ENC-02 no file in any app-private dir holds a setting value',
      () async {
    await wipe();
    final marker = 'QA_SET_LEAK_${DateTime.now().microsecondsSinceEpoch}';
    await db.openFor(_uid);
    await db.putSetting('frequent_medicines', '["$marker"]');
    await db.putSetting('doctor_profile', '{"name":"$marker"}');
    expect(await db.getSetting('doctor_profile'), contains(marker));
    await db.close();
    final roots = {dir, ...await h.appPrivateDirs()};
    final leaks = <String>[];
    var scanned = 0;
    for (final r in roots) {
      final d = Directory(r);
      if (!d.existsSync()) continue;
      for (final e in d.listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        scanned++;
        if (fileHas(e, marker)) leaks.add(e.path);
      }
    }
    expect(scanned, greaterThan(0), reason: 'positive control: nothing scanned');
    expect(leaks, isEmpty);
  });
}
