// QA characterization helpers. Uses only flutter_test + packages already in
// pubspec.lock (no new dependencies). Mocks platform channels so the REAL app
// code (DatabaseHelper, SecurityWrapper, screens) runs on the host VM.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const sqlcipherChannel = MethodChannel('com.davidmartos96.sqflite_sqlcipher');
const secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const localAuthChannel = MethodChannel('plugins.flutter.io/local_auth');

TestDefaultBinaryMessenger get _messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Records every call made to the sqlcipher channel.
class FakeSqlCipher {
  final List<MethodCall> calls = [];

  /// If true, any openDatabase call that carries a non-null password throws
  /// (simulates "wrong key" / corrupted encrypted file).
  bool failEncryptedOpen = false;

  /// Rows returned for `SELECT * FROM patients`.
  List<List<Object?>> patientRows = [];

  List<MethodCall> get opens =>
      calls.where((c) => c.method == 'openDatabase').toList();

  void install() {
    _messenger.setMockMethodCallHandler(sqlcipherChannel, (call) async {
      calls.add(call);
      final args = (call.arguments is Map) ? call.arguments as Map : const {};
      switch (call.method) {
        case 'getDatabasesPath':
          return '/fake/databases';
        case 'openDatabase':
          if (failEncryptedOpen && args['password'] != null) {
            throw PlatformException(
                code: 'sqlite_error', message: 'file is not a database');
          }
          return 1;
        case 'query':
          final sql = (args['sql'] ?? '').toString();
          if (sql.toUpperCase().contains('USER_VERSION')) {
            return {
              'columns': ['user_version'],
              'rows': [
                [0]
              ]
            };
          }
          return {
            'columns': [
              'id',
              'name',
              'age',
              'gender',
              'phone',
              'relation',
              'history'
            ],
            'rows': patientRows,
          };
        case 'insert':
          return 1;
        case 'update':
        case 'delete':
          return 1;
        default:
          return null; // execute, options, debugMode, batch, closeDatabase...
      }
    });
  }
}

/// Secure storage fake. When [throwOnAccess] is true every call throws,
/// simulating Keystore/Keychain failure.
class FakeSecureStorage {
  final Map<String, String> store = {};
  bool throwOnAccess = false;
  final List<MethodCall> calls = [];

  void install() {
    _messenger.setMockMethodCallHandler(secureStorageChannel, (call) async {
      calls.add(call);
      if (throwOnAccess) {
        throw PlatformException(code: 'KeyStoreError', message: 'boom');
      }
      final args = call.arguments as Map;
      final key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return store[key];
        case 'write':
          store[key!] = args['value'] as String;
          return null;
        default:
          return null;
      }
    });
  }
}

/// local_auth fake. [mode]: 'throw' => every call throws;
/// 'unsupported' => device reports no biometrics / not supported;
/// 'deny' => supported but user fails authentication;
/// 'allow' => supported and authentication succeeds.
void installLocalAuth(String mode) {
  _messenger.setMockMethodCallHandler(localAuthChannel, (call) async {
    if (mode == 'throw') {
      throw PlatformException(code: 'NotAvailable', message: 'sensor error');
    }
    switch (call.method) {
      case 'getAvailableBiometrics':
      case 'getEnrolledBiometrics':
        return mode == 'unsupported' ? <String>[] : <String>['fingerprint'];
      case 'deviceSupportsBiometrics':
      case 'isDeviceSupported':
        return mode != 'unsupported';
      case 'authenticate':
        return mode == 'allow';
      default:
        return false;
    }
  });
}
