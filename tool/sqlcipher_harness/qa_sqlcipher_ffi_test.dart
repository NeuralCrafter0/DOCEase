// Host entry point for the QA real-SQLCipher cases
// (integration_test/support/qa_db_open_suite.dart). Not run by a plain
// `flutter test`: tool/sqlcipher_harness/run_qa.sh copies the repo to a temp
// dir, adds sqflite_common_ffi + the system-sqlcipher hook config to the
// copy, places this file and #10's sqlcipher_ffi_test.dart in test/ and runs
// this one. Reuses #10's MemKeys and FfiOpener unchanged.
import 'dart:io';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

import '../integration_test/support/qa_db_open_suite.dart';
import 'sqlcipher_ffi_test.dart' show FfiOpener, MemKeys;

class QaFfiHarness implements QaDbSuiteHarness {
  final root = Directory.systemTemp.createTempSync('docease_qa_ffi_');
  late final dbDir = Directory('${root.path}/databases')..createSync();
  late final support = Directory('${root.path}/support')..createSync();
  late final docs = Directory('${root.path}/documents')..createSync();
  late final cache = Directory('${root.path}/cache')..createSync();
  @override
  final DbKeyStore keys = MemKeys();
  @override
  final CipherDatabaseOpener opener = FfiOpener();
  @override
  Future<String> databasesPath() async => dbDir.path;
  @override
  Future<List<String>> appPrivateDirs() async =>
      [root.path, support.path, docs.path, cache.path];
  @override
  void define(String name, Future<void> Function() body) => test(name, body);
}

void main() {
  final harness = QaFfiHarness();
  tearDownAll(() {
    if (harness.root.existsSync()) harness.root.deleteSync(recursive: true);
  });
  test('this build really is SQLCipher (not plain SQLite)', () async {
    final db = await ffi.databaseFactoryFfiNoIsolate.openDatabase(':memory:');
    final v = await db.rawQuery('PRAGMA cipher_version');
    await db.close();
    expect(v, isNotEmpty);
  });
  runQaDbOpenSuite(harness);
}
