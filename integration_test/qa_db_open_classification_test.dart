// QA real-SQLCipher + Android Keystore cases that #10's
// db_encryption_migration_test.dart does not cover (KCV-03/05/08-17,
// SET-ENC-01/02; see integration_test/support/qa_db_open_suite.dart).
// Run on an emulator or device (not part of `flutter test`):
//   flutter test integration_test/qa_db_open_classification_test.dart -d <device>
// Host run (system libsqlcipher): bash tool/sqlcipher_harness/run_qa.sh
// Uses the real secure storage of the test app; it deletes only the keys and
// docease_* files of the qaKcv* doctors it creates (and the legacy file).
import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart' as pp;
import 'package:sqflite_sqlcipher/sqflite.dart' as sq;

import 'support/qa_db_open_suite.dart';

class _DeviceHarness implements QaDbSuiteHarness {
  @override
  final DbKeyStore keys = SecureStorageKeyStore();
  @override
  final CipherDatabaseOpener opener = const SqlCipherOpener();
  @override
  Future<String> databasesPath() => sq.getDatabasesPath();
  @override
  Future<List<String>> appPrivateDirs() async {
    final dirs = <String>[
      (await pp.getApplicationSupportDirectory()).path,
      (await pp.getApplicationDocumentsDirectory()).path,
      (await pp.getTemporaryDirectory()).path,
    ];
    // Android: /data/data/<pkg> (shared_prefs, files, cache, databases...).
    dirs.add(p.dirname(await databasesPath()));
    return dirs;
  }

  @override
  void define(String name, Future<void> Function() body) =>
      testWidgets(name, (_) => body());
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  runQaDbOpenSuite(_DeviceHarness());
}
