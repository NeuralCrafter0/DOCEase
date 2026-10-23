// Host unit tests for DatabaseHelper's fail-closed behaviour. Real SQLCipher
// round trips (encryption, migrations, upgrade) are in
// integration_test/db_encryption_migration_test.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';

const uid = 'doctorA';
const fallbackKey = 'fallback_secure_key_123';

void main() {
  late Directory dir;
  late MemoryKeyStore keys;
  late RecordingOpener opener;

  DatabaseHelper helper() => DatabaseHelper(
      keyStore: keys, opener: opener, databasesPath: () async => dir.path);
  String path(String name) => p.join(dir.path, name);
  String target() => path(DatabaseHelper.dbFileNameFor(uid));
  String legacy() => path(DatabaseHelper.legacyDbFileName);
  List<String> files() =>
      dir.listSync().map((e) => p.basename(e.path)).toList()..sort();
  List<int> randomBytes(int n) {
    final r = Random(n);
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  /// Writes the key-check value that [key] would have written on create.
  void writeKcvFor(String key) => File(DatabaseHelper.kcvPathFor(target()))
      .writeAsStringSync('v1:${hexOf(DatabaseHelper.keyCheckBytes(key, uid))}');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('docease_db_unit_');
    keys = MemoryKeyStore();
    opener = RecordingOpener();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('fail closed on key errors', () {
    test('secure storage read throws: keyUnavailable, nothing opened (DB-01)',
        () async {
      keys.failRead = true;
      final h = helper();
      final states = <DbOpenState>[];
      final sub = h.states.listen(states.add);

      await expectLater(
          h.openFor(uid),
          throwsA(isA<DbOpenException>()
              .having((e) => e.error, 'error', DbOpenError.keyUnavailable)));
      await flushMicrotasks();
      await sub.cancel();

      expect(opener.calls, isEmpty);
      expect(files(), isEmpty);
      expect(states.map((s) => s.toString()), [
        'DbClosed()',
        'DbOpening($uid)',
        'DbFailed($uid, keyUnavailable)',
      ]);
      final failed = h.state as DbFailed;
      expect(failed.canReset, isFalse);
      expect(keys.log.where((l) => l.startsWith('write:')), isEmpty);
    });

    test('first run and key write throws: keyUnavailable, no file (DB-02)',
        () async {
      keys.failWrite = true;
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
      expect(opener.calls, isEmpty);
      expect(files(), isEmpty);
    });

    test('key that does not read back is never used', () async {
      final h = DatabaseHelper(
          keyStore: _DroppingKeyStore(),
          opener: opener,
          databasesPath: () async => dir.path);
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
      expect(opener.calls, isEmpty);
    });

    test('wrong key (KCV of another key): keyMismatch after exactly one keyed '
        'open, file untouched (DB-03)', () async {
      final bytes = randomBytes(4096);
      File(target()).writeAsBytesSync(bytes);
      writeKcvFor('d' * 64);
      keys.values[DatabaseHelper.keyNameFor(uid)] = 'a' * 64;
      opener.error = Exception('file is not a database (code 26)');
      final h = helper();

      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));

      final failed = h.state as DbFailed;
      expect(failed.error, DbOpenError.keyMismatch);
      expect(failed.canReset, isTrue);
      expect(opener.calls, hasLength(1));
      expect(opener.calls.single.key, 'a' * 64);
      expect(opener.calls.any((c) => c.key == null || c.key == ''), isFalse);
      expect(opener.calls.any((c) => c.key == fallbackKey), isFalse);
      expect(File(target()).readAsBytesSync(), bytes);
      expect(files(), [
        DatabaseHelper.dbFileNameFor(uid),
        '${DatabaseHelper.dbFileNameFor(uid)}.kcv',
      ]);
    });

    test('encrypted file but no key at all: keyUnavailable (retry only, no '
        'reset), never opened', () async {
      File(target()).writeAsBytesSync(randomBytes(4096));
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
      expect((h.state as DbFailed).canReset, isFalse);
      expect(opener.calls, isEmpty);
      // No key was generated for a file it could never open.
      expect(keys.values, isEmpty);
    });

    test('disk full while creating: storageFull, partial file removed (DB-07)',
        () async {
      opener.error = FileSystemException(
          'write failed', target(), const OSError('No space left on device', 28));
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.storageFull);
      expect(files(), isEmpty);
    });

    test('invalid uid is rejected before anything is touched', () {
      final h = helper();
      expect(() => h.openFor('../evil'), throwsArgumentError);
      expect(() => h.openFor(''), throwsArgumentError);
      expect(opener.calls, isEmpty);
      expect(keys.log, isEmpty);
    });

    test('database getter never opens anything by itself', () async {
      await expectLater(helper().database, throwsStateError);
      expect(opener.calls, isEmpty);
    });
  });

  group('keys', () {
    test('generateKey is 32 random bytes as 64 hex chars', () {
      final a = DatabaseHelper.generateKey();
      final b = DatabaseHelper.generateKey();
      expect(a, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a, isNot(b));
    });

    test('the hardcoded fallback key is never used by openFor', () async {
      // Every failure path of openFor: none may fall back to a fixed key.
      for (final setup in <void Function()>[
        () => keys.failRead = true,
        () => keys.failWrite = true,
        () {
          File(target()).writeAsBytesSync(randomBytes(64));
          keys.values[DatabaseHelper.keyNameFor(uid)] = 'b' * 64;
          opener.error = Exception('file is not a database');
        },
      ]) {
        keys = MemoryKeyStore();
        opener = RecordingOpener();
        setup();
        await expectLater(helper().openFor(uid), throwsA(anything));
        expect(opener.calls.map((c) => c.key), isNot(contains(fallbackKey)));
        expect(keys.values.values, isNot(contains(fallbackKey)));
      }
    });
  });

  group('unsynced counter (outside the database)', () {
    Future<DatabaseHelper> mismatched() async {
      File(target()).writeAsBytesSync(randomBytes(4096));
      writeKcvFor('e' * 64);
      keys.values[DatabaseHelper.keyNameFor(uid)] = 'c' * 64;
      opener.error = Exception('file is not a database');
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.keyMismatch);
      return h;
    }

    final counterKey = DatabaseHelper.unsyncedCounterKeyFor(uid);

    test('readable in keyMismatch: known(n) from the stored counter', () async {
      keys.values[counterKey] = '3';
      expect(await (await mismatched()).unsyncedCount(),
          const UnsyncedCount.known(3));
    });

    test('missing, garbage or negative counter is unknown', () async {
      final h = await mismatched();
      expect(await h.unsyncedCount(), UnsyncedCount.unknown);
      keys.values[counterKey] = 'banana';
      expect(await h.unsyncedCount(), UnsyncedCount.unknown);
      keys.values[counterKey] = '-1';
      expect(await h.unsyncedCount(), UnsyncedCount.unknown);
    });

    test('unreadable counter (storage throws) is unknown', () async {
      final h = await mismatched();
      keys.values[counterKey] = '0';
      keys.failRead = true;
      expect(await h.unsyncedCount(), UnsyncedCount.unknown);
    });

    test('no doctor at all is unknown', () async {
      expect(await helper().unsyncedCount(), UnsyncedCount.unknown);
    });

    test('covers(): unknown is the strongest warning', () {
      const k0 = UnsyncedCount.known(0);
      const k3 = UnsyncedCount.known(3);
      const k5 = UnsyncedCount.known(5);
      const u = UnsyncedCount.unknown;
      expect(k0.covers(k0), isTrue);
      expect(k0.covers(k3), isFalse);
      expect(k3.covers(k3), isTrue);
      expect(k5.covers(k3), isTrue);
      expect(k3.covers(k5), isFalse);
      expect(u.covers(k5), isTrue);
      expect(k5.covers(u), isFalse);
      expect(u.covers(u), isTrue);
      expect(k0.mayHaveUnsynced, isFalse);
      expect(k3.mayHaveUnsynced, isTrue);
      expect(u.mayHaveUnsynced, isTrue);
    });
  });

  group('resetAndResync gating', () {
    Future<DatabaseHelper> mismatched() async {
      File(target()).writeAsBytesSync(randomBytes(4096));
      writeKcvFor('e' * 64);
      keys.values[DatabaseHelper.keyNameFor(uid)] = 'c' * 64;
      opener.error = Exception('file is not a database');
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      return h;
    }

    test('refused when the user was shown fewer unsynced changes (DB-05)',
        () async {
      keys.values[DatabaseHelper.unsyncedCounterKeyFor(uid)] = '3';
      final h = await mismatched();
      final before = File(target()).readAsBytesSync();
      var resynced = false;

      await expectLater(
          h.resetAndResync(
              acknowledgedUnsynced: const UnsyncedCount.known(0),
              resync: () async => resynced = true),
          throwsA(isA<ResetNotConfirmedException>().having(
              (e) => e.current, 'current', const UnsyncedCount.known(3))));

      expect(File(target()).readAsBytesSync(), before);
      expect(keys.values[DatabaseHelper.keyNameFor(uid)], 'c' * 64);
      expect(resynced, isFalse);
      expect((h.state as DbFailed).error, DbOpenError.keyMismatch);
    });

    test('unknown count needs an unknown acknowledgement (DB-05b)', () async {
      final h = await mismatched();
      final before = File(target()).readAsBytesSync();
      await expectLater(
          h.resetAndResync(acknowledgedUnsynced: const UnsyncedCount.known(99)),
          throwsA(isA<ResetNotConfirmedException>()
              .having((e) => e.current, 'current', UnsyncedCount.unknown)));
      expect(File(target()).readAsBytesSync(), before);
    });

    test('never allowed outside keyMismatch (DB-06)', () async {
      keys.failRead = true;
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      await expectLater(
          h.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
          throwsStateError);
      await expectLater(
          helper().resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
          throwsStateError);
      expect(opener.calls, isEmpty);
    });

    test('a key store failure during reset deletes nothing', () async {
      final h = await mismatched();
      final before = File(target()).readAsBytesSync();
      keys.failWrite = true;
      await expectLater(
          h.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
          throwsA(isA<DbOpenException>()));
      expect(File(target()).readAsBytesSync(), before);
      expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
    });
  });

  group('legacy claim bookkeeping', () {
    test('nothing to claim is a no-op returning false (MIG-06u/07u)', () async {
      final h = helper();
      expect(await h.hasLegacyDb(), isFalse);
      expect(await h.claimLegacyDb(uid), isFalse);
      expect(h.state, isA<DbClosed>());
      expect(opener.calls, isEmpty);
      expect(files(), isEmpty);
    });

    test('undecryptable legacy file: legacyUnreadable (no reset), legacy '
        'byte-identical, no '
        'temp files left, fallback only tried on a copy', () async {
      final bytes = randomBytes(8192);
      File(legacy()).writeAsBytesSync(bytes);
      keys.values[DatabaseHelper.legacyKeyName] =
          '0f0e0d0c-0b0a-4908-8706-050403020100';
      opener.error = Exception('file is not a database');
      final h = helper();

      await expectLater(h.claimLegacyDb(uid), throwsA(isA<DbOpenException>()));

      expect((h.state as DbFailed).error, DbOpenError.legacyUnreadable);
      expect((h.state as DbFailed).canReset, isFalse);
      expect(File(legacy()).readAsBytesSync(), bytes);
      expect(files(), [DatabaseHelper.legacyDbFileName]);
      expect(await h.hasLegacyDb(), isTrue);
      // Old key first, then the fallback; both only ever on the work copy.
      expect(opener.calls.map((c) => c.key), [
        '0f0e0d0c-0b0a-4908-8706-050403020100',
        fallbackKey,
      ]);
      expect(opener.calls.every((c) => c.path.endsWith('.migrating')), isTrue);
    });

    test('legacy key unreadable and fallback fails: keyUnavailable (retry)',
        () async {
      File(legacy()).writeAsBytesSync(randomBytes(4096));
      keys.failRead = true;
      keys.failOnly = (n) => n == DatabaseHelper.legacyKeyName;
      opener.error = Exception('file is not a database');
      final h = helper();
      await expectLater(h.claimLegacyDb(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
      expect(await h.hasLegacyDb(), isTrue);
    });

    test('claim fails in the copy step (disk full): legacy kept (MIG-04u)',
        () async {
      final bytes = randomBytes(4096);
      File(legacy()).writeAsBytesSync(bytes);
      final h = DatabaseHelper(
        keyStore: keys,
        opener: opener,
        databasesPath: () async => dir.path,
        migrationHook: (point, _) async {
          if (point == MigrationCheckpoint.copied) {
            throw FileSystemException('copy', legacy(),
                const OSError('No space left on device', 28));
          }
        },
      );
      await expectLater(h.claimLegacyDb(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.storageFull);
      expect(File(legacy()).readAsBytesSync(), bytes);
      expect(files(), [DatabaseHelper.legacyDbFileName]);
      expect(await h.hasLegacyDb(), isTrue);
    });

    group('interrupted claim marker', () {
      String hexHead(List<int> b) =>
          b.take(16).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      void writeMarker(Object json) => File(path(DatabaseHelper.claimMarkerFileName))
          .writeAsStringSync(jsonEncode(json));

      test('committed (target salt matches): finishes, legacy removed',
          () async {
        final t = randomBytes(4096);
        File(target()).writeAsBytesSync(t);
        File(legacy()).writeAsBytesSync(randomBytes(2048));
        writeMarker({'uid': uid, 'salt': hexHead(t)});

        expect(await helper().hasLegacyDb(), isFalse);
        expect(files(), [DatabaseHelper.dbFileNameFor(uid)]);
        expect(File(target()).readAsBytesSync(), t);
      });

      test('not committed (salt differs, e.g. old empty target): legacy kept',
          () async {
        final l = randomBytes(2048);
        File(target()).writeAsBytesSync(randomBytes(4096));
        File(legacy()).writeAsBytesSync(l);
        writeMarker({'uid': uid, 'salt': '00' * 16});

        expect(await helper().hasLegacyDb(), isTrue);
        expect(File(legacy()).readAsBytesSync(), l);
        expect(File(path(DatabaseHelper.claimMarkerFileName)).existsSync(),
            isFalse);
      });

      test('not committed (no target) or corrupt marker: legacy kept',
          () async {
        final l = randomBytes(2048);
        File(legacy()).writeAsBytesSync(l);
        writeMarker({'uid': uid, 'salt': '11' * 16});
        expect(await helper().hasLegacyDb(), isTrue);
        File(path(DatabaseHelper.claimMarkerFileName))
            .writeAsStringSync('{not json');
        expect(await helper().hasLegacyDb(), isTrue);
        expect(File(legacy()).readAsBytesSync(), l);
      });
    });
  });
  group('settings', () {
    test('throw with no open DB and after a failed open; never open a DB',
        () async {
      final h = helper();
      await expectLater(h.getSetting('k'), throwsA(isA<StateError>()));
      await expectLater(h.putSetting('k', 'v'), throwsA(isA<StateError>()));
      await expectLater(h.deleteSetting('k'), throwsA(isA<StateError>()));
      expect(opener.calls, isEmpty);

      keys.failRead = true;
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      await expectLater(
          h.putSetting('k', 'v'),
          throwsA(isA<DbOpenException>()
              .having((e) => e.error, 'error', DbOpenError.keyUnavailable)));
      expect(opener.calls, isEmpty);
      expect(files(), isEmpty);
    });
  });
}

/// Accepts writes but never stores them (a broken keystore).
class _DroppingKeyStore implements DbKeyStore {
  @override
  Future<String?> read(String name) async => null;
  @override
  Future<void> write(String name, String value) async {}
  @override
  Future<void> delete(String name) async {}
}
