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
import 'package:sqflite_sqlcipher/sqflite.dart'
    show ConflictAlgorithm, Database;

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

  // --- attachment references (photo sweep) --------------------------------

  const appFiles = '/data/user/0/com.docease.app/files';
  final ownA = LocalDatabase.ownerFolderNameFor(uidA);
  final ownB = LocalDatabase.ownerFolderNameFor(uidB);
  Patient withVisits(String id, List<List<String>> visits) => Patient(
      id: id, name: 'Asha', age: '34', gender: 'Female', phone: '+91999',
      history: [
        for (var i = 0; i < visits.length; i++)
          VisitRecord(
              id: 'v$i-$id', date: DateTime(2026, 1, 1 + i),
              visitType: 'Routine', symptoms: 's', diagnosis: 'd',
              prescription: 'rx', attachmentPaths: visits[i]),
      ]);
  Future<void> markAllSynced(DatabaseHelper d) async {
    for (final p in await d.dirtyPatients()) {
      expect(await d.markSynced(p.id, p.updatedAt!), isTrue);
    }
  }
  Matcher scanFails(AttachmentScanFailure reason) => throwsA(
      isA<AttachmentScanIncomplete>().having((e) => e.reason, 'reason', reason));

  // --- strict reads: an open DB whose read fails must throw, not look empty
  Matcher readFails(DbReadFailure reason) => throwsA(
      isA<DbReadException>().having((e) => e.reason, 'reason', reason));
  const strMarker = 'ZZ-STR-MARKER-91c4';
  // --- swapAttachmentPath: confirmed upload swaps one photo, keeps edits
  const swpUuid = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
  final swpLocal = '$appFiles/attachments/$ownA/$swpUuid.jpg';
  const swpStorage = 'clinical_attachments/$uidA/p1/$swpUuid.jpg';
  Future<bool> swp(DatabaseHelper d,
          {String owner = uidA,
          String patient = 'p1',
          String? localPath,
          String storagePath = swpStorage}) =>
      d.swapAttachmentPath(
          expectedOwner: owner,
          patientId: patient,
          localPath: localPath ?? swpLocal,
          storagePath: storagePath);
  Future<Map<String, Object?>?> rawRow(Database db, String id) async {
    final r = await db.query('patients', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Map.of(r.single);
  }
  Patient edited(Patient p, Map<String, Object?> changes) =>
      Patient.fromJson({...p.toJson(), ...changes});

  h.define('SWP-01 an edit queued during the upload and the swap both '
      'survive (row queue, current row read in the transaction)', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal, 'keep.jpg']]));
    final before = (await d.fetchPatientsStrict()).single;
    // The doctor saves an edit (name + a new visit) while putFile runs;
    // the swap is queued right behind it, nothing awaited in between.
    final json = before.toJson();
    final newVisit = Map<String, Object?>.from(
        (json['history'] as List).single as Map)
      ..['id'] = 'v-new'
      ..['attachmentPaths'] = <String>[];
    final edit = d.updatePatient(edited(before, {
      'name': 'Asha R.',
      'history': [...json['history'] as List, newVisit],
    }));
    final swap = swp(d);
    expect(await edit, isNotNull);
    expect(await swap, isTrue);
    final after = (await d.fetchPatientsStrict()).single;
    expect(after.name, 'Asha R.'); // the edit survived
    expect(after.history.map((v) => v.id), [before.history.single.id, 'v-new']);
    expect(after.history.first.attachmentPaths, [swpStorage, 'keep.jpg']);
    // Reverse order: swap first, then an edit built from the current row.
    await d.insertPatient(withVisits('p2', [[swpLocal]]));
    final s2 = swp(d,
        patient: 'p2', storagePath: 'clinical_attachments/$uidA/p2/$swpUuid.jpg');
    expect(await s2, isTrue);
    final p2 = (await d.fetchPatientsStrict()).singleWhere((p) => p.id == 'p2');
    expect(await d.updatePatient(edited(p2, {'phone': '+91888'})), isNotNull);
    final p2b = (await rawRow(db, 'p2'))!;
    expect(p2b['phone'], '+91888');
    expect(p2b['history'] as String,
        contains('clinical_attachments/$uidA/p2/$swpUuid.jpg'));
    await d.close();
    await wipe();
  });

  h.define('SWP-02 the path in two visits (and aliased stored forms): all '
      'swapped; other entries, visits and fields kept exactly', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    final enc = Uri.file(swpLocal).path;
    final aliasDataData =
        '/data/data/com.docease.app/files/attachments/$ownA/$swpUuid.jpg';
    final otherOwner = '$appFiles/attachments/$ownB/$swpUuid.jpg';
    const legacy = '/storage/emulated/0/DCIM/legacy.jpg';
    await d.insertPatient(withVisits('p1', [
      [swpLocal, legacy],
      ['file://localhost$enc', otherOwner],
      ['$appFiles/attachments/$ownA/other.jpg'],
      [aliasDataData, 'file://$enc'],
    ]));
    // Unknown visit keys must survive byte for byte.
    final raw0 = (await rawRow(db, 'p1'))!;
    final hist = (jsonDecode(raw0['history'] as String) as List)
        .cast<Map<String, dynamic>>();
    hist[2]['zzExtra'] = {'k': [1, 2.5, null]};
    await db.update('patients', {'history': jsonEncode(hist)},
        where: 'id = ?', whereArgs: ['p1']);
    final before = (await rawRow(db, 'p1'))!;
    expect(await swp(d), isTrue);
    final after = (await rawRow(db, 'p1'))!;
    final h2 = (jsonDecode(after['history'] as String) as List)
        .cast<Map<String, dynamic>>();
    expect(h2[0]['attachmentPaths'], [swpStorage, legacy]);
    expect(h2[1]['attachmentPaths'], [swpStorage, otherOwner]);
    expect(h2[3]['attachmentPaths'], [swpStorage, swpStorage]);
    expect(jsonEncode(h2[2]), jsonEncode(hist[2])); // untouched visit
    for (final i in [0, 1, 3]) {
      final a = Map.of(h2[i])..remove('attachmentPaths');
      final b = Map.of(hist[i])..remove('attachmentPaths');
      expect(jsonEncode(a), jsonEncode(b));
    }
    for (final c in ['id', 'name', 'age', 'gender', 'phone', 'relation']) {
      expect(after[c], before[c], reason: c);
    }
    await d.close();
    await wipe();
  });

  h.define('SWP-03 the photo is gone: false, row byte-identical, counter '
      'unchanged', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [['$appFiles/attachments/$ownA/x.jpg']]));
    await d.insertPatient(withVisits('p3', [[swpLocal]])); // other patient
    await markAllSynced(d);
    final before = await rawRow(db, 'p1');
    final c0 = await counterOf(uidA);
    expect(await swp(d), isFalse); // removed before the upload finished
    expect(await rawRow(db, 'p1'), before);
    expect(await counterOf(uidA), c0);
    // Same photo already swapped (repeat confirmation): false, no change.
    await d.insertPatient(withVisits('p2', [[swpLocal]]));
    const sp2 = 'clinical_attachments/$uidA/p2/$swpUuid.jpg';
    expect(await swp(d, patient: 'p2', storagePath: sp2), isTrue);
    final p2 = await rawRow(db, 'p2');
    final c1 = await counterOf(uidA);
    expect(await swp(d, patient: 'p2', storagePath: sp2), isFalse);
    expect(await rawRow(db, 'p2'), p2);
    expect(await counterOf(uidA), c1);
    await d.close();
    await wipe();
  });

  h.define('SWP-04 deleted or tombstoned patient, or no such row: false, '
      'nothing written', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    expect(await swp(d), isFalse); // no such row
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    await d.markPendingDelete('p1');
    final c0 = await counterOf(uidA);
    expect(await swp(d), isFalse);
    expect(await rawRow(db, 'p1'), isNull);
    expect(await d.pendingDeletesStrict(), ['p1']);
    expect(await counterOf(uidA), c0);
    // A row that exists next to a tombstone is still refused.
    await db.insert('patients', {
      'id': 'p1', 'name': 'Asha', 'age': '34', 'gender': 'Female',
      'phone': '+91999', 'relation': 'Self',
      'history': jsonEncode([{'id': 'v', 'date': '2026-01-01T00:00:00.000',
        'attachmentPaths': [swpLocal]}]),
      'sync_state': 'synced', 'updated_at': 1,
    });
    final raw = await rawRow(db, 'p1');
    expect(await swp(d), isFalse);
    expect(await rawRow(db, 'p1'), raw);
    expect(await counterOf(uidA), c0);
    await d.close();
    await wipe();
  });

  h.define('SWP-05 a corrupt row throws unreadableRow (never false) and '
      'writes nothing', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    await markAllSynced(d);
    final c0 = await counterOf(uidA);
    for (final bad in <Object>[
      '{"attachmentPaths": ["$swpLocal"]', // not JSON
      '{"id":"v"}', // not a list
      jsonEncode([{'id': 'v', 'attachmentPaths': swpLocal}]),
      jsonEncode([{'id': 'v', 'date': '2026-01-01T00:00:00.000',
        'attachmentPaths': [swpLocal, 7]}]),
      jsonEncode([{'id': 'v', 'date': 'not a date',
        'attachmentPaths': [swpLocal]}]), // visit would come back flagged
      Uint8List.fromList([1, 2, 3]), // not text
    ]) {
      await db.update('patients', {'history': bad, 'sync_state': 'synced'},
          where: 'id = ?', whereArgs: ['p1']);
      final before = await rawRow(db, 'p1');
      await expectLater(swp(d), readFails(DbReadFailure.unreadableRow));
      expect(await rawRow(db, 'p1'), before);
      expect(await counterOf(uidA), c0);
    }
    // Table gone while the DB counts as open: readFailed, not false.
    await db.execute('DROP TABLE patients');
    await expectLater(swp(d), readFails(DbReadFailure.readFailed));
    await d.close();
    await wipe();
  });

  h.define('SWP-06 counter: +1 exactly once from clean, not again while '
      'dirty; updated_at bumped; markSynced with it clears it', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    final other = '$appFiles/attachments/$ownA/second.jpg';
    await d.insertPatient(withVisits('p1', [[swpLocal], [other]]));
    await d.insertPatient(withVisits('p2', [['$appFiles/attachments/$ownA/z.jpg']]));
    await markAllSynced(d);
    expect(await counterOf(uidA), '0');
    final t0 = (await rawRow(db, 'p1'))!['updated_at'] as int;
    expect(await swp(d), isTrue);
    final r1 = (await rawRow(db, 'p1'))!;
    expect(r1['sync_state'], 'dirty');
    expect(r1['updated_at'] as int, greaterThan(t0));
    expect(await counterOf(uidA), '1');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));
    // Second photo of the same, now dirty, row: no second increment.
    expect(
        await swp(d,
            localPath: other,
            storagePath: 'clinical_attachments/$uidA/p1/second.jpg'),
        isTrue);
    final r2 = (await rawRow(db, 'p1'))!;
    expect(r2['updated_at'] as int, greaterThan(r1['updated_at'] as int));
    expect(await counterOf(uidA), '1');
    // The swap gets pushed: it is in the dirty list with its version.
    final dirty = await d.dirtyPatientsStrict();
    expect(dirty.map((p) => p.id), ['p1']);
    expect(dirty.single.updatedAt, '${r2['updated_at']}');
    expect(await d.markSynced('p1', dirty.single.updatedAt!), isTrue);
    expect(await counterOf(uidA), '0');
    // Unknown counter: rebuilt from the rows inside the transaction (no
    // deadlock), then counts this row once.
    await h.keys.delete(DatabaseHelper.unsyncedCounterKeyFor(uidA));
    await d.insertPatient(withVisits('p4', [['$appFiles/attachments/$ownA/w.jpg']]));
    await markAllSynced(d);
    await h.keys.delete(DatabaseHelper.unsyncedCounterKeyFor(uidA));
    await d.updatePatient(edited(
        (await d.fetchPatientsStrict()).singleWhere((p) => p.id == 'p2'),
        {'phone': '+91777'})); // one dirty row, counter unknown
    await h.keys.delete(DatabaseHelper.unsyncedCounterKeyFor(uidA));
    expect(
        await swp(d,
            patient: 'p4',
            localPath: '$appFiles/attachments/$ownA/w.jpg',
            storagePath: 'clinical_attachments/$uidA/p4/w.jpg'),
        isTrue);
    expect(await counterOf(uidA), '2'); // p2 + p4
    await d.close();
    await wipe();
  });

  h.define('SWP-07 after the swap, referencedAttachmentKeys drops the local '
      'key and keeps the others', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    final other = '$appFiles/attachments/$ownA/other.jpg';
    await d.insertPatient(withVisits('p1', [
      [swpLocal, other],
      ['file://localhost${Uri.file(swpLocal).path}'],
    ]));
    expect(await d.referencedAttachmentKeys(),
        {'attachments/$swpUuid.jpg', 'attachments/other.jpg'});
    expect(await swp(d), isTrue);
    expect(await d.referencedAttachmentKeys(), {'attachments/other.jpg'});
    expect(await d.referencedAttachmentPaths(), {swpStorage, other});
    await d.close();
    await wipe();
  });

  h.define('SWP-08 owner and Storage-path guards: wrong owner or closed DB '
      'throws notOpen; other patient/uid folder or traversal is an '
      'ArgumentError; nothing written', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    await markAllSynced(d);
    final before = await rawRow(db, 'p1');
    final c0 = await counterOf(uidA);
    // Signed in as B while A's DB is still open (the local path is in B's
    // folder so the arguments are valid for B).
    await expectLater(
        swp(d,
            owner: uidB,
            localPath: '$appFiles/attachments/$ownB/$swpUuid.jpg',
            storagePath: 'clinical_attachments/$uidB/p1/$swpUuid.jpg'),
        readFails(DbReadFailure.notOpen));
    for (final sp in [
      'clinical_attachments/$uidA/p2/$swpUuid.jpg', // other patient
      'clinical_attachments/$uidB/p1/$swpUuid.jpg', // other uid
      'clinical_attachments/$uidA/p1/../p2/$swpUuid.jpg', // traversal
      'clinical_attachments/$uidA/../$uidB/p1/$swpUuid.jpg',
      'clinical_attachments/$uidA//$swpUuid.jpg',
      'doctor_profiles/$uidA/$swpUuid.jpg',
    ]) {
      await expectLater(swp(d, storagePath: sp),
          throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'storagePath')),
          reason: sp);
    }
    await expectLater(
        swp(d, localPath: '$appFiles/attachments/$ownB/$swpUuid.jpg'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'localPath')));
    expect(await rawRow(db, 'p1'), before);
    expect(await counterOf(uidA), c0);
    await d.close();
    await expectLater(swp(d), readFails(DbReadFailure.notOpen));
    // Reopened as B: A's swap is refused, B's DB untouched.
    final dB = helper();
    await dB.openFor(uidB);
    await expectLater(swp(dB), readFails(DbReadFailure.notOpen));
    expect(await dB.fetchPatientsStrict(), isEmpty);
    await dB.close();
    await wipe();
  });

  // --- attachment_swaps: stale whole-row saves keep the uploaded path
  Future<List<Map<String, Object?>>> swapRows(Database db) =>
      db.query('attachment_swaps', orderBy: 'patient_id, local_key');
  Patient withDiagnosis(Patient p, String diagnosis) {
    final json = p.toJson();
    final hist = [
      for (final v in json['history'] as List)
        Map<String, Object?>.from(v as Map)..['diagnosis'] = diagnosis,
    ];
    return Patient.fromJson({...json, 'history': hist});
  }
  List<List<String>> storedPaths(Map<String, Object?> row) => [
        for (final v in jsonDecode(row['history'] as String) as List)
          List<String>.from((v as Map)['attachmentPaths'] as List),
      ];

  h.define('SWQ-01 attachment_swaps table: fresh v2 create and v1 -> v2 '
      'upgrade; a swap records its mapping in the same transaction',
      () async {
    await wipe();
    final v1 = helper(schemaVersion: 1);
    final db1 = await v1.openFor(uidA);
    expect(await tableNames(db1), isNot(contains('attachment_swaps')));
    await db1.insert('patients', v1Row(0));
    await v1.close();
    final d = helper();
    final db = await d.openFor(uidA);
    expect(await tableNames(db), contains('attachment_swaps'));
    expect(await rawRows(db), hasLength(1));
    final cols = await db.rawQuery('PRAGMA table_info(attachment_swaps)');
    expect({for (final c in cols) c['name']: (c['type'], c['notnull'], c['pk'])}, {
      'patient_id': ('TEXT', 1, 1),
      'local_key': ('TEXT', 1, 2),
      'storage_path': ('TEXT', 1, 0),
      'swapped_at': ('INTEGER', 1, 0),
    });
    await d.close();
    await wipe();
    final f = helper();
    final fdb = await f.openFor(uidA);
    expect(await tableNames(fdb), contains('attachment_swaps'));
    expect(await swapRows(fdb), isEmpty);
    await f.insertPatient(withVisits('p1', [[swpLocal]]));
    final t0 = DateTime.now().millisecondsSinceEpoch;
    expect(await swp(f), isTrue);
    final rows = await swapRows(fdb);
    expect(rows, hasLength(1));
    expect(rows.single['patient_id'], 'p1');
    expect(rows.single['local_key'], 'attachments/$swpUuid.jpg');
    expect(rows.single['storage_path'], swpStorage);
    expect(rows.single['swapped_at'] as int, greaterThanOrEqualTo(t0));
    // A false swap records nothing.
    expect(await swp(f, patient: 'p9',
        storagePath: 'clinical_attachments/$uidA/p9/$swpUuid.jpg'), isFalse);
    expect(await swapRows(fdb), hasLength(1));
    await f.close();
    await wipe();
  });

  h.define('SWQ-02 swap, then a stale updatePatient / insertPatient '
      'carrying the local path (or an alias): the DB keeps the Storage '
      'path', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    final newPhoto = '$appFiles/attachments/$ownA/new.jpg';
    await d.insertPatient(withVisits('p1', [[swpLocal, newPhoto]]));
    final stale = (await d.fetchPatientsStrict()).single; // the form's copy
    expect(await swp(d), isTrue);
    expect(await d.updatePatient(stale), isNotNull);
    expect(storedPaths((await rawRow(db, 'p1'))!), [[swpStorage, newPhoto]]);
    expect(await d.insertPatient(stale), isNotNull); // insert-or-replace
    expect(storedPaths((await rawRow(db, 'p1'))!), [[swpStorage, newPhoto]]);
    final aliased = Patient.fromJson({
      ...stale.toJson(),
      'history': [
        {...stale.history.single.toJson(),
          'attachmentPaths': ['file://localhost${Uri.file(swpLocal).path}',
            '/data/data/com.docease.app/files/attachments/$ownA/$swpUuid.jpg',
            newPhoto]},
      ],
    });
    expect(await d.updatePatient(aliased), isNotNull);
    expect(storedPaths((await rawRow(db, 'p1'))!),
        [[swpStorage, swpStorage, newPhoto]]);
    expect(await d.referencedAttachmentKeys(), {'attachments/new.jpg'});
    await d.close();
    await wipe();
  });

  h.define('SWQ-03 a stale save that also changed a diagnosis keeps both '
      'the diagnosis and the Storage path; still one dirty count', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    await markAllSynced(d);
    final stale = (await d.fetchPatientsStrict()).single;
    expect(await swp(d), isTrue);
    expect(await counterOf(uidA), '1');
    final v = await d.updatePatient(withDiagnosis(stale, 'Dengue, revised'));
    expect(v, isNotNull);
    final row = (await rawRow(db, 'p1'))!;
    expect(storedPaths(row), [[swpStorage]]);
    final visit = (jsonDecode(row['history'] as String) as List).single as Map;
    expect(visit['diagnosis'], 'Dengue, revised');
    expect(row['sync_state'], 'dirty');
    expect('${row['updated_at']}', v);
    expect(await counterOf(uidA), '1');
    final dirty = (await d.dirtyPatientsStrict()).single;
    expect(dirty.history.single.attachmentPaths, [swpStorage]);
    expect(await d.markSynced('p1', dirty.updatedAt!), isTrue);
    await d.close();
    await wipe();
  });

  h.define('SWQ-04 other patients are not affected; a mapping whose path '
      'left the owner/patient folder is not applied', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    await d.insertPatient(withVisits('p2', [[swpLocal]])); // same local file
    final staleP2 = (await d.fetchPatientsStrict()).singleWhere((p) => p.id == 'p2');
    expect(await swp(d), isTrue); // p1 only
    expect(await d.updatePatient(staleP2), isNotNull);
    expect(storedPaths((await rawRow(db, 'p2'))!), [[swpLocal]]);
    expect(await d.insertPatient(withVisits('p3', [[swpLocal]])), isNotNull);
    expect(storedPaths((await rawRow(db, 'p3'))!), [[swpLocal]]);
    // Tampered mappings for p2: other patient's / other uid's folder,
    // traversal. None is applied.
    for (final bad in [
      'clinical_attachments/$uidA/p1/$swpUuid.jpg',
      'clinical_attachments/$uidB/p2/$swpUuid.jpg',
      'clinical_attachments/$uidA/p2/../p1/$swpUuid.jpg',
      'https://example.com/$swpUuid.jpg',
    ]) {
      await db.insert('attachment_swaps', {
        'patient_id': 'p2', 'local_key': 'attachments/$swpUuid.jpg',
        'storage_path': bad, 'swapped_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      expect(await d.updatePatient(staleP2), isNotNull);
      expect(storedPaths((await rawRow(db, 'p2'))!), [[swpLocal]], reason: bad);
    }
    await d.close();
    await wipe();
  });

  h.define('SWQ-05 deleting a patient clears its mappings in the tombstone '
      'transaction; other patients keep theirs', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    await d.insertPatient(withVisits('p2', [[swpLocal]]));
    expect(await swp(d), isTrue);
    expect(await swp(d, patient: 'p2',
        storagePath: 'clinical_attachments/$uidA/p2/$swpUuid.jpg'), isTrue);
    expect((await swapRows(db)).map((r) => r['patient_id']), ['p1', 'p2']);
    await d.markPendingDelete('p1');
    expect((await swapRows(db)).map((r) => r['patient_id']), ['p2']);
    expect(await d.pendingDeletesStrict(), ['p1']);
    // A failed delete keeps the mapping (same transaction).
    await db.execute('DROP TABLE pending_deletes');
    await expectLater(d.markPendingDelete('p2'), throwsA(anything));
    expect((await swapRows(db)).map((r) => r['patient_id']), ['p2']);
    expect(await rawRow(db, 'p2'), isNotNull);
    await d.close();
    await wipe();
  });

  h.define('SWQ-06 mappings older than 30 days are pruned on open; newer '
      'ones stay', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    final now = DateTime.now().millisecondsSinceEpoch;
    const day = 24 * 60 * 60 * 1000;
    expect(DatabaseHelper.attachmentSwapRetention, const Duration(days: 30));
    for (final (pid, age) in [('old', 31 * day), ('edge', 30 * day + 60000),
        ('recent', 29 * day), ('fresh', 0)]) {
      await db.insert('attachment_swaps', {
        'patient_id': pid, 'local_key': 'attachments/$pid.jpg',
        'storage_path': 'clinical_attachments/$uidA/$pid/$pid.jpg',
        'swapped_at': now - age,
      });
    }
    await d.close();
    final db2 = await d.openFor(uidA);
    expect((await swapRows(db2)).map((r) => r['patient_id']).toSet(),
        {'recent', 'fresh'});
    await d.close();
    await wipe();
  });

  h.define('SWQ-07 a cloud merge is never rewritten; the scans ignore '
      'mappings', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    final stale = (await d.fetchPatientsStrict()).single;
    expect(await swp(d), isTrue);
    await markAllSynced(d);
    expect(await d.applyCloudPatient(stale), isTrue); // clean row: applied
    expect(storedPaths((await rawRow(db, 'p1'))!), [[swpLocal]]);
    await markAllSynced(d);
    expect(await d.insertPatient(stale, fromCloud: true), isNotNull);
    expect(storedPaths((await rawRow(db, 'p1'))!), [[swpLocal]]);
    expect((await rawRow(db, 'p1'))!['sync_state'], 'synced');
    // Mappings are not references: a mapping for a row-less patient adds
    // nothing to either scan.
    await db.insert('attachment_swaps', {
      'patient_id': 'ghost', 'local_key': 'attachments/ghost.jpg',
      'storage_path': 'clinical_attachments/$uidA/ghost/ghost.jpg',
      'swapped_at': DateTime.now().millisecondsSinceEpoch,
    });
    expect(await d.referencedAttachmentKeys(), {'attachments/$swpUuid.jpg'});
    expect(await d.referencedAttachmentPaths(), {swpLocal});
    await d.markPendingDelete('p1');
    expect(await d.referencedAttachmentKeys(), isEmpty);
    expect(await d.referencedAttachmentPaths(), isEmpty);
    await d.close();
    await wipe();
  });

  h.define('SWQ-08 security regression: edit-details stale copy after a '
      'swap keeps the Storage path, the new name/phone and every visit',
      () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    final other = '$appFiles/attachments/$ownA/other.jpg';
    // 1. Saved patient with a visit holding local path L; the details
    //    screen captures its copy.
    await d.insertPatient(withVisits('p1', [[swpLocal], [other]]));
    final stale = (await d.fetchPatientsStrict()).single;
    // 2. The upload confirms: L -> S.
    expect(await swp(d), isTrue);
    // 3. Details save from the stale copy: only name and phone changed,
    //    history exactly as captured (still holding L).
    final edited = Patient.fromJson({
      ...stale.toJson(),
      'name': 'Asha Renamed',
      'phone': '+910000000001',
    });
    expect(edited.history.first.attachmentPaths, [swpLocal]);
    expect(await d.updatePatient(edited), isNotNull);
    // 4. Stored row: S not L, new details kept, every visit present.
    final row = (await rawRow(db, 'p1'))!;
    expect(row['name'], 'Asha Renamed');
    expect(row['phone'], '+910000000001');
    expect(storedPaths(row), [[swpStorage], [other]]);
    expect((jsonDecode(row['history'] as String) as List)
        .map((v) => (v as Map)['id']), stale.history.map((v) => v.id));
    expect(row['history'], isNot(contains(swpLocal)));
    final keys = await d.referencedAttachmentKeys();
    expect(keys, isNot(contains('attachments/$swpUuid.jpg')));
    expect(keys, {'attachments/other.jpg'});
    await d.close();
    await wipe();
  });

  h.define('SWQ-09 characterization (not fixed in the DB): a stale copy '
      'captured before the visit existed drops that visit on save', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', []));
    final stale = (await d.fetchPatientsStrict()).single; // no visits yet
    // A visit with photo L is added, then its upload confirms.
    await d.updatePatient(withVisits('p1', [[swpLocal]]));
    expect(await swp(d), isTrue);
    expect(storedPaths((await rawRow(db, 'p1'))!), [[swpStorage]]);
    // Details save from the pre-visit copy.
    expect(
        await d.updatePatient(
            Patient.fromJson({...stale.toJson(), 'name': 'Asha Renamed'})),
        isNotNull);
    final row = (await rawRow(db, 'p1'))!;
    // Today's behaviour: the whole-row write replaces history, so the
    // visit (and its uploaded S) is gone from the row; the save references
    // neither L nor S, so the mapping is dropped too (SWQ-10); the scan no
    // longer references the photo.
    expect(row['name'], 'Asha Renamed');
    expect(jsonDecode(row['history'] as String), isEmpty);
    expect(row['sync_state'], 'dirty');
    expect(await swapRows(db), isEmpty);
    expect(await d.referencedAttachmentKeys(), isEmpty);
    await d.close();
    await wipe();
  });

  h.define('SWQ-10 a save that removes the photo drops its mapping, so a '
      'later stale pre-upload copy keeps L (no Storage reference comes '
      'back); a save still holding S keeps it', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    final other = '$appFiles/attachments/$ownA/other.jpg';
    await d.insertPatient(withVisits('p1', [[swpLocal, other]]));
    await d.insertPatient(withVisits('p2', [[swpLocal]]));
    final staleP1 = (await d.fetchPatientsStrict())
        .singleWhere((p) => p.id == 'p1'); // pre-upload copy, holds L
    expect(await swp(d), isTrue);
    final s2 = 'clinical_attachments/$uidA/p2/$swpUuid.jpg';
    expect(await swp(d, patient: 'p2', storagePath: s2), isTrue);
    expect((await swapRows(db)).map((r) => r['patient_id']), ['p1', 'p2']);
    // The doctor removes the photo from p1.
    expect(await d.updatePatient(withVisits('p1', [[other]])), isNotNull);
    expect((await swapRows(db)).map((r) => r['patient_id']), ['p2'],
        reason: "p1's mapping dropped, p2's untouched");
    // A stale pre-upload copy is saved later: L stays L.
    expect(await d.updatePatient(staleP1), isNotNull);
    final row = (await rawRow(db, 'p1'))!;
    expect(storedPaths(row), [[swpLocal, other]]);
    expect(row['history'], isNot(contains('clinical_attachments/')));
    expect(await swapRows(db), hasLength(1));
    // p2: a save that still holds S (the current row, renamed) keeps the
    // mapping; so does insertPatient with an alias of L (rewritten to S).
    final current = (await d.fetchPatientsStrict())
        .singleWhere((p) => p.id == 'p2');
    expect(current.history.single.attachmentPaths, [s2]);
    expect(await d.updatePatient(
        Patient.fromJson({...current.toJson(), 'name': 'Asha Renamed'})),
        isNotNull);
    expect((await swapRows(db)).single['storage_path'], s2);
    expect(await d.insertPatient(withVisits('p2',
        [['file://localhost${Uri.file(swpLocal).path}']])), isNotNull);
    expect(storedPaths((await rawRow(db, 'p2'))!), [[s2]]);
    expect((await swapRows(db)).single['patient_id'], 'p2');
    // insertPatient that removes it drops it too.
    expect(await d.insertPatient(withVisits('p2', [[]])), isNotNull);
    expect(await swapRows(db), isEmpty);
    await d.close();
    await wipe();
  });

  h.define('SWQ-11 markSynced backstop: a push snapshot from '
      'dirtyPatientsStrict is refused after a local edit or a swap; the '
      'row stays dirty and the counter is unchanged', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [[swpLocal]]));
    expect(await counterOf(uidA), '1');
    // Snapshot for the push, then a local edit before the confirmation.
    final snap = (await d.dirtyPatientsStrict()).single;
    final v2 = await d.updatePatient(
        Patient.fromJson({...snap.toJson(), 'name': 'Asha Edited'}));
    expect(v2, isNot(snap.updatedAt));
    expect(await d.markSynced('p1', snap.updatedAt!), isFalse);
    var row = (await rawRow(db, 'p1'))!;
    expect(row['sync_state'], 'dirty');
    expect('${row['updated_at']}', v2);
    expect(row['name'], 'Asha Edited');
    expect(await counterOf(uidA), '1');
    // Same after a swap that happened after the snapshot.
    final snap2 = (await d.dirtyPatientsStrict()).single;
    expect(await swp(d), isTrue);
    expect(await d.markSynced('p1', snap2.updatedAt!), isFalse);
    row = (await rawRow(db, 'p1'))!;
    expect(row['sync_state'], 'dirty');
    expect(storedPaths(row), [[swpStorage]]);
    expect(await counterOf(uidA), '1');
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));
    // The current snapshot is accepted, exactly once.
    final latest = (await d.dirtyPatientsStrict()).single;
    expect(latest.history.single.attachmentPaths, [swpStorage]);
    expect(await d.markSynced('p1', latest.updatedAt!), isTrue);
    expect(await counterOf(uidA), '0');
    expect(await d.markSynced('p1', latest.updatedAt!), isFalse);
    expect(await counterOf(uidA), '0');
    await d.close();
    await wipe();
  });

  h.define('STR-01 healthy DB: strict reads equal the lenient ones; an '
      'empty DB gives empty, not an error', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    expect(await d.fetchPatientsStrict(), isEmpty);
    expect(await d.dirtyPatientsStrict(), isEmpty);
    expect(await d.pendingDeletesStrict(), isEmpty);
    await d.insertPatient(patient('p1'));
    await d.insertPatient(withVisits('p2', [['$strMarker.jpg']]));
    await d.insertPatient(patient('p3'));
    await d.markPendingDelete('p3');
    List<String> ids(List<Patient> l) => l.map((p) => p.id).toList();
    expect(ids(await d.fetchPatientsStrict()), ids(await d.fetchPatients()));
    expect(ids(await d.fetchPatientsStrict()), unorderedEquals(['p1', 'p2']));
    expect(ids(await d.dirtyPatientsStrict()), ids(await d.dirtyPatients()));
    expect(await d.pendingDeletesStrict(), ['p3']);
    expect(await d.pendingDeletesStrict(), await d.pendingDeletes());
    await d.close();
  });
  h.define('STR-02 table dropped while the DB counts as open: strict reads '
      'throw readFailed, lenient ones still return empty', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.insertPatient(patient('p2'));
    await d.markPendingDelete('p2');
    final counterBefore = await counterOf(uidA);
    await db.execute('DROP TABLE patients');
    await db.execute('DROP TABLE pending_deletes');
    expect(d.state, isA<DbReady>()); // still "open"
    expect(d.openUid, uidA);
    await expectLater(
        d.fetchPatientsStrict(), readFails(DbReadFailure.readFailed));
    await expectLater(
        d.dirtyPatientsStrict(), readFails(DbReadFailure.readFailed));
    await expectLater(
        d.pendingDeletesStrict(), readFails(DbReadFailure.readFailed));
    // Lenient behaviour unchanged: looks exactly like "no patients".
    expect(await d.fetchPatients(), isEmpty);
    expect(await d.dirtyPatients(), isEmpty);
    expect(await d.pendingDeletes(), isEmpty);
    expect(d.state, isA<DbReady>());
    expect(await counterOf(uidA), counterBefore); // reads never touch it
    await d.close();
    await wipe();
  });
  h.define('STR-03 one corrupt history row: strict reads throw '
      'unreadableRow (no patient data), lenient ones list it flagged',
      () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.insertPatient(withVisits('p2', [['a.jpg']]));
    await d.insertPatient(patient('p3'));
    await db.update('patients', {'history': '{"$strMarker": [broken', 'name': strMarker},
        where: 'id = ?', whereArgs: ['p2']);
    final errors = <Object>[];
    for (final read in [d.fetchPatientsStrict, d.dirtyPatientsStrict]) {
      try {
        await read();
        fail('expected DbReadException');
      } on DbReadException catch (e) {
        expect(e.reason, DbReadFailure.unreadableRow);
        errors.add(e);
      }
    }
    for (final e in errors) {
      expect(e.toString(), isNot(contains(strMarker)));
      expect(e.toString(), isNot(contains('p2')));
    }
    // Lenient: every row, the bad one flagged (unchanged behaviour).
    final lenient = await d.fetchPatients();
    expect(lenient, hasLength(3));
    expect(lenient.singleWhere((p) => p.id == 'p2').hasParseErrors, isTrue);
    expect((await d.dirtyPatients()).map((p) => p.id),
        unorderedEquals(['p1', 'p2', 'p3']));
    // A clean, synced corrupt row: dirtyPatientsStrict has nothing to
    // refuse, fetchPatientsStrict still does.
    await markAllSynced(d);
    await db.update('patients', {'sync_state': 'synced'},
        where: 'id = ?', whereArgs: ['p2']);
    expect(await d.dirtyPatientsStrict(), isEmpty);
    await expectLater(
        d.fetchPatientsStrict(), readFails(DbReadFailure.unreadableRow));
    await d.close();
    await wipe();
  });
  h.define('STR-04 one unreadable tombstone: pendingDeletesStrict throws '
      'unreadableRow; lenient pendingDeletes hides or passes it', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.markPendingDelete('p1');
    expect(await d.pendingDeletesStrict(), ['p1']);
    // An empty id: lenient returns it as is, strict refuses the answer.
    await db.execute(
        "INSERT INTO pending_deletes (patient_id, deleted_at) VALUES ('', 1)");
    await expectLater(
        d.pendingDeletesStrict(), readFails(DbReadFailure.unreadableRow));
    expect(await d.pendingDeletes(), ['', 'p1']);
    // An id that is not text: lenient returns empty, hiding 'p1' too.
    await db.execute("DELETE FROM pending_deletes WHERE patient_id = ''");
    await db.execute("INSERT INTO pending_deletes (patient_id, deleted_at) "
        "VALUES (X'00ff', 2)");
    await expectLater(
        d.pendingDeletesStrict(), readFails(DbReadFailure.unreadableRow));
    expect(await d.pendingDeletes(), isEmpty);
    await d.close();
    await wipe();
  });
  h.define('STR-05 closed, never opened, or open failed: strict reads '
      'throw notOpen', () async {
    await wipe();
    final d = helper();
    for (final read in [
      d.fetchPatientsStrict,
      d.dirtyPatientsStrict,
      d.pendingDeletesStrict,
    ]) {
      await expectLater(read(), readFails(DbReadFailure.notOpen));
    }
    await d.openFor(uidA);
    await d.insertPatient(patient('p1'));
    await d.close();
    await expectLater(
        d.fetchPatientsStrict(), readFails(DbReadFailure.notOpen));
    // Failed open (wrong key -> keyMismatch): still notOpen, lenient empty.
    await h.keys.write(DatabaseHelper.keyNameFor(uidA), 'ab' * 32);
    final d2 = helper();
    await expectLater(d2.openFor(uidA), throwsA(isA<DbOpenException>()));
    expect(d2.state, isA<DbFailed>());
    await expectLater(
        d2.fetchPatientsStrict(), readFails(DbReadFailure.notOpen));
    await expectLater(
        d2.pendingDeletesStrict(), readFails(DbReadFailure.notOpen));
    expect(await d2.fetchPatients(), isEmpty);
    await wipe();
  });
  h.define('ATT-01 mix of patients/visits, dirty rows and the doctor photo: '
      'exact paths, keys, read only', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [])); // no visits
    await d.insertPatient(withVisits('p2', [
      ['$appFiles/attachments/$ownA/a1.jpg',
       'clinical_attachments/$uidA/p2/up.jpg',
       'https://firebasestorage.googleapis.com/v0/b/x/o/clinical_attachments'
           '%2F$uidA%2Fp2%2Fold.jpg?alt=media&token=t'],
    ]));
    await d.insertPatient(withVisits('p3', [
      [], // visit without attachments
      ['file:///data/data/com.docease.app/files/attachments/$ownA/a%20b.jpg', ''],
    ]));
    await markAllSynced(d);
    // Dirty (unsynced) row: must be included.
    await d.insertPatient(withVisits('p4', [
      ['/data/data/com.docease.app/files/attachments/$ownA/dirty.png'],
    ]));
    await d.putSetting('doctor_profile', jsonEncode({
      'name': 'Dr A',
      'profileImageUrl': '$appFiles/profile/$ownA/avatar_1.png',
    }));
    await d.putSetting('medicines', '["Paracetamol"]');

    final rowsBefore = await rawRows(db);
    final settingsBefore = await db.query('settings', orderBy: 'key');
    final counterBefore = await counterOf(uidA);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));
    expect((await d.dirtyPatients()).map((p) => p.id), ['p4']);

    final expectedPaths = {
      '$appFiles/attachments/$ownA/a1.jpg',
      'clinical_attachments/$uidA/p2/up.jpg',
      'https://firebasestorage.googleapis.com/v0/b/x/o/clinical_attachments'
          '%2F$uidA%2Fp2%2Fold.jpg?alt=media&token=t',
      'file:///data/data/com.docease.app/files/attachments/$ownA/a%20b.jpg',
      '',
      '/data/data/com.docease.app/files/attachments/$ownA/dirty.png',
      '$appFiles/profile/$ownA/avatar_1.png',
    };
    const expectedKeys = {
      'attachments/a1.jpg',
      'attachments/a b.jpg', // file:// parsed, percent-decoded
      'attachments/dirty.png', // dirty row included
      'profile/avatar_1.png',
    };
    expect(await d.referencedAttachmentPaths(), expectedPaths);
    expect(await d.referencedAttachmentKeys(), expectedKeys);

    // Read only: rows (sync_state, updated_at), settings, counter unchanged.
    expect(await rawRows(db), rowsBefore);
    expect(await db.query('settings', orderBy: 'key'), settingsBefore);
    expect(await counterOf(uidA), counterBefore);
    expect(await d.unsyncedCount(), const UnsyncedCount.known(1));

    // Persisted: same answer after close and reopen.
    await d.close();
    await d.openFor(uidA);
    expect(await d.referencedAttachmentPaths(), expectedPaths);
    expect(await d.referencedAttachmentKeys(), expectedKeys);
    await d.close();
  });

  h.define('ATT-02 an empty DB (and one with no attachments) gives an empty '
      'set', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    expect(await d.referencedAttachmentPaths(), isEmpty);
    expect(await d.referencedAttachmentKeys(), isEmpty);
    await d.insertPatient(withVisits('p1', [[], []]));
    await d.insertPatient(patient('p2'));
    await d.putSetting('doctor_profile', '{"name":"Dr A"}');
    expect(await d.referencedAttachmentPaths(), isEmpty);
    expect(await d.referencedAttachmentKeys(), isEmpty);
    await d.close();
  });

  h.define('ATT-03 one corrupt row or attachment JSON throws; never a '
      'partial set', () async {
    await wipe();
    final d = helper();
    final db = await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [['$appFiles/attachments/$ownA/1.jpg']]));
    await d.insertPatient(withVisits('p2', [['$appFiles/attachments/$ownA/2.jpg']]));
    await d.insertPatient(withVisits('p3', [['$appFiles/attachments/$ownA/3.jpg']]));
    final counterBefore = await counterOf(uidA);

    Future<void> corrupt(String history) =>
        db.update('patients', {'history': history},
            where: 'id = ?', whereArgs: ['p2']);

    await corrupt(jsonEncode([
      {'id': 'v', 'attachmentPaths': '$appFiles/attachments/$ownA/2.jpg'}
    ]));
    await expectLater(d.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.unreadableAttachmentList));
    await expectLater(d.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.unreadableAttachmentList));

    await corrupt(jsonEncode([
      {'id': 'v', 'attachmentPaths': ['$appFiles/attachments/$ownA/2.jpg', 5]}
    ]));
    await expectLater(d.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.unreadableAttachmentList));

    await corrupt('[{"id":"v","attachmentPaths":["x"');
    await expectLater(d.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.unreadableRow));
    await expectLater(d.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.unreadableRow));

    await d.putSetting('doctor_profile', '{"profileImageUrl":');
    await corrupt(jsonEncode([]));
    await expectLater(d.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.unreadableDoctorProfile));
    await d.deleteSetting('doctor_profile');

    // Repaired: the full set comes back.
    expect(await d.referencedAttachmentPaths(), {
      '$appFiles/attachments/$ownA/1.jpg',
      '$appFiles/attachments/$ownA/3.jpg',
    });
    expect(await counterOf(uidA), counterBefore);
    await d.close();
  });

  h.define("ATT-04 keys: another owner's path or a legacy/unknown local path "
      'throws; web links and Storage refs are skipped', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [
      ['$appFiles/attachments/$ownA/mine.jpg',
       'gs://x.appspot.com/clinical_attachments/$uidA/p1/a.jpg',
       'http://example.com/a.jpg',
       'doctor_profiles/$uidA/1700000000.jpg'],
    ]));
    expect(await d.referencedAttachmentKeys(), {'attachments/mine.jpg'});

    await d.insertPatient(withVisits('p2', [['$appFiles/attachments/$ownB/theirs.jpg']]));
    expect(await d.referencedAttachmentPaths(),
        contains('$appFiles/attachments/$ownB/theirs.jpg'));
    await expectLater(d.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.unrecognisedPath));

    await d.insertPatient(withVisits('p2', [
      ['/data/user/0/com.docease.app/cache/image_picker4211.jpg'],
    ]));
    await expectLater(d.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.unrecognisedPath));

    await d.insertPatient(withVisits('p2', [[]]));
    expect(await d.referencedAttachmentKeys(), {'attachments/mine.jpg'});

    // The same stored path keys differently under the other owner's DB.
    await d.openFor(uidB);
    await d.insertPatient(withVisits('q1', [['$appFiles/attachments/$ownB/theirs.jpg']]));
    expect(await d.referencedAttachmentKeys(), {'attachments/theirs.jpg'});
    await d.close();
  });

  h.define('ATT-06 file://localhost and file:/// key like the absolute '
      'path; any other host makes the DB scan throw', () async {
    await wipe();
    final d = helper();
    await d.openFor(uidA);
    const uuid = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
    final abs = '$appFiles/attachments/$ownA/$uuid.jpg';
    final enc = Uri.file(abs).path;
    await d.insertPatient(withVisits('p1', [
      [abs, 'file://$enc'],
      ['file://localhost$enc'],
    ]));
    expect(await d.referencedAttachmentKeys(), {'attachments/$uuid.jpg'});
    final evil = 'file://evil$enc';
    await d.insertPatient(withVisits('p2', [[evil]]));
    expect(await d.referencedAttachmentPaths(),
        {abs, 'file://$enc', 'file://localhost$enc', evil}); // as stored
    await expectLater(d.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.unrecognisedPath));
    await d.close();
  });
  h.define('ATT-05 scan throws when no DB is open or the open failed', () async {
    await wipe();
    final none = helper();
    await expectLater(none.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.noDatabase));
    await expectLater(none.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.noDatabase));
    expect(File(dbPath(uidA)).existsSync(), isFalse);

    final d = helper();
    await d.openFor(uidA);
    await d.insertPatient(withVisits('p1', [['$appFiles/attachments/$ownA/1.jpg']]));
    await d.close();
    await expectLater(d.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.noDatabase));

    final failed = helper(keys: _FailingKeys(h.keys, failRead: true));
    await expectLater(failed.openFor(uidA), throwsA(isA<DbOpenException>()));
    await expectLater(failed.referencedAttachmentPaths(),
        scanFails(AttachmentScanFailure.openFailed));
    await expectLater(failed.referencedAttachmentKeys(),
        scanFails(AttachmentScanFailure.openFailed));
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
