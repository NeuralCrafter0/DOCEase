// Real SQLCipher + Android Keystore tests for the local database layer.
// Run on an emulator or device (not part of `flutter test`):
//   flutter test integration_test/db_encryption_migration_test.dart -d <device>
// Note: uses the real secure storage of the test app; it deletes only the
// keys and docease_* files of the itest/other doctors it creates.
import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sq;

import 'support/db_suite.dart';

class _DeviceHarness implements DbSuiteHarness {
  @override
  final DbKeyStore keys = SecureStorageKeyStore();

  @override
  final CipherDatabaseOpener opener = const SqlCipherOpener();

  @override
  Future<String> databasesPath() => sq.getDatabasesPath();

  @override
  void define(String name, Future<void> Function() body) =>
      testWidgets(name, (_) => body());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runDbSuite(_DeviceHarness());
}
