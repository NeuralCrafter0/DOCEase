// Real-SQLCipher test bodies for DatabaseHelper, shared by
//  * integration_test/db_encryption_migration_test.dart (emulator/device:
//    sqflite_sqlcipher + flutter_secure_storage / Android Keystore), and
//  * any host harness that supplies a SQLCipher-backed opener.
// The suite only talks to the app through DatabaseHelper's public API plus
// the harness's opener (for seeding legacy files and checking raw files).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' show Database;

abstract class DbSuiteHarness {
  /// Directory the helper keeps its databases in.
  Future<String> databasesPath();

  /// The key store the helper uses (real secure storage on device).
  DbKeyStore get keys;

  /// SQLCipher opener; [CipherDatabaseOpener.open] must throw if the key
  /// does not decrypt the file.
  CipherDatabaseOpener get opener;

  /// Registers one test (testWidgets on device, test on host).
  void define(String name, Future<void> Function() body);
}

const uidA = 'itestA';
const uidB = 'itestB';
const uidOther = 'other';
const fallbackKey = 'fallback_secure_key_123';
const uniqueName = 'ZZ_UNIQUE_PATIENT_NAME_ZZ';
const _v1Ddl = 'CREATE TABLE patients (id TEXT PRIMARY KEY, name TEXT, '
    'age TEXT, gender TEXT, phone TEXT, relation TEXT, history TEXT)';

void runDbSuite(DbSuiteHarness h) {
  late String dir;
  String path(String name) => p.join(dir, name);
  String dbPath(String uid) => path(DatabaseHelper.dbFileNameFor(uid));
  String legacyPath() => path(DatabaseHelper.legacyDbFileName);

  final excluder = _RecordingExcluder();
  DatabaseHelper helper(
          {DbKeyStore? keys,
          int? schemaVersion,
          MigrationHook? hook,
          Future<String> Function()? databasesPath}) =>
      DatabaseHelper(
        keyStore: keys ?? h.keys,
        opener: h.opener,
        databasesPath: databasesPath ?? h.databasesPath,
        schemaVersion: schemaVersion ?? DatabaseHelper.currentSchemaVersion,
        migrationHook: hook,
        backupExcluder: excluder,
      );
  String kcvPath(String uid) => DatabaseHelper.kcvPathFor(dbPath(uid));

  Future<String?> keyOf(String uid) => h.keys.read(DatabaseHelper.keyNameFor(uid));
  Future<String?> counterOf(String uid) =>
      h.keys.read(DatabaseHelper.unsyncedCounterKeyFor(uid));

  Future<void> wipe() async {
    dir = await h.databasesPath();
    await Directory(dir).create(recursive: true);
    for (final e in Directory(dir).listSync()) {
      final n = p.basename(e.path);
      if (n.startsWith('docease_') && e is File) e.deleteSync();
    }
    for (final uid in [uidA, uidB, uidOther]) {
      await h.keys.delete(DatabaseHelper.keyNameFor(uid));
      await h.keys.delete(DatabaseHelper.unsyncedCounterKeyFor(uid));
    }
    await h.keys.delete(DatabaseHelper.legacyKeyName);
  }

  List<String> strayFiles() => Directory(dir)
      .listSync()
      .map((e) => p.basename(e.path))
      .where((n) => n.contains('.migrating') || n.contains('.encrypting') ||
          n.endsWith('.claimed') || n.endsWith('.tmp'))
      .toList();

  bool isPlainSqlite(String file) {
    final head = File(file).openSync()..setPositionSync(0);
    final bytes = head.readSync(16);
    head.closeSync();
    return String.fromCharCodes(bytes) == 'SQLite format 3\u0000';
  }

  bool containsBytes(String file, String needle) {
    final hay = File(file).readAsBytesSync();
    final n = utf8.encode(needle);
    outer:
    for (var i = 0; i <= hay.length - n.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (hay[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  Future<void> expectCannotOpen(String file, String? key) async {
    Object? error;
    try {
      final db = key == null
          ? await h.opener.openPlaintext(file)
          : await h.opener.open(file, key: key);
      await db.rawQuery('SELECT COUNT(*) FROM patients');
      await db.close();
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: 'opened $file with key=${key == null ? 'none' : 'given'}');
  }

  Map<String, Object?> v1Row(int i) => {
        'id': 'p$i', 'name': 'Patient $i', 'age': '${20 + i}', 'gender': 'Other',
        'phone': '+9100000$i', 'relation': 'Self',
        'history': jsonEncode([
          {'id': 'r$i', 'date': '2026-01-0${1 + i % 9}T00:00:00.000',
           'visitType': 'Routine', 'symptoms': 'cough \u2022 $i',
           'diagnosis': 'Dx $i', 'prescription': 'Rx $i'}
        ]),
      };

  /// Old-build legacy file: v1 schema, [cipherKey] null = plaintext.
  Future<Map<String, String>> seedLegacy({String? cipherKey, int rows = 25}) async {
    Future<void> create(Database db, int _) => db.execute(_v1Ddl);
    final db = cipherKey == null
        ? await h.opener.openPlaintext(legacyPath(), version: 1, onCreate: create)
        : await h.opener.open(legacyPath(),
            key: cipherKey, version: 1, onCreate: create);
    final history = <String, String>{};
    for (var i = 0; i < rows; i++) {
      final r = v1Row(i);
      await db.insert('patients', r);
      history[r['id'] as String] = r['history'] as String;
    }
    await db.close();
    return history;
  }

  Future<Map<String, String>> rawHistory(String file, String key) async {
    final db = await h.opener.open(file, key: key);
    try {
      return {
        for (final r in await db.query('patients'))
          r['id'] as String: r['history'] as String
      };
    } finally {
      await db.close();
    }
  }

  Future<List<Map<String, Object?>>> rawRows(Database db) =>
      db.query('patients', orderBy: 'id');

  Future<int> userVersion(Database db) async =>
      (await db.rawQuery('PRAGMA user_version')).first.values.first as int;

  Patient patient(String id, {String name = 'Asha'}) => Patient(
      id: id, name: name, age: '34', gender: 'Female', phone: '+91999',
      history: [
        VisitRecord(
            id: 'v-$id', date: DateTime(2026, 1, 1), visitType: 'Routine',
            symptoms: 's', diagnosis: 'URTI', prescription: 'rx'),
      ]);

  Future<void> expectClaimFailedSafely(
      DatabaseHelper d, List<int> legacyBefore, DbOpenError error) async {
    expect(d.state, isA<DbFailed>());
    expect((d.state as DbFailed).error, error);
    expect(File(legacyPath()).readAsBytesSync(), legacyBefore,
        reason: 'legacy file must be byte-identical');
    expect(File(dbPath(uidA)).existsSync(), isFalse);
    expect(strayFiles(), isEmpty);
    expect(await helper().hasLegacyDb(), isTrue);
  }

  // -------------------------------------------------------------------------

  h.define('DB-08/09 new DB is encrypted, unreadable without the key or with '
      'the old fallback key, and holds no plaintext', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1', name: uniqueName));
    await d.close();

    final file = dbPath(uidA);
    expect(isPlainSqlite(file), isFalse);
    expect(containsBytes(file, uniqueName), isFalse);
    await expectCannotOpen(file, null);
    await expectCannotOpen(file, '');
    await expectCannotOpen(file, fallbackKey);
    await expectCannotOpen(file, DatabaseHelper.generateKey());
    final key = (await keyOf(uidA))!;
    expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
    final db = await h.opener.open(file, key: key);
    expect((await rawRows(db)).single['name'], uniqueName);
    await db.close();
  });

  h.define('DB-10/11 key reused across reopen; each doctor has own key/file',
      () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('a1'));
    final keyA = await keyOf(uidA);
    await d.close();
    await d.openFor(uidA);
    expect(await keyOf(uidA), keyA);
    expect((await d.fetchPatients()).single.id, 'a1');

    await d.openFor(uidB); // closes A first
    expect(d.currentUid, uidB);
    expect(await d.fetchPatients(), isEmpty);
    expect(await keyOf(uidB), isNot(keyA));
    expect(File(dbPath(uidB)).existsSync(), isTrue);
    await d.close();
    await expectCannotOpen(dbPath(uidB), keyA);
  });

  h.define('DB-01 (real files) key read failure never creates or opens a DB',
      () async {
    await wipe();
    final d = helper(keys: _FailingKeys(h.keys, failRead: true));
    await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
    expect((d.state as DbFailed).error, DbOpenError.keyUnavailable);
    expect(File(dbPath(uidA)).existsSync(), isFalse);
    expect(await keyOf(uidA), isNull);
  });

  h.define('MIG-09 fresh install is created directly at v2', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    expect(await userVersion(db), 2);
    final cols = [for (final c in await db.rawQuery('PRAGMA table_info(patients)')) c['name']];
    expect(cols, containsAll(['id', 'name', 'history', 'sync_state', 'updated_at']));
    await d.close();
  });

  h.define('MIG-08 v1 -> v2 upgrade keeps every row and marks them unsynced',
      () async {
    await wipe();
    // v1 fixture through the constructor hook, under the doctor's real key.
    final v1 = helper(schemaVersion: 1);
    final db1 = await v1.openFor(uidA);
    expect(await userVersion(db1), 1);
    final rows = [for (var i = 0; i < 5; i++) v1Row(i)];
    for (final r in rows) {
      await db1.insert('patients', r);
    }
    await v1.close();

    final d = helper();
    final db = await d.openFor(uidA);
    expect(await userVersion(db), 2);
    final after = await rawRows(db);
    expect(after, hasLength(5));
    for (var i = 0; i < 5; i++) {
      for (final k in rows[i].keys) {
        expect(after[i][k], rows[i][k], reason: 'row $i field $k');
      }
      expect(after[i]['sync_state'], SyncState.dirty);
      expect(after[i]['updated_at'], greaterThan(0));
    }
    expect(await d.unsyncedCount(), const UnsyncedCount.known(5));
    expect(await counterOf(uidA), '5');
    expect((await d.dirtyPatients()).map((p) => p.id).toSet(),
        rows.map((r) => r['id']).toSet());
    await d.close();
  });

  // --- settings (local key-value store, schema v2) ------------------------

  Future<List<String>> tableNames(Database db) async => [
        for (final r in await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
          r['name'] as String
      ];

  Future<void> expectSettingsTable(Database db) async {
    final cols = {
      for (final c in await db.rawQuery('PRAGMA table_info(settings)'))
        c['name'] as String: c
    };
    expect(cols.keys, unorderedEquals(['key', 'value', 'updated_at']));
    expect(cols['key']!['type'], 'TEXT');
    expect(cols['key']!['pk'], 1);
    expect(cols['value']!['type'], 'TEXT');
    expect(cols['value']!['notnull'], 1);
    expect(cols['updated_at']!['type'], 'INTEGER');
    expect(cols['updated_at']!['notnull'], 1);
  }

  h.define('SET-01 fresh v2 create has the settings table, empty', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    expect(await userVersion(db), 2);
    expect(await tableNames(db),
        containsAll(['patients', 'pending_deletes', 'settings']));
    await expectSettingsTable(db);
    expect(await d.getSetting('doctor_profile'), isNull);
    await d.close();
  });

  h.define('SET-02 putSetting upserts; delete; counter and sync_state '
      'untouched', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    expect(await d.markSynced('p1', (await d.dirtyPatients()).single.updatedAt!),
        isTrue);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(0));
    final counterBefore = await counterOf(uidA);
    final patientBefore = await rawRows(db);

    await d.putSetting('medicines', '["Paracetamol"]');
    final first = (await db.query('settings')).single;
    await d.putSetting('medicines', '["Paracetamol","Amoxicillin"]');
    final rows = await db.query('settings');
    expect(rows, hasLength(1), reason: 'upsert, not a second row');
    expect(rows.single['value'], '["Paracetamol","Amoxicillin"]');
    expect(rows.single['updated_at'] as int,
        greaterThanOrEqualTo(first['updated_at'] as int));
    expect(await d.getSetting('medicines'), '["Paracetamol","Amoxicillin"]');
    await d.putSetting('doctor_profile', '{}');
    expect(await d.getSetting('doctor_profile'), '{}');

    await d.deleteSetting('medicines');
    expect(await d.getSetting('medicines'), isNull);
    await d.deleteSetting('medicines'); // no-op
    await d.deleteSetting('never_set'); // no-op
    expect(await d.getSetting('doctor_profile'), '{}');

    expect(await d.unsyncedCount(), const UnsyncedCount.known(0));
    expect(await counterOf(uidA), counterBefore);
    expect(await rawRows(db), patientBefore);
    expect(await d.dirtyPatients(), isEmpty);
    await d.close();
  });

  h.define('SET-03 settings survive close and reopen byte-for-byte; other '
      'doctors do not see them', () async {
    await wipe();
    const json = '{"name":"Dr. A \u00e9\u2022","meds":["x","y"],"n":1}';
    final d = helper();
    await d.openFor(uidA);
    await d.putSetting('doctor_profile', json);
    await d.close();
    await expectLater(d.getSetting('doctor_profile'), throwsA(anything),
        reason: 'closed: must throw, not return a stale value');

    final d2 = helper();
    await d2.openFor(uidA);
    expect(await d2.getSetting('doctor_profile'), json);
    await d2.openFor(uidB);
    expect(await d2.getSetting('doctor_profile'), isNull);
    await d2.close();
  });

  h.define('SET-04 v1 -> v2 upgrade adds the settings table and keeps rows',
      () async {
    await wipe();
    final v1 = helper(schemaVersion: 1);
    final db1 = await v1.openFor(uidA);
    expect(await tableNames(db1), isNot(contains('settings')));
    for (var i = 0; i < 3; i++) {
      await db1.insert('patients', v1Row(i));
    }
    await v1.close();

    final d = helper();
    final db = await d.openFor(uidA);
    expect(await userVersion(db), 2);
    await expectSettingsTable(db);
    expect(await db.query('settings'), isEmpty);
    expect(await rawRows(db), hasLength(3));
    await d.putSetting('k', 'v');
    expect(await d.getSetting('k'), 'v');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(3),
        reason: 'only the 3 upgraded patients count');
    await d.close();
  });

  h.define('SET-05 a v2 file from an earlier build (no settings or '
      'pending_deletes table) is repaired on open', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    final raw = await h.opener.open(dbPath(uidA), key: (await keyOf(uidA))!);
    await raw.execute('DROP TABLE settings');
    await raw.execute('DROP TABLE pending_deletes');
    await raw.close();

    final db = await d.openFor(uidA);
    expect(d.state, isA<DbReady>());
    await expectSettingsTable(db);
    expect(await tableNames(db), contains('pending_deletes'));
    await d.putSetting('k', 'v');
    expect(await d.getSetting('k'), 'v');
    expect((await d.fetchPatients()).single.id, 'p1');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));
    await d.close();
  });

  h.define('SET-06 setting values are not readable in the raw file', () async {
    await wipe();
    const marker = 'ZZ_SETTING_MARKER_Dr_Profile_ZZ';
    const keyMarker = 'ZZ_SETTING_KEY_ZZ';
    final d = helper();
    await d.openFor(uidA);
    await d.putSetting(keyMarker, '{"name":"$marker"}');
    await d.close();

    final file = dbPath(uidA);
    expect(isPlainSqlite(file), isFalse);
    for (final f in Directory(dir).listSync().whereType<File>()) {
      expect(containsBytes(f.path, marker), isFalse, reason: p.basename(f.path));
      expect(containsBytes(f.path, keyMarker), isFalse,
          reason: p.basename(f.path));
    }
    await expectCannotOpen(file, null);
    await expectCannotOpen(file, fallbackKey);
    await expectCannotOpen(file, DatabaseHelper.generateKey());
    final db = await h.opener.open(file, key: (await keyOf(uidA))!);
    expect((await db.query('settings')).single['value'], '{"name":"$marker"}');
    await db.close();
  });

  h.define('SET-07 settings calls throw when no DB is open or it failed',
      () async {
    await wipe();
    final none = helper();
    await expectLater(none.getSetting('k'), throwsA(isA<StateError>()));
    await expectLater(none.putSetting('k', 'v'), throwsA(isA<StateError>()));
    await expectLater(none.deleteSetting('k'), throwsA(isA<StateError>()));

    final failed = helper(keys: _FailingKeys(h.keys, failRead: true));
    await expectLater(failed.openFor(uidA), throwsA(isA<DbOpenException>()));
    await expectLater(failed.putSetting('k', 'v'),
        throwsA(isA<DbOpenException>()));
    expect(File(dbPath(uidA)).existsSync(), isFalse);
  });

  h.define('SET-08 claim never replaces a doctor DB holding only settings',
      () async {
    await wipe();
    await seedLegacy(rows: 2);
    final legacyBefore = File(legacyPath()).readAsBytesSync();
    final d = helper();
    await d.openFor(uidA);
    await d.putSetting('doctor_profile', '{"n":1}');
    await d.close();
    expect(await d.claimLegacyDb(uidA), isFalse);
    expect(File(legacyPath()).readAsBytesSync(), legacyBefore);
    expect(await d.getSetting('doctor_profile'), '{"n":1}');
    await d.close();
  });

  h.define('unsyncedCount follows dirty/synced, and markSynced is a '
      'compare-and-set (edit during flight)', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(0));

    final v1 = await d.insertPatient(patient('p1'));
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));
    expect(await counterOf(uidA), '1');

    // Edited while the v1 write is in flight: v1's confirmation must not
    // clean the row.
    final v2 = await d.updatePatient(patient('p1', name: 'Asha K'));
    expect(v2, isNot(v1));
    expect(await counterOf(uidA), '1', reason: 'already dirty: no double count');
    expect(await d.markSynced('p1', v1!), isFalse);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));
    expect((await d.dirtyPatients()).single.updatedAt, v2);

    expect(await d.markSynced('p1', v2!), isTrue);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(0));
    expect(await counterOf(uidA), '0');
    expect(await d.markSynced('p1', v2), isFalse, reason: 'no double decrement');
    expect(await counterOf(uidA), '0');
    expect(await d.markSynced('p1', 'garbage'), isFalse);

    // Cloud data arrives clean and is not counted.
    await d.insertPatient(patient('c1'), fromCloud: true);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(0));

    // Oldest updated_at first.
    await d.insertPatient(patient('a'));
    await d.insertPatient(patient('b'));
    expect((await d.dirtyPatients()).map((p) => p.id), ['a', 'b']);
    await d.updatePatient(patient('a', name: 'A2'));
    expect((await d.dirtyPatients()).map((p) => p.id), ['b', 'a']);
    expect(await counterOf(uidA), '2');

    // Deleting a dirty row turns it into one tombstone: still 2 unsynced
    // until Firestore confirms the delete.
    await d.markPendingDelete('b');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(2));
    expect(await counterOf(uidA), '2');
    expect(await d.pendingDeletes(), ['b']);
    // Deleting a clean row adds one.
    await d.markPendingDelete('c1');
    expect(await counterOf(uidA), '3');
    await d.clearPendingDelete('b');
    await d.clearPendingDelete('b'); // repeated confirmation: no-op
    expect(await counterOf(uidA), '2');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(2));
    expect(await d.pendingDeletes(), ['c1']);
    await d.close();
  });

  h.define('counter is reconciled against the rows on open', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    await h.keys.write(DatabaseHelper.unsyncedCounterKeyFor(uidA), '7');
    await d.openFor(uidA);
    expect(await counterOf(uidA), '1');
    await d.close();
    await h.keys.delete(DatabaseHelper.unsyncedCounterKeyFor(uidA));
    await d.openFor(uidA);
    expect(await counterOf(uidA), '1');
    await d.close();
  });

  h.define('counter never under-reports: failed increment makes it unknown, '
      'and if that fails too the save is refused', () async {
    await wipe();
    final counterKey = DatabaseHelper.unsyncedCounterKeyFor(uidA);
    final keys = _FailingKeys(h.keys);
    final d = helper(keys: keys);
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    expect(await counterOf(uidA), '1');

    keys.failWriteOf = counterKey;
    await d.insertPatient(patient('p2'));
    expect(await counterOf(uidA), isNull, reason: 'deleted -> unknown');
    expect((await d.fetchPatients()).length, 2);

    keys.failDeleteOf = counterKey;
    await expectLater(d.insertPatient(patient('p3')),
        throwsA(isA<UnsyncedCounterException>()));
    expect((await d.fetchPatients()).map((p) => p.id), isNot(contains('p3')));

    keys.failWriteOf = null;
    keys.failDeleteOf = null;
    await d.close();
    await d.openFor(uidA);
    expect(await counterOf(uidA), '2', reason: 'reconciled on open');
    await d.close();
  });

  h.define('DB-03/04/05 keyMismatch: count still readable, reset gated by '
      'acknowledged count, then fresh DB and resync', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.insertPatient(patient('p2'));
    await d.close();
    final oldKey = (await keyOf(uidA))!;
    await h.keys.write(DatabaseHelper.keyNameFor(uidA), DatabaseHelper.generateKey());
    final before = File(dbPath(uidA)).readAsBytesSync();
    final kcvBefore = File(kcvPath(uidA)).readAsStringSync();

    await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
    expect((d.state as DbFailed).error, DbOpenError.keyMismatch);
    expect((d.state as DbFailed).canReset, isTrue);
    expect(File(dbPath(uidA)).readAsBytesSync(), before);

    final count = await d.unsyncedCount();
    expect(count, const UnsyncedCount.known(2));
    await expectLater(
        d.resetAndResync(acknowledgedUnsynced: const UnsyncedCount.known(1)),
        throwsA(isA<ResetNotConfirmedException>()));
    expect(File(dbPath(uidA)).readAsBytesSync(), before);

    var resynced = false;
    await d.resetAndResync(
        acknowledgedUnsynced: count, resync: () async => resynced = true);
    expect(resynced, isTrue);
    expect(d.state, isA<DbReady>());
    expect(await d.fetchPatients(), isEmpty);
    expect(await counterOf(uidA), '0');
    await d.close();

    // Reset moved the old file (and its KCV) aside instead of deleting it;
    // it still opens with the old key, which was kept.
    final moved = Directory(dir)
        .listSync()
        .map((e) => e.path)
        .where((f) => p.basename(f).startsWith(
                '${p.basename(dbPath(uidA))}.undecryptable-') &&
            !f.endsWith('.kcv'))
        .toList();
    expect(moved, hasLength(1));
    expect(File(moved.single).readAsBytesSync(), before);
    expect(File(DatabaseHelper.kcvPathFor(moved.single)).readAsStringSync(),
        kcvBefore);
    final old = await h.opener.open(moved.single, key: oldKey);
    expect((await rawRows(old)).length, 2);
    await old.close();
  });

  for (final c in [
    (id: 'MIG-01', name: 'plaintext', cipherKey: null as String?,
        step: DbMigrationStep.encryptingPlaintext, storedKey: null as String?),
    (id: 'MIG-02', name: 'fallback-key', cipherKey: fallbackKey,
        step: DbMigrationStep.rekeyingFromFallback, storedKey: null),
    (id: 'MIG-03', name: 'old prod-key', cipherKey: '0f0e0d0c-0b0a-4908-8706-050403020100',
        step: DbMigrationStep.rekeyingFromLegacyKey,
        storedKey: '0f0e0d0c-0b0a-4908-8706-050403020100'),
  ]) {
    h.define('${c.id} ${c.name} legacy DB is claimed: every row byte-identical, '
        'encrypted under the doctor key, all unsynced, legacy deleted', () async {
      await wipe();
      if (c.storedKey != null) {
        await h.keys.write(DatabaseHelper.legacyKeyName, c.storedKey!);
      }
      final before = await seedLegacy(cipherKey: c.cipherKey);
      expect(isPlainSqlite(legacyPath()), c.cipherKey == null);

      final d = helper();
      final states = <DbOpenState>[];
      final sub = d.states.listen(states.add);
      expect(await d.hasLegacyDb(), isTrue);
      expect(await d.claimLegacyDb(uidA), isTrue);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      final migrating = states.whereType<DbMigrating>().toList();
      expect(migrating.map((s) => s.step).toSet(), contains(c.step));
      final progress = [for (final s in migrating.where((s) => s.step == c.step)) s.progress];
      expect(progress.first, 0.0);
      expect(progress.last, 1.0);
      expect(listEquals(progress, [...progress]..sort()), isTrue);
      expect(states.last, isA<DbReady>());
      expect(d.state.uid, uidA);

      expect(File(legacyPath()).existsSync(), isFalse);
      expect(strayFiles(), isEmpty);
      expect(await d.hasLegacyDb(), isFalse);
      expect(isPlainSqlite(dbPath(uidA)), isFalse);
      final key = (await keyOf(uidA))!;
      expect(await rawHistory(dbPath(uidA), key), before);
      expect(await d.unsyncedCount(), UnsyncedCount.known(before.length));
      expect(await counterOf(uidA), '${before.length}');
      await expectCannotOpen(dbPath(uidA), fallbackKey);
      await expectCannotOpen(dbPath(uidA), null);
      if (c.storedKey != null) {
        expect(await h.keys.read(DatabaseHelper.legacyKeyName), isNull);
      }

      // MIG-06/07: claiming again, or by another doctor, is a no-op.
      expect(await d.claimLegacyDb(uidA), isFalse);
      expect(await d.claimLegacyDb(uidOther), isFalse);
      await d.openFor(uidOther);
      expect(await d.fetchPatients(), isEmpty);
      await d.close();
    });
  }

  h.define('MIG-04 row-count mismatch (via hook) fails safely; retry works',
      () async {
    await wipe();
    await seedLegacy(rows: 10);
    final legacyBefore = File(legacyPath()).readAsBytesSync();
    final d = helper(hook: (point, file) async {
      if (point != MigrationCheckpoint.converted) return;
      final db = await h.opener.open(file, key: (await keyOf(uidA))!);
      await db.delete('patients', where: 'id = ?', whereArgs: ['p3']);
      await db.close();
    });
    await expectLater(d.claimLegacyDb(uidA), throwsA(isA<DbOpenException>()));
    await expectClaimFailedSafely(d, legacyBefore, DbOpenError.migrationFailed);

    final retry = helper();
    expect(await retry.claimLegacyDb(uidA), isTrue);
    expect((await retry.fetchPatients()).length, 10);
    await retry.close();
  });

  for (final point in [
    MigrationCheckpoint.copied,
    MigrationCheckpoint.converted,
    MigrationCheckpoint.verified,
  ]) {
    h.define('claim forced to fail at ${point.name}: legacy untouched', () async {
      await wipe();
      await seedLegacy(cipherKey: fallbackKey, rows: 5);
      final legacyBefore = File(legacyPath()).readAsBytesSync();
      final d = helper(hook: (at, _) async {
        if (at == point) throw StateError('injected failure at ${at.name}');
      });
      await expectLater(d.claimLegacyDb(uidA), throwsA(isA<DbOpenException>()));
      await expectClaimFailedSafely(d, legacyBefore, DbOpenError.migrationFailed);
    });
  }

  h.define('MIG-05 crash right after commit: next launch finishes the claim',
      () async {
    await wipe();
    final before = await seedLegacy(rows: 6);
    final d = helper(hook: (at, _) async {
      if (at == MigrationCheckpoint.committed) throw StateError('killed');
    });
    await expectLater(d.claimLegacyDb(uidA), throwsA(isA<DbOpenException>()));
    expect(File(legacyPath()).existsSync(), isTrue, reason: 'not yet cleaned');

    final relaunch = helper();
    expect(await relaunch.hasLegacyDb(), isFalse);
    expect(File(legacyPath()).existsSync(), isFalse);
    expect(strayFiles(), isEmpty);
    await relaunch.openFor(uidA);
    expect(await rawHistory(dbPath(uidA), (await keyOf(uidA))!), before);
    await relaunch.close();
  });

  h.define('legacy DB under an unknown key: keyMismatch, legacy untouched',
      () async {
    await wipe();
    await seedLegacy(cipherKey: 'some-other-key', rows: 3);
    final legacyBefore = File(legacyPath()).readAsBytesSync();
    final d = helper();
    await expectLater(d.claimLegacyDb(uidA), throwsA(isA<DbOpenException>()));
    await expectClaimFailedSafely(d, legacyBefore, DbOpenError.legacyUnreadable);
    expect((d.state as DbFailed).canReset, isFalse);
  });

  h.define('claim never overwrites a doctor DB that has patients (opens it, '
      'returns false); an empty one is replaced', () async {
    await wipe();
    await seedLegacy(rows: 4);
    final legacyBefore = File(legacyPath()).readAsBytesSync();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('mine'));
    await d.close();
    expect(await d.claimLegacyDb(uidA), isFalse);
    expect(d.state, isA<DbReady>(), reason: "doctor's own DB opened as usual");
    expect(File(legacyPath()).readAsBytesSync(), legacyBefore);
    expect(await d.hasLegacyDb(), isTrue);
    expect((await d.fetchPatients()).single.id, 'mine');
    await d.markPendingDelete('mine');
    await d.close();
    expect(await d.claimLegacyDb(uidA), isFalse,
        reason: 'a pending delete is unsynced: never replaced');
    await d.clearPendingDelete('mine');
    await d.close();

    expect(await d.claimLegacyDb(uidA), isTrue);
    expect((await d.fetchPatients()).length, 4);
    expect(File(legacyPath()).existsSync(), isFalse);
    await d.close();
  });

  h.define('a plaintext doctor DB found in place is encrypted on open',
      () async {
    await wipe();
    final db = await h.opener.openPlaintext(dbPath(uidA),
        version: 2, onCreate: (db, _) async {
      await db.execute(_v1Ddl);
      await db.execute("ALTER TABLE patients ADD COLUMN sync_state TEXT NOT NULL DEFAULT 'dirty'");
      await db.execute('ALTER TABLE patients ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0');
    });
    await db.insert('patients', v1Row(1));
    await db.close();
    expect(isPlainSqlite(dbPath(uidA)), isTrue);

    final d = helper();
    await d.openFor(uidA);
    expect((await d.fetchPatients()).single.id, 'p1');
    await d.close();
    expect(isPlainSqlite(dbPath(uidA)), isFalse);
    expect(strayFiles(), isEmpty);
  });

  // --- key-check value (KCV) ------------------------------------------------

  String expectedKcv(String key, String uid) {
    final raw = [
      for (var i = 0; i < 64; i += 2) int.parse(key.substring(i, i + 2), radix: 16)
    ];
    return 'v1:${Hmac(sha256, raw).convert(utf8.encode('docease-keycheck:$uid'))}';
  }

  h.define('KCV-01 create writes the KCV atomically, keyed with the raw key '
      'bytes (not the hex string); excluded from backup', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    final key = (await keyOf(uidA))!;
    final kcv = File(kcvPath(uidA)).readAsStringSync();
    expect(kcv, expectedKcv(key, uidA));
    final hexKeyed =
        'v1:${Hmac(sha256, utf8.encode(key)).convert(utf8.encode('docease-keycheck:$uidA'))}';
    expect(kcv, isNot(hexKeyed));
    expect(strayFiles(), isEmpty, reason: 'no .kcv.tmp left behind');
    expect(excluder.excluded,
        containsAll([dir, dbPath(uidA), kcvPath(uidA)].map(p.normalize)));
    await d.close();
  });

  h.define('KCV-02 wrong key (KCV mismatch) -> keyMismatch, file untouched',
      () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    await h.keys.write(DatabaseHelper.keyNameFor(uidA), DatabaseHelper.generateKey());
    final before = File(dbPath(uidA)).readAsBytesSync();
    await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
    expect((d.state as DbFailed).error, DbOpenError.keyMismatch);
    expect(File(dbPath(uidA)).readAsBytesSync(), before);
  });

  h.define('KCV-03 corrupt file with the right key -> retryable, no reset, '
      'file untouched', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    final raf = File(dbPath(uidA)).openSync(mode: FileMode.append)
      ..setPositionSync(0)
      ..writeFromSync(List.filled(4096, 0x5a))
      ..closeSync();
    expect(raf, isNotNull);
    final before = File(dbPath(uidA)).readAsBytesSync();
    final keyBefore = await keyOf(uidA);
    await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
    final failed = d.state as DbFailed;
    expect(failed.error, DbOpenError.migrationFailed);
    expect(failed.canReset, isFalse);
    await expectLater(
        d.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
        throwsA(isA<StateError>()));
    expect(File(dbPath(uidA)).readAsBytesSync(), before);
    expect(await keyOf(uidA), keyBefore);
  });

  h.define('KCV-04 missing KCV (earlier build) -> retryable; written after '
      'the next successful open', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    final rightKey = (await keyOf(uidA))!;
    File(kcvPath(uidA)).deleteSync();

    // Missing KCV and an open failure (here: a stored key that does not
    // fit): ambiguous, so retryable, never keyMismatch.
    await h.keys.write(DatabaseHelper.keyNameFor(uidA), DatabaseHelper.generateKey());
    await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
    expect((d.state as DbFailed).error, DbOpenError.migrationFailed);
    expect((d.state as DbFailed).canReset, isFalse);
    expect(File(kcvPath(uidA)).existsSync(), isFalse);

    await h.keys.write(DatabaseHelper.keyNameFor(uidA), rightKey);
    await d.openFor(uidA);
    expect((await d.fetchPatients()).single.id, 'p1');
    expect(File(kcvPath(uidA)).readAsStringSync(), expectedKcv(rightKey, uidA));
    await d.close();
  });

  h.define('KCV-05 the KCV and the key never appear in logs, DbFailed or '
      'exceptions', () async {
    await wipe();
    final logs = <String>[];
    final states = <DbOpenState>[];
    final errors = <Object>[];
    final previous = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) logs.add(m);
    };
    try {
      final d = helper();
      final sub = d.states.listen(states.add);
      Future<void> tryOpen() async {
        try {
          await d.openFor(uidA);
        } catch (e) {
          errors.add(e);
        }
      }
      await d.openFor(uidA);
      await d.insertPatient(patient('p1'));
      await d.close();
      final key = (await keyOf(uidA))!;
      final kcv = File(kcvPath(uidA)).readAsStringSync();
      // Wrong key, then corrupt file, then missing KCV.
      await h.keys.write(DatabaseHelper.keyNameFor(uidA), DatabaseHelper.generateKey());
      await tryOpen();
      await h.keys.write(DatabaseHelper.keyNameFor(uidA), key);
      File(kcvPath(uidA)).deleteSync();
      File(dbPath(uidA)).writeAsBytesSync(List.filled(8192, 7));
      await tryOpen();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      final sensitive = [kcv, kcv.substring(3), key];
      final failed = states.whereType<DbFailed>().toList();
      expect(failed, hasLength(2));
      final texts = [
        ...logs,
        for (final f in failed) ...[f.toString(), '${f.cause}'],
        for (final e in errors) e.toString(),
      ];
      for (final t in texts) {
        for (final value in sensitive) {
          expect(t.contains(value), isFalse, reason: 'leaked in: $t');
        }
      }
    } finally {
      debugPrint = previous;
    }
  });

  h.define('CLS-02 file locked by another connection -> retryable, no reset',
      () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    final locker = await h.opener.open(dbPath(uidA), key: (await keyOf(uidA))!);
    await locker.execute('BEGIN EXCLUSIVE');
    try {
      await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
      expect((d.state as DbFailed).error, DbOpenError.migrationFailed);
      expect((d.state as DbFailed).canReset, isFalse);
    } finally {
      await locker.execute('ROLLBACK');
      await locker.close();
    }
    await d.openFor(uidA);
    expect((await d.fetchPatients()).single.id, 'p1');
    await d.close();
  });

  h.define('CLS-03 unusable database directory -> retryable, never keyMismatch',
      () async {
    await wipe();
    final d = helper(databasesPath: () async => '/proc/docease_nope');
    await expectLater(d.openFor(uidA), throwsA(isA<DbOpenException>()));
    expect((d.state as DbFailed).error, isNot(DbOpenError.keyMismatch));
    expect((d.state as DbFailed).canReset, isFalse);
  });

  h.define('SYNC-01 cloud copy never overwrites a dirty row or undoes a '
      'pending delete; counter unchanged', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(patient('dirty', name: 'Local edit'));
    await d.insertPatient(patient('gone'));
    await d.markPendingDelete('gone');
    expect(await counterOf(uidA), '2');

    expect(await d.applyCloudPatient(patient('dirty', name: 'Cloud')), isFalse);
    expect(await d.applyCloudPatient(patient('gone', name: 'Cloud')), isFalse);
    expect(await d.applyCloudPatient(patient('new', name: 'Cloud')), isTrue);
    expect(await d.applyCloudPatient(patient('new', name: 'Cloud 2')), isTrue,
        reason: 'a clean row is updated');
    expect(await counterOf(uidA), '2');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(2));
    final byId = {for (final p in await d.fetchPatients()) p.id: p};
    expect(byId['dirty']!.name, 'Local edit');
    expect(byId.containsKey('gone'), isFalse);
    expect(byId['new']!.name, 'Cloud 2');
    expect((await d.dirtyPatients()).map((p) => p.id), ['dirty']);
    await d.close();
  });

  h.define('LOW crash leftovers (work copies, KCV temp) are swept on start',
      () async {
    await wipe();
    final base = dbPath(uidA);
    for (final f in ['$base.migrating', '$base.encrypting-journal',
        '${DatabaseHelper.kcvPathFor(base)}.tmp',
        path('${DatabaseHelper.legacyDbFileName}.migrating')]) {
      File(f).writeAsStringSync(uniqueName);
    }
    final d = helper();
    await d.hasLegacyDb();
    expect(strayFiles(), isEmpty);
  });
}

/// Wraps a key store and fails selected operations.
class _FailingKeys implements DbKeyStore {
  _FailingKeys(this._inner, {this.failRead = false});
  final DbKeyStore _inner;
  bool failRead;
  String? failWriteOf;
  String? failDeleteOf;

  @override
  Future<String?> read(String name) {
    if (failRead) throw const OSError('injected read failure');
    return _inner.read(name);
  }

  @override
  Future<void> write(String name, String value) {
    if (name == failWriteOf) throw const OSError('injected write failure');
    return _inner.write(name, value);
  }

  @override
  Future<void> delete(String name) {
    if (name == failDeleteOf) throw const OSError('injected delete failure');
    return _inner.delete(name);
  }
}

class _RecordingExcluder implements BackupExcluder {
  final List<String> excluded = [];
  @override
  Future<void> exclude(String path) async => excluded.add(p.normalize(path));
}
