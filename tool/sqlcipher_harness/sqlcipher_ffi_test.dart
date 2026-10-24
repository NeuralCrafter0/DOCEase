// Host entry point for the real-SQLCipher suite. Not run by a plain
// `flutter test`: tool/sqlcipher_harness/run.sh copies the repo to a temp
// dir, adds sqflite_common_ffi + the sqlite3 "system sqlcipher" hook config
// to that copy, places this file in its test/ dir and runs it there.
// The test bodies live in integration_test/support/db_suite.dart (shared
// with the device test integration_test/db_encryption_migration_test.dart).
import 'dart:io';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:sqflite_sqlcipher/sqflite.dart'
    show Database, OnDatabaseCreateFn, OnDatabaseVersionChangeFn;

import '../integration_test/support/db_suite.dart';

class MemKeys implements DbKeyStore {
  final m = <String, String>{};
  @override
  Future<String?> read(String n) async => m[n];
  @override
  Future<void> write(String n, String v) async => m[n] = v;
  @override
  Future<void> delete(String n) async => m.remove(n);
}

/// Opens SQLCipher files through FFI the way the plugin does on device:
/// PRAGMA key first, then a read that fails if the key does not decrypt.
class FfiOpener implements CipherDatabaseOpener {
  @override
  Future<Database> openPlaintext(String path,
      {int? version, OnDatabaseCreateFn? onCreate}) {
    return ffi.databaseFactoryFfiNoIsolate.openDatabase(path,
        options: ffi.OpenDatabaseOptions(
            singleInstance: false, version: version, onCreate: onCreate));
  }

  @override
  Future<Database> open(String path,
      {required String key,
      int? version,
      OnDatabaseCreateFn? onCreate,
      OnDatabaseVersionChangeFn? onUpgrade,
      OnDatabaseVersionChangeFn? onDowngrade}) async {
    return ffi.databaseFactoryFfiNoIsolate.openDatabase(path,
        options: ffi.OpenDatabaseOptions(
          singleInstance: false,
          version: version,
          onCreate: onCreate,
          onUpgrade: onUpgrade,
          onDowngrade: onDowngrade,
          onConfigure: (db) async {
            if (key.isEmpty) throw ArgumentError('empty key');
            await db.rawQuery("PRAGMA key = '${key.replaceAll("'", "''")}'");
            await db.rawQuery('SELECT count(*) FROM sqlite_master');
          },
        ));
  }
}

class FfiHarness implements DbSuiteHarness {
  final dir = Directory.systemTemp.createTempSync('docease_ffi_');
  @override
  final DbKeyStore keys = MemKeys();
  @override
  final CipherDatabaseOpener opener = FfiOpener();
  @override
  Future<String> databasesPath() async => dir.path;
  @override
  void define(String name, Future<void> Function() body) => test(name, body);
}

void main() {
  final harness = FfiHarness();
  tearDownAll(() {
    if (harness.dir.existsSync()) harness.dir.deleteSync(recursive: true);
  });

  test('this build really is SQLCipher (not plain SQLite)', () async {
    final db = await ffi.databaseFactoryFfiNoIsolate.openDatabase(':memory:');
    final v = await db.rawQuery('PRAGMA cipher_version');
    await db.close();
    expect(v, isNotEmpty,
        reason: 'PRAGMA cipher_version returned nothing: the sqlite3 hook '
            'loaded plain SQLite instead of libsqlcipher');
    // ignore: avoid_print
    print('cipher_version: ${v.first.values.first}');
  });

  runDbSuite(harness);
}
