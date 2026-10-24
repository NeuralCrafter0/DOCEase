// Security review proofs of concept, adapted as regression tests: each test
// asserts the FIXED behaviour, so it fails on the reviewed commit and passes
// after the fix. Self-contained (own fakes) so the same file runs against
// both commits.
import 'dart:io';
import 'dart:math';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart'
    show Database, OnDatabaseCreateFn, OnDatabaseVersionChangeFn;

const uid = 'doctorA';

class _Keys implements DbKeyStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String name) async => values[name];
  @override
  Future<void> write(String name, String value) async => values[name] = value;
  @override
  Future<void> delete(String name) async => values.remove(name);
}

class _Opener implements CipherDatabaseOpener {
  Object? error;
  final List<String?> keys = [];

  @override
  Future<Database> open(String path,
      {String? key,
      int? version,
      OnDatabaseCreateFn? onCreate,
      OnDatabaseVersionChangeFn? onUpgrade,
      OnDatabaseVersionChangeFn? onDowngrade}) async {
    keys.add(key);
    throw error ?? StateError('fake opener: no database');
  }

  // Not on the reviewed commit's interface, hence no @override.
  // ignore: annotate_overrides
  Future<Database> openPlaintext(String path,
      {int? version, OnDatabaseCreateFn? onCreate}) async {
    keys.add(null);
    throw error ?? StateError('fake opener: no database');
  }
}

void main() {
  late Directory dir;
  late _Keys keys;
  late _Opener opener;

  DatabaseHelper helper() => DatabaseHelper(
      keyStore: keys, opener: opener, databasesPath: () async => dir.path);
  String target() => p.join(dir.path, DatabaseHelper.dbFileNameFor(uid));
  List<int> randomBytes(int n) {
    final r = Random(n);
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('docease_sec_poc_');
    keys = _Keys();
    opener = _Opener();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('POC-1 fixed: an empty stored key is rejected before any open; no '
      'plaintext DB is created', () async {
    keys.values[DatabaseHelper.keyNameFor(uid)] = '';
    final h = helper();
    await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
    expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
    expect(opener.keys, isEmpty);
    expect(dir.listSync(), isEmpty);
  });

  test('POC-1b fixed: a malformed/short stored key is rejected', () async {
    keys.values[DatabaseHelper.keyNameFor(uid)] = 'x';
    final h = helper();
    await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
    expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
    expect(opener.keys, isEmpty);
  });

  test('POC-2 fixed: a transient "open_failed <path>" with the right key is '
      'retryable, never keyMismatch, and reset cannot delete the DB', () async {
    final bytes = randomBytes(4096);
    File(target()).writeAsBytesSync(bytes);
    keys.values[DatabaseHelper.keyNameFor(uid)] = 'a' * 64; // the RIGHT key
    keys.values[DatabaseHelper.unsyncedCounterKeyFor(uid)] = '0';
    opener.error = Exception('open_failed ${target()}');
    final h = helper();
    await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
    final failed = h.state as DbFailed;
    expect(failed.error, isNot(DbOpenError.keyMismatch));
    expect(failed.canReset, isFalse);

    await expectLater(
        h.resetAndResync(acknowledgedUnsynced: const UnsyncedCount.known(0)),
        throwsStateError);
    expect(File(target()).readAsBytesSync(), bytes);
    expect(keys.values[DatabaseHelper.keyNameFor(uid)], 'a' * 64);
  });

  test('POC-3 fixed: a missing key next to an encrypted DB is keyUnavailable '
      '(retry only), not keyMismatch + reset', () async {
    File(target()).writeAsBytesSync(randomBytes(4096));
    final h = helper();
    await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
    expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
    expect((h.state as DbFailed).canReset, isFalse);
    expect(opener.keys, isEmpty);
    expect(await h.unsyncedCount(), UnsyncedCount.unknown);
  });

  test('POC-4 fixed: DbFailed.cause never carries raw exception text',
      () async {
    File(target()).writeAsBytesSync(randomBytes(4096));
    keys.values[DatabaseHelper.keyNameFor(uid)] = 'a' * 64;
    opener.error = Exception("sql 'ATTACH ... KEY ?' args [REDACTED-MARKER]");
    final h = helper();
    Object? thrown;
    try {
      await h.openFor(uid);
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<DbOpenException>());
    expect((h.state as DbFailed).cause.toString(),
        isNot(contains('REDACTED-MARKER')));
    expect(thrown.toString(), isNot(contains('REDACTED-MARKER')));
    expect(h.state.toString(), isNot(contains('REDACTED-MARKER')));
  });

  test('CONFIRM: traversal-style uids are rejected', () {
    final h = helper();
    for (final bad in ['../x', 'a/b', r'a\b', '', 'a.b', '..', 'a' * 129]) {
      expect(() => h.openFor(bad), throwsArgumentError, reason: bad);
    }
  });

  test('CONFIRM: generateKey is 64 lowercase hex chars and not repeated', () {
    final seen = <String>{};
    for (var i = 0; i < 200; i++) {
      final k = DatabaseHelper.generateKey();
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(k), isTrue);
      expect(seen.add(k), isTrue);
    }
  });
}
