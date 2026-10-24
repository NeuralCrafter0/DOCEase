// Host unit tests for the security review of fix/db-fail-closed-encryption
// (one group per review item). Real SQLCipher behaviour for the same items
// is in integration_test/support/db_suite.dart (KCV-*, CLS-*, SYNC-01).
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';

const uid = 'doctorA';
const keyA = '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late MemoryKeyStore keys;
  late RecordingOpener opener;

  DatabaseHelper helper({DbKeyStore? keyStore}) => DatabaseHelper(
      keyStore: keyStore ?? keys,
      opener: opener,
      databasesPath: () async => dir.path,
      backupExcluder: RecordingBackupExcluder());
  String target() => p.join(dir.path, DatabaseHelper.dbFileNameFor(uid));
  String kcv() => DatabaseHelper.kcvPathFor(target());
  List<String> files() =>
      dir.listSync().map((e) => p.basename(e.path)).toList()..sort();
  List<int> randomBytes(int n) {
    final r = Random(n);
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  void writeKcvFor(String key) => File(kcv())
      .writeAsStringSync('v1:${hexOf(DatabaseHelper.keyCheckBytes(key, uid))}');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('docease_review_');
    keys = MemoryKeyStore();
    opener = RecordingOpener();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  // --- 1 (High) ----------------------------------------------------------
  group('1 secure storage never resets on error', () {
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final calls = <MethodCall>[];
    Object? readError;

    setUp(() {
      calls.clear();
      readError = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'read' && readError != null) throw readError!;
        return null;
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    Map<Object?, Object?> optionsOf(MethodCall c) =>
        (c.arguments as Map)['options'] as Map<Object?, Object?>;

    test('Android: every call carries resetOnError=false', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      const store = SecureStorageKeyStore();
      await store.read('db_key_x');
      await store.write('db_key_x', keyA);
      await store.delete('db_key_x');
      expect(calls.map((c) => c.method), ['read', 'write', 'delete']);
      for (final c in calls) {
        expect(optionsOf(c)['resetOnError'], 'false', reason: c.method);
      }
    });

    test('iOS: keys are first_unlock_this_device', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const store = SecureStorageKeyStore();
      await store.write('db_key_x', keyA);
      expect(optionsOf(calls.single)['accessibility'],
          'first_unlock_this_device');
    });

    test('a read error (e.g. Keystore decrypt failure) is keyUnavailable: '
        'nothing opened, created, written or deleted', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      readError = PlatformException(code: 'Exception encountered',
          message: 'javax.crypto.BadPaddingException');
      File(target()).writeAsBytesSync(randomBytes(4096));
      final before = File(target()).readAsBytesSync();
      final h = helper(keyStore: const SecureStorageKeyStore());
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      final failed = h.state as DbFailed;
      expect(failed.error, DbOpenError.keyUnavailable);
      expect(failed.canReset, isFalse);
      expect(opener.calls, isEmpty);
      expect(calls.map((c) => c.method).toSet(), {'read'});
      expect(File(target()).readAsBytesSync(), before);
      expect(await h.unsyncedCount(), UnsyncedCount.unknown);
    });
  });

  // --- 2 (Medium) --------------------------------------------------------
  group('2 only a provable wrong key is keyMismatch; reset moves aside', () {
    Future<DbFailed> failOpen(Object error) async {
      opener.error = error;
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      return h.state as DbFailed;
    }

    setUp(() {
      File(target()).writeAsBytesSync(randomBytes(4096));
      keys.values[DatabaseHelper.keyNameFor(uid)] = keyA;
    });

    for (final error in <Object>[
      Exception('database is locked (code 5)'),
      Exception('open_failed /data/user/0/x/databases/docease_x.db'),
      const FileSystemException('read failed', '/x', OSError('EIO', 5)),
      Exception('file is not a database (code 26)'), // corrupt, right key
    ]) {
      test('KCV matches the stored key, open fails ($error): retryable',
          () async {
        writeKcvFor(keyA);
        final failed = await failOpen(error);
        expect(failed.error, DbOpenError.migrationFailed);
        expect(failed.canReset, isFalse);
      });
    }

    for (final (name, content) in [
      ('missing', null),
      ('empty', ''),
      ('truncated', 'v1:abcd'),
      ('unknown version', 'v2:${'0' * 64}'),
      ('not hex', 'v1:${'z' * 64}'),
    ]) {
      test('KCV $name: ambiguous, so retryable, never keyMismatch', () async {
        if (content != null) File(kcv()).writeAsStringSync(content);
        final failed =
            await failOpen(Exception('file is not a database (code 26)'));
        expect(failed.error, DbOpenError.migrationFailed);
        expect(failed.canReset, isFalse);
      });
    }

    test('KCV of a different key: keyMismatch, the only resettable case',
        () async {
      writeKcvFor('ff' * 32);
      final failed = await failOpen(Exception('file is not a database'));
      expect(failed.error, DbOpenError.keyMismatch);
      expect(failed.canReset, isTrue);
    });

    test('reset moves the file and its KCV aside and keeps the old key',
        () async {
      writeKcvFor('ff' * 32);
      final bytes = File(target()).readAsBytesSync();
      final kcvBefore = File(kcv()).readAsStringSync();
      opener.error = Exception('file is not a database');
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      // The fake opener also refuses the fresh database, so reset throws
      // after the move; the moved-aside copy must be intact regardless.
      await expectLater(
          h.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
          throwsA(anything));
      final moved = files()
          .where((f) => f.contains('.undecryptable-') && !f.endsWith('.kcv'))
          .toList();
      expect(moved, hasLength(1));
      expect(File(p.join(dir.path, moved.single)).readAsBytesSync(), bytes);
      expect(
          File(DatabaseHelper.kcvPathFor(p.join(dir.path, moved.single)))
              .readAsStringSync(),
          kcvBefore);
      final stamp = int.parse(moved.single.split('.undecryptable-').last);
      expect(keys.values[DatabaseHelper.quarantinedKeyNameFor(uid, stamp)],
          keyA);
    });

    test('a retryable failure never allows reset', () async {
      writeKcvFor(keyA);
      final bytes = File(target()).readAsBytesSync();
      opener.error = Exception('database is locked');
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      await expectLater(
          h.resetAndResync(acknowledgedUnsynced: UnsyncedCount.unknown),
          throwsStateError);
      expect(File(target()).readAsBytesSync(), bytes);
      expect(keys.values[DatabaseHelper.keyNameFor(uid)], keyA);
    });
  });

  // --- 3 (Medium) --------------------------------------------------------
  group('3 a stored key must be exactly 64 hex chars', () {
    for (final bad in [
      '',
      'x',
      'a' * 63,
      'a' * 65,
      'g' * 64,
      ' ${'a' * 63}',
      '${'a' * 64}\n',
      'fallback_secure_key_123',
      '0f0e0d0c-0b0a-4908-8706-050403020100',
    ]) {
      test('"${bad.length > 12 ? '${bad.substring(0, 12)}...' : bad}" '
          '(${bad.length} chars): keyUnavailable, never opened or created',
          () async {
        keys.values[DatabaseHelper.keyNameFor(uid)] = bad;
        final h = helper();
        await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
        expect((h.state as DbFailed).error, DbOpenError.keyUnavailable);
        expect(opener.calls, isEmpty);
        expect(files(), isEmpty, reason: 'no plaintext DB, no KCV');
        expect(keys.values[DatabaseHelper.keyNameFor(uid)], bad,
            reason: 'never overwritten');
      });
    }

    test('SqlCipherOpener refuses an empty key before reaching the plugin',
        () {
      expect(() => const SqlCipherOpener().open('/nonexistent', key: ''),
          throwsArgumentError);
    });

    test('hexDecodeKey gives the 32 raw bytes', () {
      expect(DatabaseHelper.hexDecodeKey(keyA), List.generate(32, (i) => i));
      expect(DatabaseHelper.hexDecodeKey(keyA.toUpperCase()),
          List.generate(32, (i) => i));
      expect(() => DatabaseHelper.hexDecodeKey('a' * 62), throwsStateError);
    });
  });

  // --- 4 (Medium) --------------------------------------------------------
  group('4 DbFailed carries a sanitized code, never raw error text', () {
    const marker = 'SECRET-MARKER-7f3a';
    for (final (error, code) in <(Object, String)>[
      (Exception("sql 'PRAGMA key = ?' args [$marker]"), '_Exception'),
      (PlatformException(code: 'sqlite_error', message: marker, details: marker),
          'platform:sqlite_error'),
      (PlatformException(code: 'bad code $marker'), 'platform'),
      (FileSystemException(marker, '/data/$marker', const OSError('ENOSPC', 28)),
          'fs:28'),
      (StateError(marker), 'StateError'),
      (marker, 'String'),
      (keyA, 'String'),
      (keyA.toUpperCase(), 'String'),
      (PlatformException(code: keyA), 'platform'),
    ]) {
      test('${error.runtimeType} -> $code', () async {
        File(target()).writeAsBytesSync(randomBytes(4096));
        keys.values[DatabaseHelper.keyNameFor(uid)] = keyA;
        writeKcvFor(keyA);
        opener.error = error;
        final logs = <String>[];
        final previous = debugPrint;
        debugPrint = (m, {wrapWidth}) => logs.add(m ?? '');
        Object? thrown;
        final h = helper();
        try {
          await h.openFor(uid);
        } catch (e) {
          thrown = e;
        } finally {
          debugPrint = previous;
        }
        final failed = h.state as DbFailed;
        expect(failed.cause, code);
        // Re-wrapping an already-sanitized cause keeps it.
        expect(describeDbError(failed.cause), code);
        for (final text in [
          failed.toString(),
          '${failed.cause}',
          thrown.toString(),
          '${(thrown as DbOpenException).cause}',
          ...logs,
        ]) {
          expect(text, isNot(contains(marker)));
          expect(text, isNot(contains(keyA)));
        }
      });
    }
  });

  // --- 6 (Medium, iOS) ---------------------------------------------------
  group('6 backup exclusion', () {
    test('PlatformBackupExcluder makes no platform call off iOS', () async {
      const channel = PlatformBackupExcluder.channel;
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (c) async => calls.add(c));
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      await const PlatformBackupExcluder().exclude('/x');
      expect(calls, Platform.isIOS ? hasLength(1) : isEmpty);
    });
  });

  // --- 7 (Low) -----------------------------------------------------------
  group('7 low items', () {
    test('crash leftovers are swept on start; real files are kept', () async {
      final base = DatabaseHelper.dbFileNameFor(uid);
      final stray = [
        '$base.migrating',
        '$base.migrating-journal',
        '$base.encrypting',
        '$base.encrypting-wal',
        '$base.kcv.tmp',
        '${DatabaseHelper.legacyDbFileName}.migrating',
      ];
      final keep = [
        base,
        '$base.kcv',
        '$base.undecryptable-1',
        DatabaseHelper.legacyDbFileName,
        'other.db.migrating',
        'notes.txt',
      ];
      for (final f in [...stray, ...keep]) {
        File(p.join(dir.path, f)).writeAsStringSync('x');
      }
      await helper().hasLegacyDb();
      expect(files(), (List.of(keep)..sort()));
    });

    test('sweep also runs on openFor, even when the key read fails', () async {
      final f = p.join(dir.path, '${DatabaseHelper.dbFileNameFor(uid)}.migrating');
      File(f).writeAsStringSync('x');
      keys.failRead = true;
      await expectLater(helper().openFor(uid), throwsA(isA<DbOpenException>()));
      expect(File(f).existsSync(), isFalse);
    });

    test('a failed create leaves no KCV behind', () async {
      opener.error = const FileSystemException(
          'write failed', '/x', OSError('No space left on device', 28));
      final h = helper();
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect((h.state as DbFailed).error, DbOpenError.storageFull);
      expect(files(), isEmpty);
    });

    test('KCV is HMAC-SHA256 keyed with the raw key bytes (known answer)',
        () {
      // python3: hmac.new(bytes(range(32)), b'docease-keycheck:doctorA',
      //                    hashlib.sha256).hexdigest()
      expect(hexOf(DatabaseHelper.keyCheckBytes(keyA, uid)),
          '941a8d720af7b18fa8a25f7c83caefcd917ca2c7099e8120d1b35ea745c3fba5');
      // ...not keyed with the 64-char hex string:
      expect(hexOf(DatabaseHelper.keyCheckBytes(keyA, uid)),
          isNot('f272c338dc760c5235ff2635957ebc10565b197d092102bc8a70a6044ad8a483'));
      expect(DatabaseHelper.keyCheckBytes(keyA, 'doctorB'),
          isNot(DatabaseHelper.keyCheckBytes(keyA, uid)));
    });

    test('constantTimeEquals: correct, and reads every byte on a mismatch',
        () {
      final eq = DatabaseHelper.constantTimeEquals;
      expect(eq([1, 2, 3], [1, 2, 3]), isTrue);
      expect(eq([], []), isTrue);
      expect(eq([9, 2, 3], [1, 2, 3]), isFalse);
      expect(eq([1, 2, 9], [1, 2, 3]), isFalse);
      expect(eq([1, 2], [1, 2, 3]), isFalse);
      final a = _ReadLog(List.filled(32, 0));
      final b = _ReadLog([1, ...List.filled(31, 0)]);
      expect(eq(a, b), isFalse);
      expect(a.reads, List.generate(32, (i) => i), reason: 'no early exit');
      expect(b.reads, List.generate(32, (i) => i));
    });

    test('openUid is only set while the DB is open and ready (for the '
        'session check)', () async {
      final h = helper();
      expect(h.openUid, isNull);
      keys.failRead = true;
      await expectLater(h.openFor(uid), throwsA(isA<DbOpenException>()));
      expect(h.openUid, isNull);
    });
  });
}

/// A list that records which indexes were read.
class _ReadLog extends ListBase<int> {
  _ReadLog(this._inner);
  final List<int> _inner;
  final List<int> reads = [];
  @override
  int get length => _inner.length;
  @override
  set length(int v) => _inner.length = v;
  @override
  int operator [](int i) {
    reads.add(i);
    return _inner[i];
  }

  @override
  void operator []=(int i, int v) => _inner[i] = v;
}
