import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show Hmac, sha256;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:sqflite_sqlcipher/sqflite.dart'
    show
        ConflictAlgorithm,
        DatabaseExecutor,
        Database,
        DatabaseException,
        OnDatabaseCreateFn,
        OnDatabaseVersionChangeFn;

import '../models/patient.dart';
import 'local_database.dart';

export 'local_database.dart';

// ---------------------------------------------------------------------------
// Injectable seams (production defaults; tests swap these out)
// ---------------------------------------------------------------------------

/// Where database keys (and the unsynced counter) live. Production:
/// flutter_secure_storage.
abstract class DbKeyStore {
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

class SecureStorageKeyStore implements DbKeyStore {
  const SecureStorageKeyStore({
    FlutterSecureStorage storage = defaultStorage,
    FlutterSecureStorage previousAccessibilityStorage =
        previousAccessibility,
  })  : _storage = storage,
        _previous = previousAccessibilityStorage;

  /// flutter_secure_storage 10 defaults `resetOnError` to true: on a decrypt
  /// error it deletes the entry (or every entry) and returns null, turning a
  /// transient Keystore failure into permanent key loss. Never reset; a
  /// read error then throws and surfaces as [DbOpenError.keyUnavailable].
  /// The shared-preferences name, key prefix and ciphers stay the defaults,
  /// so existing entries (including the legacy key) remain readable.
  static const AndroidOptions androidOptions =
      AndroidOptions(resetOnError: false);

  /// New entries are readable after first unlock and never leave this
  /// device (no iCloud Keychain, no restore onto another device).
  static const IOSOptions iosOptions = IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device);

  /// The iOS default accessibility used by earlier builds (and so by the
  /// legacy key). The keychain read query matches on accessibility, so
  /// entries written that way are only found by a query using it too.
  static const IOSOptions previousIosOptions = IOSOptions.defaultOptions;

  static const FlutterSecureStorage defaultStorage =
      FlutterSecureStorage(aOptions: androidOptions, iOptions: iosOptions);
  static const FlutterSecureStorage previousAccessibility = FlutterSecureStorage(
      aOptions: androidOptions, iOptions: previousIosOptions);

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _previous;

  static bool get _isApple => Platform.isIOS || Platform.isMacOS;

  @override
  Future<String?> read(String name) async {
    final value = await _storage.read(key: name);
    if (value != null || !_isApple) return value;
    // Written by an earlier build with the default accessibility.
    return _previous.read(key: name);
  }

  @override
  Future<void> write(String name, String value) async {
    try {
      await _storage.write(key: name, value: value);
    } on PlatformException {
      // An entry written with the previous accessibility has the same
      // keychain identity, so adding one with the new accessibility fails
      // as a duplicate. Replace it (the plugin's delete ignores
      // accessibility); callers keep a copy of anything they overwrite.
      if (!_isApple || await _previous.read(key: name) == null) rethrow;
      await _storage.delete(key: name);
      await _storage.write(key: name, value: value);
    }
  }

  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}

/// Opens SQLCipher databases. Every call returns a fresh connection (no
/// single-instance caching) that the caller must close.
abstract class CipherDatabaseOpener {
  /// Opens an encrypted database with [key], which must not be empty (an
  /// empty SQLCipher key silently creates a plaintext database).
  /// Implementations MUST verify the key during open (throw if it does not
  /// decrypt the file).
  Future<Database> open(
    String path, {
    required String key,
    int? version,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
  });

  /// Opens an unencrypted SQLite file. Only for the recovery migration's
  /// work copy of a legacy plaintext database (and test fixtures); never
  /// used for a live database.
  Future<Database> openPlaintext(String path,
      {int? version, OnDatabaseCreateFn? onCreate});
}

/// Production opener backed by sqflite_sqlcipher. Both the Android and iOS
/// plugins verify the key at open time by querying the schema.
class SqlCipherOpener implements CipherDatabaseOpener {
  const SqlCipherOpener();
  @override
  Future<Database> open(
    String path, {
    required String key,
    int? version,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
  }) {
    if (key.isEmpty) {
      throw ArgumentError('An empty key would open the file unencrypted.');
    }
    return sqlcipher.openDatabase(
      path,
      password: key,
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onDowngrade: onDowngrade,
      singleInstance: false,
    );
  }

  @override
  Future<Database> openPlaintext(String path,
      {int? version, OnDatabaseCreateFn? onCreate}) {
    return sqlcipher.openDatabase(path,
        password: null,
        version: version,
        onCreate: onCreate,
        singleInstance: false);
  }
}

/// Keeps database files out of device backups. iOS: sets
/// NSURLIsExcludedFromBackupKey through the `docease/backup_exclusion`
/// channel (ios/Runner/AppDelegate.swift). Android backups are disabled in
/// the manifest, so the production implementation does nothing there.
abstract class BackupExcluder {
  Future<void> exclude(String path);
}

class PlatformBackupExcluder implements BackupExcluder {
  const PlatformBackupExcluder();
  static const MethodChannel channel =
      MethodChannel('docease/backup_exclusion');

  @override
  Future<void> exclude(String path) async {
    if (!Platform.isIOS) return;
    await channel.invokeMethod<void>('excludeFromBackup', {'path': path});
  }
}

/// Points inside a recovery migration where a test hook runs.
enum MigrationCheckpoint {
  /// The source (and its sidecars) has been copied to the work file.
  copied,

  /// The copy has been exported/rekeyed, before row counts are verified.
  converted,

  /// The output passed verification, before it is committed.
  verified,

  /// The output has replaced the target (claims only), before the legacy
  /// file is deleted. Throwing here simulates a crash right after commit.
  committed,
}

/// Test hook: may inspect or tamper with [path] (the file the migration is
/// working on at [checkpoint]) or throw to force a failure at that point.
typedef MigrationHook = Future<void> Function(
    MigrationCheckpoint checkpoint, String path);

// ---------------------------------------------------------------------------
// DatabaseHelper
// ---------------------------------------------------------------------------

class DatabaseHelper implements LocalDatabase {
  /// Production defaults: flutter_secure_storage, sqflite_sqlcipher and the
  /// platform databases directory. Tests inject fakes for any of them.
  ///
  /// Test hooks (never set in production):
  /// [schemaVersion] opens/creates databases at an older schema, e.g. `1` to
  /// build a v1 fixture for the v1 -> v2 upgrade test.
  /// [migrationHook] runs at each [MigrationCheckpoint] of a recovery
  /// migration, e.g. to force a failure partway through [claimLegacyDb].
  DatabaseHelper({
    DbKeyStore? keyStore,
    CipherDatabaseOpener? opener,
    Future<String> Function()? databasesPath,
    BackupExcluder? backupExcluder,
    @visibleForTesting int schemaVersion = currentSchemaVersion,
    @visibleForTesting MigrationHook? migrationHook,
  })  : assert(schemaVersion >= 1 && schemaVersion <= currentSchemaVersion),
        _keys = keyStore ?? const SecureStorageKeyStore(),
        _opener = opener ?? const SqlCipherOpener(),
        _databasesPath = databasesPath ?? sqlcipher.getDatabasesPath,
        _backup = backupExcluder ?? const PlatformBackupExcluder(),
        _schemaVersion = schemaVersion,
        _hook = migrationHook;

  /// App-wide instance with the production dependencies.
  static final DatabaseHelper instance = DatabaseHelper();

  final DbKeyStore _keys;
  final CipherDatabaseOpener _opener;
  final Future<String> Function() _databasesPath;
  final BackupExcluder _backup;
  final int _schemaVersion;
  final MigrationHook? _hook;

  // --- constants -----------------------------------------------------------

  static const int currentSchemaVersion = 2;

  /// Unscoped database used before per-doctor scoping.
  static const String legacyDbFileName = 'docease_production_v1.db';

  /// Secure-storage name of the unscoped key used before per-doctor scoping.
  static const String legacyKeyName = 'db_encryption_key_prod';

  /// Written after a claim is verified and before it is committed. It records
  /// the new file's SQLCipher salt so an interrupted claim can tell whether
  /// the commit (rename) happened: finished if so, rolled back if not.
  static const String claimMarkerFileName = '$legacyDbFileName.claimed';

  /// The hardcoded key old builds fell back to when secure storage threw.
  /// Kept ONLY to read a legacy file during [claimLegacyDb]; it is never used
  /// to open or create a live database.
  static const String _legacyFallbackKey = 'fallback_secure_key_123';

  /// The file name is derived from a hash of the uid, so uids that differ
  /// only in case never share a file on case-insensitive file systems
  /// (APFS by default). Secure-storage names keep the uid itself.
  static String dbFileNameFor(String uid) =>
      'docease_${sha256.convert(utf8.encode(uid)).toString().substring(0, 32)}.db';
  static String keyNameFor(String uid) => 'db_key_$uid';
  static String unsyncedCounterKeyFor(String uid) => 'unsynced_count_$uid';

  /// Key-check sidecar next to a database file: `v1:` + hex of
  /// HMAC-SHA256(raw 32 key bytes, `docease-keycheck:<uid>`). Written
  /// atomically whenever a key is bound to the file (creation, migration,
  /// rekey, claim, reset) and after any successful open where it is missing
  /// or stale. It proves whether the stored key belongs to the file, which
  /// the open error cannot: sqflite_sqlcipher reports a wrong key, a lock,
  /// CANTOPEN and many I/O errors alike as `open_failed <path>`. Never
  /// logged. Not secret beyond the key itself (HMAC output reveals nothing
  /// about a 256-bit random key).
  static String kcvPathFor(String dbPath) => '$dbPath.kcv';

  /// The KCV bytes for [key] (64 hex chars, decoded to its raw 32 bytes and
  /// used as the HMAC key; never the hex string itself).
  @visibleForTesting
  static List<int> keyCheckBytes(String key, String uid) =>
      Hmac(sha256, hexDecodeKey(key))
          .convert(utf8.encode('docease-keycheck:$uid'))
          .bytes;

  static String _kcvText(String key, String uid) =>
      'v1:${_toHex(keyCheckBytes(key, uid))}';

  /// Where [resetAndResync] keeps the previous key of a file it moved aside.
  static String quarantinedKeyNameFor(String uid, int stamp) =>
      'db_key_${uid}_undecryptable_$stamp';

  /// Suffix of a database file moved aside by [resetAndResync].
  static String quarantineSuffix(int stamp) => '.undecryptable-$stamp';

  // The uid is an opaque owner id (a Firebase uid today, possibly a local
  // profile id later): any 1-128 chars of [A-Za-z0-9_-]. It is hashed into
  // the file name; the check still rejects anything path-like outright.
  static final RegExp _uidPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  /// Every key this code creates or accepts: 32 bytes as 64 hex chars.
  static final RegExp _hexKeyPattern = RegExp(r'^[0-9a-fA-F]{64}$');

  /// The old unscoped key (`Uuid().v4()`), accepted only as a legacy source.
  static final RegExp _legacyUuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
      r'[0-9a-fA-F]{12}$');

  /// Migration work files (and sidecars) of any doctor or the legacy file.
  static final RegExp _tempFilePattern = RegExp(
      r'^docease_[^/\\]+\.db(\.(migrating|encrypting)(-journal|-wal|-shm)?|\.kcv\.tmp)$');
  static const List<String> _sidecars = ['-journal', '-wal', '-shm'];
  static const String _sqliteHeader = 'SQLite format 3\u0000';

  // --- state ---------------------------------------------------------------

  Database? _db;
  String? _uid;
  Future<Database>? _pending;
  Future<void> _lock = Future<void>.value();
  Future<void> _rowLock = Future<void>.value();
  int _lastVersion = 0;
  DbMigrationStep? _lastStep;

  DbOpenState _state = const DbClosed();
  final StreamController<DbOpenState> _states =
      StreamController<DbOpenState>.broadcast(sync: true);

  @override
  DbOpenState get state => _state;

  /// The uid whose database is open (or being opened), if any.
  String? get currentUid => _uid;

  @override
  String? get openUid => (_db != null && _state is DbReady) ? _uid : null;

  @override
  Stream<DbOpenState> get states {
    late final StreamController<DbOpenState> c;
    StreamSubscription<DbOpenState>? sub;
    c = StreamController<DbOpenState>(
      onListen: () {
        c.add(_state);
        sub = _states.stream.listen(c.add);
      },
      onCancel: () => sub?.cancel(),
    );
    return c.stream;
  }

  void _emit(DbOpenState s) {
    _state = s;
    _states.add(s);
  }

  /// Serialises open/close/claim/reset so two of them never race on files.
  Future<T> _serial<T>(Future<T> Function() fn) {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }

  /// Serialises row writes so each one's sync_state transition and the
  /// unsynced counter update happen together.
  Future<T> _rowSerial<T>(Future<T> Function() fn) {
    final prev = _rowLock;
    final done = Completer<void>();
    _rowLock = done.future;
    return prev.then((_) => fn()).whenComplete(done.complete);
  }

  /// The open database for the current doctor. Throws [StateError] if no
  /// doctor database has been opened with [openFor], or [DbOpenException] if
  /// the last open failed. Never opens anything by itself.
  Future<Database> get database async {
    final db = _db;
    if (db != null) return db;
    final pending = _pending;
    if (pending != null) return pending;
    final s = _state;
    if (s is DbFailed) {
      throw DbOpenException(s.error, uid: s.uid, cause: s.cause);
    }
    throw StateError('No doctor database is open. Call openFor(uid) first.');
  }

  // --- lifecycle -----------------------------------------------------------

  @override
  Future<Database> openFor(String uid) {
    _checkUid(uid);
    return _track(_serial(() async {
      await _sweepStrayTemps();
      if (_uid == uid && _db != null) return _db!;
      await _closeLocked();
      _uid = uid;
      return _guard(uid, () => _openScopedLocked(uid));
    }));
  }

  @override
  Future<void> close() => _serial(_closeLocked);

  Future<void> _closeLocked() async {
    final db = _db;
    _db = null;
    _uid = null;
    if (db != null) {
      try {
        await db.close();
      } catch (e) {
        debugPrint('DB close error: ${_describe(e)}');
      }
    }
    if (_state is! DbClosed) _emit(const DbClosed());
  }

  Future<Database> _track(Future<Database> f) {
    _pending = f;
    f.then((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_pending, f)) _pending = null;
    });
    return f;
  }

  /// Runs [body], publishing [DbReady] or [DbFailed] for [uid]. On success
  /// the unsynced counter is reconciled against the real rows.
  Future<Database> _guard(String uid, Future<Database> Function() body) async {
    _emit(DbOpening(uid));
    try {
      final db = await body();
      _db = db;
      _uid = uid;
      if (_schemaVersion >= 2) {
        await _createV2Tables(db);
        await _pruneAttachmentSwaps(db);
        await _reconcileCounter(uid, db);
      }
      _emit(DbReady(uid));
      return db;
    } on DbOpenException catch (e) {
      _emit(DbFailed(uid, e.error, e.cause));
      rethrow;
    } catch (e) {
      final err = _classifyFatal(e, DbOpenError.migrationFailed);
      _emit(DbFailed(uid, err, describeDbError(e)));
      throw DbOpenException(err, uid: uid, cause: e);
    }
  }

  Future<Database> _openScopedLocked(String uid) async {
    final path = await _pathFor(dbFileNameFor(uid));
    final keyName = keyNameFor(uid);

    // Fail closed: if secure storage throws, nothing is opened or created.
    String? key = await _readKey(keyName, uid);

    if (!await _hasData(path)) {
      key ??= await _createKey(keyName, uid);
      return _createFresh(path, key, uid);
    }

    if (await _isPlaintext(path)) {
      // Cannot happen for files this code created, but never leave a
      // plaintext file in place: encrypt a copy and swap it in.
      key ??= await _createKey(keyName, uid);
      final out = await _convertToEncrypted(
        uid: uid,
        sourcePath: path,
        workBase: path,
        sourceKey: null,
        targetKey: key,
        step: DbMigrationStep.encryptingPlaintext,
      );
      await _writeKcv(path, key, uid);
      await _replaceFile(out!, path);
    }

    if (key == null) {
      // An encrypted file but no stored key. keyMismatch (and its reset)
      // needs a key that exists and provably does not fit; a missing entry
      // may be storage trouble, so this is retry-only and never deletes.
      throw DbOpenException(DbOpenError.keyUnavailable, uid: uid);
    }
    return _openMain(path, key, uid);
  }

  Future<Database> _openMain(String path, String key, String uid) async {
    final Database db;
    try {
      db = await _opener.open(
        path,
        key: _requireKey(key),
        version: _schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: _onDowngrade,
      );
    } catch (e) {
      throw DbOpenException(await _classifyOpenFailure(e, path, key, uid),
          uid: uid, cause: e);
    }
    await _afterOpen(uid, path, key);
    return db;
  }

  /// Why an existing file did not open with the doctor's (well-formed) key,
  /// from evidence that holds on every platform (never the error text):
  /// whether the file is readable, and the key-check sidecar. Only a KCV
  /// that does not match the stored key is [DbOpenError.keyMismatch]. A
  /// matching KCV (corruption or a lock), a missing or unreadable KCV
  /// (ambiguous, e.g. a file from an earlier build) or an unreadable file
  /// is retryable and never offers a reset.
  Future<DbOpenError> _classifyOpenFailure(
      Object e, String path, String key, String uid) async {
    final fatal = _classifyFatal(e, DbOpenError.migrationFailed);
    if (fatal != DbOpenError.migrationFailed) return fatal;
    if (!await _isReadable(path)) return DbOpenError.migrationFailed;
    return await _checkKcv(path, key, uid) == _Kcv.mismatch
        ? DbOpenError.keyMismatch
        : DbOpenError.migrationFailed;
  }

  Future<Database> _createFresh(String path, String key, String uid) async {
    try {
      await Directory(p.dirname(path)).create(recursive: true);
      await _deleteDbFiles(path); // only an empty/zero-byte file can be here
      await _writeKcv(path, key, uid);
      final db = await _opener.open(path,
          key: _requireKey(key),
          version: _schemaVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
          onDowngrade: _onDowngrade);
      if (await _isPlaintext(path)) {
        await db.close();
        throw StateError('Refusing a database that was created unencrypted.');
      }
      await _afterOpen(uid, path, key);
      return db;
    } catch (e) {
      // A brand-new file holds no user data: remove partial output, and
      // its key-check value (it vouches for a file that does not exist).
      await _shredDbFiles(path);
      await _safeDelete(kcvPathFor(path));
      throw DbOpenException(_classifyFatal(e, DbOpenError.migrationFailed),
          uid: uid, cause: e);
    }
  }

  /// After the doctor's database opened with its key: (re)write a missing
  /// or stale key-check value, and keep the files out of device backups.
  /// Neither failure blocks the open; both are retried on every open.
  Future<void> _afterOpen(String uid, String path, String key) async {
    if (await _checkKcv(path, key, uid) != _Kcv.match) {
      try {
        await _writeKcv(path, key, uid);
      } catch (e) {
        debugPrint('Key-check value not saved: ${_describe(e)}');
      }
    }
    for (final target in [p.dirname(path), path, kcvPathFor(path)]) {
      try {
        await _backup.exclude(target);
      } catch (e) {
        debugPrint('Backup exclusion failed: ${_describe(e)}');
      }
    }
  }

  // --- legacy (unscoped) database ------------------------------------------

  @override
  Future<bool> hasLegacyDb() => _serial(() async {
        await _sweepStrayTemps();
        final legacy = await _pathFor(legacyDbFileName);
        await _finishInterruptedClaim(legacy);
        return _hasData(legacy);
      });

  /// Returns true if the legacy database was claimed (and [uid]'s database is
  /// now open), or false, changing nothing, if there was nothing to claim, so
  /// a repeated claim (or a claim by another doctor afterwards) is a no-op.
  ///
  /// If the doctor's database already exists it is replaced only when it
  /// holds no patients; otherwise the claim is skipped (returns false), the
  /// doctor's database is opened as usual and the legacy file is left as it
  /// is (merging two databases is a product decision made elsewhere).
  @override
  Future<bool> claimLegacyDb(String uid) {
    _checkUid(uid);
    return _serial(() async {
      final legacy = await _pathFor(legacyDbFileName);
      final target = await _pathFor(dbFileNameFor(uid));
      await _sweepStrayTemps();
      await _finishInterruptedClaim(legacy);
      if (!await _hasData(legacy)) return false;
      await _closeLocked();
      _uid = uid;
      var claimed = true;
      await _track(_guard(
          uid,
          () => _claimLocked(uid, legacy, target,
              onTargetNotEmpty: () => claimed = false)));
      return claimed;
    });
  }

  Future<Database> _claimLocked(String uid, String legacy, String target,
      {required void Function() onTargetNotEmpty}) async {
    final keyName = keyNameFor(uid);
    String? key = await _readKey(keyName, uid);
    if (await _hasData(target)) {
      if (key == null) {
        throw DbOpenException(DbOpenError.keyUnavailable, uid: uid);
      }
      if (!await _isEmptyTarget(target, key, uid)) {
        // Never merge or overwrite: open the doctor's own DB as usual and
        // leave the legacy file exactly as it is.
        debugPrint('Legacy claim skipped: ${dbFileNameFor(uid)} has patients.');
        onTargetNotEmpty();
        return _openMain(target, key, uid);
      }
    }
    key ??= await _createKey(keyName, uid);

    final out = await _convertLegacy(uid, legacy, target, key);
    final marker = await _pathFor(claimMarkerFileName);
    try {
      // Commit: key-check value for the target key, marker (with the new
      // file's salt), then atomic rename.
      await _writeKcv(target, key, uid);
      final salt = await _headHex(out);
      await File(marker)
          .writeAsString(jsonEncode({'uid': uid, 'salt': salt}), flush: true);
      for (final s in _sidecars) {
        await _safeDelete('$target$s'); // only an empty target can be here
      }
      await File(out).rename(target);
    } catch (e) {
      await _safeDelete(marker);
      await _deleteDbFiles(out);
      rethrow;
    }
    await _runHook(MigrationCheckpoint.committed, target);
    _emit(DbMigrating(uid, _lastStep!, 1.0));
    await _finishInterruptedClaim(legacy);
    try {
      await _keys.delete(legacyKeyName);
    } catch (e) {
      debugPrint('Could not delete legacy key: ${e.runtimeType}');
    }
    final db = await _openMain(target, key, uid);
    // We cannot prove claimed rows ever reached Firestore: all start
    // unsynced. The reconcile in _guard then sets the counter to their count.
    try {
      await db.update('patients', {'sync_state': SyncState.dirty});
    } catch (e) {
      debugPrint('Could not mark claimed rows dirty: ${_describe(e)}');
    }
    return db;
  }

  /// Whether the existing target database has no patients and no pending
  /// deletes.
  Future<bool> _isEmptyTarget(String target, String key, String uid) async {
    final Database db;
    try {
      db = await _opener.open(target, key: _requireKey(key));
    } catch (e) {
      throw DbOpenException(await _classifyOpenFailure(e, target, key, uid),
          uid: uid, cause: e);
    }
    try {
      final counts = await _rowCounts(db);
      // A pending delete is an unsynced change too, and settings (profile,
      // medicines) exist nowhere else: never replace either.
      return (counts['patients'] ?? 0) == 0 &&
          (counts['pending_deletes'] ?? 0) == 0 &&
          (counts['settings'] ?? 0) == 0;
    } finally {
      await db.close();
    }
  }

  Future<String> _convertLegacy(
      String uid, String legacy, String target, String targetKey) async {
    if (await _isPlaintext(legacy)) {
      return (await _convertToEncrypted(
        uid: uid,
        sourcePath: legacy,
        workBase: target,
        sourceKey: null,
        targetKey: targetKey,
        step: DbMigrationStep.encryptingPlaintext,
      ))!;
    }
    // Encrypted: try the old unscoped key, then the old hardcoded fallback.
    Object? legacyKeyError;
    String? legacyKey;
    try {
      legacyKey = await _keys.read(legacyKeyName);
    } catch (e) {
      legacyKeyError = e;
    }
    if (legacyKey != null && !_legacyUuidPattern.hasMatch(legacyKey)) {
      debugPrint('Legacy key is not a UUID; not trying it.');
      legacyKey = null;
    }
    final candidates = <(String, DbMigrationStep)>[
      if (legacyKey != null) (legacyKey, DbMigrationStep.rekeyingFromLegacyKey),
      (_legacyFallbackKey, DbMigrationStep.rekeyingFromFallback),
    ];
    for (final (candidate, step) in candidates) {
      final out = await _convertToEncrypted(
        uid: uid,
        sourcePath: legacy,
        workBase: target,
        sourceKey: candidate,
        targetKey: targetKey,
        step: step,
        probeOnly: true,
      );
      if (out != null) return out;
    }
    if (legacyKeyError != null) {
      // The real legacy key may be fine; storage just could not provide it.
      throw DbOpenException(DbOpenError.keyUnavailable,
          uid: uid, cause: legacyKeyError);
    }
    // Never keyMismatch: a reset would not touch the legacy file.
    throw DbOpenException(DbOpenError.legacyUnreadable, uid: uid);
  }

  /// Finishes or rolls back a claim that was interrupted between writing the
  /// marker and deleting the legacy file. Never deletes the legacy file
  /// unless the committed copy is verifiably in place.
  Future<void> _finishInterruptedClaim(String legacy) async {
    final marker = File(await _pathFor(claimMarkerFileName));
    if (!await marker.exists()) return;
    var committed = false;
    try {
      final m = jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
      final owner = m['uid'];
      final salt = m['salt'];
      if (owner is String && _uidPattern.hasMatch(owner) && salt is String) {
        final target = await _pathFor(dbFileNameFor(owner));
        committed = await _hasData(target) && await _headHex(target) == salt;
      }
    } catch (e) {
      debugPrint('Unreadable claim marker: ${e.runtimeType}');
    }
    // Committed: the new file is in place, so finish removing the source.
    // Not committed: the legacy file is still the only copy; keep it.
    if (committed) await _shredDbFiles(legacy);
    await marker.delete();
  }

  // --- recovery engine -----------------------------------------------------

  /// Copies [sourcePath] (plus any journal/WAL sidecars, so SQLite can
  /// recover them) to a work file next to [workBase], converts the copy into
  /// an encrypted database under [targetKey], and verifies every table's row
  /// count, user_version and quick_check. Returns the verified output path.
  /// The source file itself is never opened or modified.
  ///
  /// With [probeOnly], a [sourceKey] that does not open the copy returns
  /// `null` instead of failing (the plugin reports a wrong key only as a
  /// generic open failure, and the copy has no other user).
  Future<String?> _convertToEncrypted({
    required String uid,
    required String sourcePath,
    required String workBase,
    required String? sourceKey,
    required String targetKey,
    required DbMigrationStep step,
    bool probeOnly = false,
  }) async {
    if (!_hexKeyPattern.hasMatch(targetKey)) {
      throw StateError('Refusing to migrate to a malformed key.');
    }
    final work = '$workBase.migrating';
    final exported = '$workBase.encrypting';
    await _shredDbFiles(work);
    await _shredDbFiles(exported);
    _lastStep = step;
    Database? db;
    try {
      _emit(DbMigrating(uid, step, 0.0));
      for (final s in ['', ..._sidecars]) {
        final f = File('$sourcePath$s');
        if (await f.exists()) await f.copy('$work$s');
      }
      await _runHook(MigrationCheckpoint.copied, work);
      _emit(DbMigrating(uid, step, 0.15));

      try {
        db = sourceKey == null
            ? await _opener.openPlaintext(work)
            : await _opener.open(work, key: _requireKey(sourceKey));
      } catch (e) {
        if (probeOnly) {
          await _shredDbFiles(work);
          return null;
        }
        rethrow;
      }
      final expected = await _rowCounts(db);
      final userVersion = await _userVersion(db);
      _emit(DbMigrating(uid, step, 0.3));

      final String out;
      // These statements carry the key (as an argument or in the SQL), and
      // sqflite exceptions print both: keep only a sanitized code.
      try {
        if (sourceKey == null) {
          await db.execute(
              'ATTACH DATABASE ? AS docease_enc KEY ?', [exported, targetKey]);
          await db.rawQuery("SELECT sqlcipher_export('docease_enc')");
          await db.rawQuery('PRAGMA docease_enc.user_version = $userVersion');
          await db.execute('DETACH DATABASE docease_enc');
        } else {
          await db.rawQuery('PRAGMA journal_mode = DELETE');
          await db.rawQuery("PRAGMA rekey = '${_sqlQuote(targetKey)}'");
        }
      } catch (e) {
        throw DbOpenException(_classifyFatal(e, DbOpenError.migrationFailed),
            uid: uid, cause: e);
      }
      await db.close();
      db = null;
      if (sourceKey == null) {
        await _shredDbFiles(work);
        out = exported;
      } else {
        out = work;
      }
      await _runHook(MigrationCheckpoint.converted, out);
      _emit(DbMigrating(uid, step, 0.7));

      await _verify(out, targetKey, expected, userVersion);
      await _runHook(MigrationCheckpoint.verified, out);
      _emit(DbMigrating(uid, step, 0.9));
      return out;
    } catch (e) {
      try {
        await db?.close();
      } catch (_) {}
      await _shredDbFiles(work);
      await _shredDbFiles(exported);
      if (e is DbOpenException) rethrow;
      throw DbOpenException(_classifyFatal(e, DbOpenError.migrationFailed),
          uid: uid, cause: e);
    }
  }

  Future<void> _runHook(MigrationCheckpoint checkpoint, String path) async {
    final hook = _hook;
    if (hook != null) await hook(checkpoint, path);
  }

  Future<void> _verify(String path, String key, Map<String, int> expected,
      int userVersion) async {
    if (await _isPlaintext(path)) {
      throw StateError('Migration output is not encrypted.');
    }
    final db = await _opener.open(path, key: _requireKey(key));
    try {
      final actual = await _rowCounts(db);
      if (!mapEquals(actual, expected)) {
        throw StateError('Row counts differ: expected $expected, got $actual');
      }
      if (await _userVersion(db) != userVersion) {
        throw StateError('user_version was not preserved.');
      }
      final check = await db.rawQuery('PRAGMA quick_check');
      if (check.isEmpty || check.first.values.first != 'ok') {
        throw StateError('quick_check failed: $check');
      }
    } finally {
      await db.close();
    }
  }

  Future<Map<String, int>> _rowCounts(Database db) async {
    final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name");
    final counts = <String, int>{};
    for (final t in tables) {
      final name = t['name'] as String;
      final r = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM "${name.replaceAll('"', '""')}"');
      counts[name] = r.first['c'] as int;
    }
    return counts;
  }

  Future<int> _userVersion(Database db) async {
    final r = await db.rawQuery('PRAGMA user_version');
    return r.first.values.first as int;
  }

  /// Atomically replaces [target] with the verified file [source].
  Future<void> _replaceFile(String source, String target) async {
    for (final s in _sidecars) {
      if (await File('$target$s').exists()) {
        await _deleteDbFiles(source);
        throw StateError('Refusing to replace $target while $s exists.');
      }
    }
    await File(source).rename(target);
  }

  // --- reset ---------------------------------------------------------------

  /// Moves the current doctor's undecryptable database aside (never deletes
  /// it; its previous key is kept under [quarantinedKeyNameFor]), starts a
  /// fresh one under a new key, then runs [resync] (e.g. a Firestore pull).
  ///
  /// Only allowed in `DbFailed(keyMismatch)`. [acknowledgedUnsynced] must be
  /// the [unsyncedCount] the user was warned about; if the current count is
  /// worse (higher, or unknown when a number was shown), this throws
  /// [ResetNotConfirmedException] and deletes nothing. Never touches other
  /// doctors' files or the legacy file.
  @override
  Future<void> resetAndResync({
    required UnsyncedCount acknowledgedUnsynced,
    Future<void> Function()? resync,
  }) async {
    await _serial(() async {
      await _sweepStrayTemps();
      final s = _state;
      if (s is! DbFailed || !s.canReset) {
        throw StateError('resetAndResync is only allowed after keyMismatch.');
      }
      final uid = s.uid!;
      final current = await _readCounter(uid);
      if (!acknowledgedUnsynced.covers(current)) {
        throw ResetNotConfirmedException(current);
      }
      await _track(_guard(uid, () async {
        final path = await _pathFor(dbFileNameFor(uid));
        final keyName = keyNameFor(uid);
        final stamp = DateTime.now().millisecondsSinceEpoch;
        // Keys first: if storage fails, nothing has been moved yet.
        final String? oldKey;
        try {
          oldKey = await _keys.read(keyName);
          if (oldKey != null) {
            await _keys.write(quarantinedKeyNameFor(uid, stamp), oldKey);
          }
        } catch (e) {
          throw DbOpenException(DbOpenError.keyUnavailable, uid: uid, cause: e);
        }
        final key = await _createKey(keyName, uid);
        try {
          await _quarantine(path, quarantineSuffix(stamp));
        } catch (e) {
          // Nothing was moved: restore the old key so key and file match.
          if (oldKey != null) {
            try {
              await _keys.write(keyName, oldKey);
            } catch (_) {}
          }
          rethrow;
        }
        return _createFresh(path, key, uid);
      }));
    });
    if (resync != null) await resync();
  }

  // --- schema --------------------------------------------------------------

  /// Fresh databases are built as v1 and then run through the same upgrade
  /// steps as existing installs, so both paths always produce one schema.
  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE patients (
        id TEXT PRIMARY KEY,
        name TEXT, age TEXT, gender TEXT, phone TEXT, relation TEXT, history TEXT
      )
    ''');
    await _upgrade(db, 1, version);
  }

  /// sqflite runs this inside a transaction, so a failure rolls back cleanly.
  static Future<void> _onUpgrade(Database db, int from, int to) =>
      _upgrade(db, from, to);

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2 && to >= 2) {
      // v1 -> v2: add sync tracking. We cannot know whether v1 rows ever
      // reached Firestore, so they start dirty (counted as unsynced).
      await db.execute("ALTER TABLE patients ADD COLUMN sync_state TEXT "
          "NOT NULL DEFAULT '${SyncState.dirty}'");
      await db.execute('ALTER TABLE patients ADD COLUMN updated_at INTEGER '
          'NOT NULL DEFAULT 0');
      await db.update(
          'patients', {'updated_at': DateTime.now().millisecondsSinceEpoch});
      await db.execute(
          'CREATE INDEX idx_patients_sync_state ON patients(sync_state)');
      await _createV2Tables(db);
    }
  }

  /// Tables added in v2 besides the patients columns. `IF NOT EXISTS`, so
  /// it also repairs v2 files created by earlier builds of this branch,
  /// before these tables were folded into v2 (see [_guard]).
  static Future<void> _createV2Tables(Database db) async {
    // Tombstones for deletes Firestore has not confirmed yet.
    await db.execute('CREATE TABLE IF NOT EXISTS pending_deletes ('
        'patient_id TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL)');
    // Local key-value store (doctor profile, medicines list, ...). Values
    // are opaque strings; never synced and never counted as unsynced.
    await db.execute('CREATE TABLE IF NOT EXISTS settings ('
        'key TEXT PRIMARY KEY, value TEXT NOT NULL, '
        'updated_at INTEGER NOT NULL)');
    // local photo key -> Storage path recorded by swapAttachmentPath, so a
    // whole-row save from a stale in-memory copy keeps the uploaded path.
    // A mapping, not a reference: never read by the attachment scans.
    await db.execute('CREATE TABLE IF NOT EXISTS attachment_swaps ('
        'patient_id TEXT NOT NULL, local_key TEXT NOT NULL, '
        'storage_path TEXT NOT NULL, swapped_at INTEGER NOT NULL, '
        'PRIMARY KEY(patient_id, local_key))');
  }

  static Future<void> _onDowngrade(Database db, int from, int to) async {
    throw StateError('Database schema v$from is newer than this app (v$to).');
  }

  // --- patients ------------------------------------------------------------

  /// Monotonic write version stored in `updated_at`, so a late Firestore
  /// confirmation can never mark a newer local edit as synced.
  int _nextVersion() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastVersion = max(now, _lastVersion + 1);
    return _lastVersion;
  }

  Map<String, Object?> _row(Patient patient) => {
        'id': patient.id, 'name': patient.name, 'age': patient.age,
        'gender': patient.gender, 'phone': patient.phone,
        'relation': patient.relation,
        'history': jsonEncode(patient.history.map((e) => e.toJson()).toList()),
      };

  /// Inserts or replaces a patient as a local edit (dirty). Returns the
  /// row's write version (for [markSynced]), or `null` if nothing was
  /// written. A patient with parse errors is never written (it would
  /// overwrite the stored data with placeholders). With [fromCloud] this is
  /// [applyCloudPatient] and returns its write version, or `null` if the
  /// cloud copy was not applied.
  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) {
    if (_refuseUnparsed(patient)) return Future.value(null);
    if (fromCloud) {
      return _applyCloud(patient)
          .then((v) => v == null ? null : '$v', onError: (Object _) => null);
    }
    return _rowSerial(() async {
      final (db, wasDirty) = await _prepareWrite(patient.id);
      if (db == null) return null;
      // Counter never under-reports: count a new dirty row before writing it
      // (throws UnsyncedCounterException, refusing the save, if it can't).
      if (!wasDirty) await _incrementCounter(_uid!, db);
      try {
        final version = _nextVersion();
        await db.transaction((txn) async {
          await txn.insert(
              'patients',
              {
                ...await _rowKeepingSwaps(txn, patient),
                'sync_state': SyncState.dirty,
                'updated_at': version,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        });
        return '$version';
      } catch (e) {
        debugPrint('SQLITE insert error: ${_describe(e)}');
        return null;
      }
    });
  }

  /// False means skipped, not an error: the local row is dirty, the id has
  /// a tombstone, or the cloud copy failed to parse. Throws if no database
  /// is open or the write fails.
  @override
  Future<bool> applyCloudPatient(Patient patient) async =>
      !_refuseUnparsed(patient) && await _applyCloud(patient) != null;

  /// One statement, so nothing can change between the check and the write:
  /// insert when the id has no row and no tombstone, update only a clean
  /// (synced) row. A dirty row or a tombstone means no change at all, so
  /// the unsynced counter is untouched. Returns the write version, or null
  /// if skipped. Throws on database errors.
  Future<int?> _applyCloud(Patient patient) {
    return _rowSerial(() async {
      final db = await database;
      final version = _nextVersion();
      final row = {
        ..._row(patient),
        'sync_state': SyncState.synced,
        'updated_at': version,
      };
      final cols = row.keys.toList();
      final updates = cols
          .where((c) => c != 'id')
          .map((c) => '$c = excluded.$c')
          .join(', ');
      try {
        final n = await db.rawUpdate(
            'INSERT INTO patients (${cols.join(', ')}) '
            'SELECT ${List.filled(cols.length, '?').join(', ')} '
            'WHERE NOT EXISTS '
            '(SELECT 1 FROM pending_deletes WHERE patient_id = ?) '
            'ON CONFLICT(id) DO UPDATE SET $updates '
            'WHERE patients.sync_state = ?',
            [...row.values, patient.id, SyncState.synced]);
        return n > 0 ? version : null;
      } catch (e) {
        debugPrint('SQLITE cloud apply error: ${_describe(e)}');
        rethrow;
      }
    });
  }

  /// Updates a patient and marks it dirty. Returns the write version, or
  /// `null` if nothing was written (including patients with parse errors).
  @override
  Future<String?> updatePatient(Patient patient) {
    if (_refuseUnparsed(patient)) return Future.value(null);
    return _rowSerial(() async {
      final (db, wasDirty) = await _prepareWrite(patient.id);
      if (db == null) return null;
      if (!wasDirty) await _incrementCounter(_uid!, db);
      try {
        final version = _nextVersion();
        final n = await db.transaction((txn) async => txn.update(
            'patients',
            {
              ...await _rowKeepingSwaps(txn, patient),
              'sync_state': SyncState.dirty,
              'updated_at': version,
            },
            where: 'id = ?',
            whereArgs: [patient.id]));
        return n > 0 ? '$version' : null;
      } catch (e) {
        debugPrint('SQLITE update error: ${_describe(e)}');
        return null;
      }
    });
  }

  /// [_row] for a local whole-row save, with every attachment entry that
  /// keys to a path already swapped for this patient (`attachment_swaps`)
  /// kept as the recorded Storage path, so a stale in-memory copy cannot
  /// put the local path back. Mappings the saved row no longer references
  /// at all (the photo was removed) are deleted, so a later stale
  /// pre-upload copy is not turned back into the Storage path. Runs in the
  /// caller's transaction; other patients' mappings are untouched. Never
  /// used for cloud copies ([_applyCloud]).
  Future<Map<String, Object?>> _rowKeepingSwaps(
      DatabaseExecutor txn, Patient patient) async {
    final row = _row(patient);
    final recorded = await txn.query('attachment_swaps',
        columns: ['local_key', 'storage_path'],
        where: 'patient_id = ?',
        whereArgs: [patient.id]);
    if (recorded.isEmpty) return row;
    final swaps = {
      for (final r in recorded)
        r['local_key'] as String: r['storage_path'] as String,
    };
    final (history, n) = AttachmentRefs.applySwapsToHistoryJson(
        row['history'] as String, swaps,
        uid: _uid!, patientId: patient.id);
    for (final k
        in AttachmentRefs.unreferencedSwapKeys(history, swaps, uid: _uid!)) {
      await txn.delete('attachment_swaps',
          where: 'patient_id = ? AND local_key = ?',
          whereArgs: [patient.id, k]);
    }
    if (n == 0) return row;
    debugPrint('SQLITE: kept $n uploaded attachment path(s) on a local save');
    return {...row, 'history': history};
  }

  /// How long a swap mapping is kept. Pruned on open; by then no in-memory
  /// copy from before the upload can still be saved.
  static const Duration attachmentSwapRetention = Duration(days: 30);

  /// Deletes swap mappings older than [attachmentSwapRetention]. Never
  /// blocks the open.
  Future<void> _pruneAttachmentSwaps(Database db) async {
    try {
      final cutoff = DateTime.now()
          .subtract(attachmentSwapRetention)
          .millisecondsSinceEpoch;
      await db.delete('attachment_swaps',
          where: 'swapped_at < ?', whereArgs: [cutoff]);
    } catch (e) {
      debugPrint('Attachment swap prune failed: ${_describe(e)}');
    }
  }

  /// The open database and whether row [id] is already dirty, or
  /// `(null, false)` (logged) if no database is usable.
  Future<(Database?, bool)> _prepareWrite(String id) async {
    try {
      final db = await database;
      return (db, await _isDirty(db, id));
    } catch (e) {
      debugPrint('SQLITE write refused: ${_describe(e)}');
      return (null, false);
    }
  }

  bool _refuseUnparsed(Patient patient) {
    if (!patient.hasParseErrors) return false;
    debugPrint('SQLITE: refusing to write unparsed patient ${patient.id}');
    return true;
  }

  /// Compare-and-set after Firestore confirmed a write: marks [patientId]
  /// clean, and only then decrements the unsynced counter, if the row's
  /// `updated_at` still equals [syncedUpdatedAt] (the value returned by the
  /// write, or [Patient.updatedAt] from [dirtyPatients], that was sent). If
  /// the row was edited while the write was in flight, returns false and
  /// leaves it dirty. One UPDATE; the extra `sync_state = dirty` condition
  /// makes a repeated confirmation a no-op instead of a second decrement.
  @override
  Future<bool> markSynced(String patientId, String syncedUpdatedAt) {
    final version = int.tryParse(syncedUpdatedAt);
    if (version == null) return Future.value(false);
    return _rowSerial(() async {
      try {
        final db = await database;
        final n = await db.rawUpdate(
            'UPDATE patients SET sync_state = ? '
            'WHERE id = ? AND updated_at = ? AND sync_state = ?',
            [SyncState.synced, patientId, version, SyncState.dirty]);
        if (n > 0) await _decrementCounter(_uid!, db);
        return n > 0;
      } catch (e) {
        debugPrint('SQLITE markSynced error: ${_describe(e)}');
        return false;
      }
    });
  }

  /// Rows with unconfirmed local changes, oldest `updated_at` first. Each
  /// carries [Patient.updatedAt] for [markSynced]. Rows that fail to parse
  /// are included (flagged, read-only) so callers can see them, but must
  /// not be pushed.
  ///
  /// Returns empty on error; do not use for destructive or "nothing to
  /// push" decisions; use [dirtyPatientsStrict] instead.
  @override
  Future<List<Patient>> dirtyPatients() async {
    try {
      final db = await database;
      final rows = await db.query('patients',
          where: 'sync_state != ?',
          whereArgs: [SyncState.synced],
          orderBy: 'updated_at ASC, id ASC');
      return rows.map(_patientFromRow).toList();
    } catch (e) {
      debugPrint('SQLITE dirty fetch error: ${_describe(e)}');
      return [];
    }
  }

  /// Deletes row [id] and records a tombstone for it in one transaction.
  /// The tombstone counts as one unsynced change (a dirty row it replaces
  /// was already counted), is never undone by [applyCloudPatient], and
  /// stays until [clearPendingDelete]. Throws if refused, with nothing
  /// written: [DbOpenException] (no database open),
  /// [UnsyncedCounterException] (counter cannot be kept honest) or the
  /// database error.
  @override
  Future<void> markPendingDelete(String id) {
    return _rowSerial(() async {
      final db = await database;
      final before = (await _isDirty(db, id) ? 1 : 0) +
          (await _hasTombstone(db, id) ? 1 : 0);
      if (before == 0) await _incrementCounter(_uid!, db);
      try {
        await db.transaction((txn) async {
          await txn.delete('patients', where: 'id = ?', whereArgs: [id]);
          await txn.delete('attachment_swaps',
              where: 'patient_id = ?', whereArgs: [id]);
          await txn.insert(
              'pending_deletes',
              {
                'patient_id': id,
                'deleted_at': DateTime.now().millisecondsSinceEpoch,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        });
      } catch (e) {
        // The counter may now over-count by one: safe, reconciled on open.
        debugPrint('SQLITE delete error: ${_describe(e)}');
        rethrow;
      }
      // A dirty row and an older tombstone became one tombstone.
      if (before == 2) await _decrementCounter(_uid!, db);
    });
  }

  /// See [LocalDatabase.swapAttachmentPath]. Reads and writes the raw
  /// stored row inside one transaction under the row write queue, so a
  /// write queued before it is seen and one queued after it sees the swap.
  @override
  Future<bool> swapAttachmentPath(
      {required String expectedOwner,
      required String patientId,
      required String localPath,
      required String storagePath}) {
    final String key;
    try {
      key = AttachmentRefs.swapKeyFor(
          expectedOwner: expectedOwner,
          patientId: patientId,
          localPath: localPath,
          storagePath: storagePath);
    } on ArgumentError catch (e) {
      return Future.error(e);
    }
    const notOpen = DbReadException(DbReadFailure.notOpen);
    const unreadable = DbReadException(DbReadFailure.unreadableRow);
    return _rowSerial(() async {
      final Database db;
      try {
        db = await database;
      } catch (_) {
        throw notOpen;
      }
      if (_uid != expectedOwner) throw notOpen;
      try {
        return await db.transaction((txn) async {
          // Owner check inside the transaction: nothing is written for a
          // DB that is no longer the expected owner's.
          if (_uid != expectedOwner || !identical(_db, db)) throw notOpen;
          if (await _hasTombstone(txn, patientId)) return false;
          final rows = await txn.query('patients',
              where: 'id = ?', whereArgs: [patientId], limit: 1);
          if (rows.isEmpty) return false;
          final row = rows.first;
          if (_patientFromRow(row).hasParseErrors) throw unreadable;
          final history = row['history'];
          if (history == null) return false; // no visits
          if (history is! String) throw unreadable;
          final String? next;
          try {
            next = AttachmentRefs.swapInHistoryJson(history,
                key: key,
                ownerFolderName:
                    AttachmentRefs.ownerFolderNameFor(expectedOwner),
                storagePath: storagePath);
          } on FormatException {
            throw unreadable;
          }
          if (next == null) return false; // the photo is gone
          // Count a clean row before it turns dirty (never under-reports).
          if (row['sync_state'] == SyncState.synced) {
            await _incrementCounter(expectedOwner, txn);
          }
          final n = await txn.update(
              'patients',
              {
                'history': next,
                'sync_state': SyncState.dirty,
                'updated_at': _nextVersion(),
              },
              where: 'id = ?',
              whereArgs: [patientId]);
          if (n != 1) throw const DbReadException(DbReadFailure.readFailed);
          // Remember the swap so a stale whole-row save keeps storagePath.
          await txn.insert(
              'attachment_swaps',
              {
                'patient_id': patientId,
                'local_key': key,
                'storage_path': storagePath,
                'swapped_at': DateTime.now().millisecondsSinceEpoch,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
          return true;
        });
      } on DbReadException {
        rethrow;
      } on UnsyncedCounterException {
        rethrow;
      } catch (e) {
        debugPrint('SQLITE attachment swap error: ${_describe(e)}');
        throw const DbReadException(DbReadFailure.readFailed);
      }
    });
  }

  /// Same as [markPendingDelete] (kept for existing callers).
  @override
  Future<void> deletePatient(String id) => markPendingDelete(id);

  /// Returns empty on error (one non-text tombstone id hides them all); do
  /// not use for destructive or "nothing to do" decisions; use
  /// [pendingDeletesStrict] instead.
  @override
  Future<List<String>> pendingDeletes() async {
    try {
      final db = await database;
      final rows = await db.query('pending_deletes',
          columns: ['patient_id'], orderBy: 'deleted_at ASC, patient_id ASC');
      return [for (final r in rows) r['patient_id'] as String];
    } catch (e) {
      debugPrint('SQLITE pending deletes error: ${_describe(e)}');
      return [];
    }
  }

  /// Only after Firestore confirmed deleting [id]: removes the tombstone,
  /// then decrements the counter. A no-op if there is none (a repeated
  /// confirmation never double-decrements). Throws on database errors.
  @override
  Future<void> clearPendingDelete(String id) {
    return _rowSerial(() async {
      final db = await database;
      final n = await db.delete('pending_deletes',
          where: 'patient_id = ?', whereArgs: [id]);
      if (n > 0) await _decrementCounter(_uid!, db);
    });
  }

  // --- settings ------------------------------------------------------------
  // Local-only key-value rows. They never touch sync_state or the unsynced
  // counter. All three throw if no database is open (or it failed to open).
  // Errors are not logged here: sqflite messages include the SQL arguments,
  // i.e. the value, so callers should log only describeDbError(e).

  @override
  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query('settings',
        columns: ['value'], where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  @override
  Future<void> putSetting(String key, String value) async {
    final db = await database;
    await db.rawInsert(
        'INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value, '
        'updated_at = excluded.updated_at',
        [key, value, DateTime.now().millisecondsSinceEpoch]);
  }

  @override
  Future<void> deleteSetting(String key) async {
    final db = await database;
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  // --- attachment references ---------------------------------------------

  @override
  Future<Set<String>> referencedAttachmentPaths() async =>
      (await _scanAttachmentRefs()).paths;

  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    final scan = await _scanAttachmentRefs();
    return AttachmentRefs.referencedKeys(scan.paths,
        ownerFolderName: AttachmentRefs.ownerFolderNameFor(scan.owner));
  }

  /// One read transaction over `patients.history` and the doctor profile
  /// setting. Never waits for an open in progress and never opens anything.
  Future<({Set<String> paths, String owner})> _scanAttachmentRefs() async {
    final state = _state;
    final db = _db;
    final owner = _uid;
    if (state is DbFailed) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.openFailed);
    }
    if (db == null || state is! DbReady || owner == null) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.noDatabase);
    }
    List<Map<String, Object?>> rows;
    List<Map<String, Object?>> profile;
    try {
      (rows, profile) = await db.transaction((txn) async {
        final r = await txn.query('patients', columns: ['history']);
        final s = await txn.query('settings',
            columns: ['value'],
            where: 'key = ?',
            whereArgs: [AttachmentRefs.doctorProfileSettingKey],
            limit: 1);
        return (r, s);
      });
    } catch (e) {
      debugPrint('Attachment scan: read failed (${describeDbError(e)})');
      throw const AttachmentScanIncomplete(AttachmentScanFailure.readFailed);
    }
    final paths = AttachmentRefs.collectReferencedPaths(
      historyValues: rows.map((r) => r['history']),
      doctorProfileValue: profile.isEmpty ? null : profile.first['value'],
    );
    return (paths: paths, owner: owner);
  }

  /// All patients. Each row is parsed on its own, so one bad row no longer
  /// hides every patient; a row that fails to parse comes back flagged
  /// ([Patient.hasParseErrors]) with its stored data kept, and is read-only.
  ///
  /// Returns empty on error; do not use for destructive, overwrite or
  /// "nothing to do" decisions, or to show "no patients"; use
  /// [fetchPatientsStrict] instead.
  @override
  Future<List<Patient>> fetchPatients() async {
    try {
      final db = await database;
      final rows = await db.query('patients');
      return rows.map(_patientFromRow).toList();
    } catch (e) {
      debugPrint('SQLITE fetch error: ${_describe(e)}');
      return [];
    }
  }

  // --- strict reads ----------------------------------------------------------
  //
  // Same queries as the lenient reads, but they never turn a failure into
  // an empty or partial answer: they throw DbReadException(reason) with no
  // patient data. The underlying error is logged only as a sanitized code.

  @override
  Future<List<Patient>> fetchPatientsStrict() => _strictRead('patients',
      (db) async => patientsFromRowsStrict(await db.query('patients')));

  @override
  Future<List<Patient>> dirtyPatientsStrict() => _strictRead(
      'dirty',
      (db) async => patientsFromRowsStrict(await db.query('patients',
          where: 'sync_state != ?',
          whereArgs: [SyncState.synced],
          orderBy: 'updated_at ASC, id ASC')));

  @override
  Future<List<String>> pendingDeletesStrict() => _strictRead(
      'pending deletes',
      (db) async => tombstoneIdsStrict(await db.query('pending_deletes',
          columns: ['patient_id'],
          orderBy: 'deleted_at ASC, patient_id ASC')));

  /// Runs [body] on the open database. `notOpen` if there is none (or its
  /// open failed), or if a different database is open by the time the read
  /// finishes; `readFailed` for any other error.
  Future<T> _strictRead<T>(
      String what, Future<T> Function(Database db) body) async {
    final Database db;
    try {
      db = await database; // waits for an open in progress
    } catch (_) {
      throw const DbReadException(DbReadFailure.notOpen);
    }
    final uid = _uid;
    if (uid == null || !identical(_db, db)) {
      throw const DbReadException(DbReadFailure.notOpen);
    }
    final T result;
    try {
      result = await body(db);
    } on DbReadException {
      rethrow;
    } catch (e) {
      debugPrint('SQLITE strict $what read failed: ${_describe(e)}');
      throw const DbReadException(DbReadFailure.readFailed);
    }
    if (_uid != uid || !identical(_db, db)) {
      throw const DbReadException(DbReadFailure.notOpen);
    }
    return result;
  }

  /// [rows] as patients, or throws `unreadableRow` if any row cannot be
  /// decoded or would come back flagged ([Patient.hasParseErrors]).
  @visibleForTesting
  static List<Patient> patientsFromRowsStrict(
      List<Map<String, Object?>> rows) {
    final out = <Patient>[];
    for (final row in rows) {
      final Patient p;
      try {
        p = _patientFromRow(row);
      } catch (_) {
        throw const DbReadException(DbReadFailure.unreadableRow);
      }
      if (p.hasParseErrors) {
        throw const DbReadException(DbReadFailure.unreadableRow);
      }
      out.add(p);
    }
    return out;
  }

  /// The tombstone ids in [rows], or throws `unreadableRow` if any is not
  /// a non-empty string.
  @visibleForTesting
  static List<String> tombstoneIdsStrict(List<Map<String, Object?>> rows) => [
        for (final r in rows)
          switch (r['patient_id']) {
            final String id when id.isNotEmpty => id,
            _ => throw const DbReadException(DbReadFailure.unreadableRow),
          },
      ];

  static Patient _patientFromRow(Map<String, Object?> row) {
    final json = <String, dynamic>{
      for (final k in const ['id', 'name', 'age', 'gender', 'phone', 'relation'])
        k: row[k],
    };
    final rawHistory = row['history'];
    Object? history = rawHistory;
    if (rawHistory is String) {
      try {
        history = jsonDecode(rawHistory);
      } catch (_) {
        // Not JSON: Patient.fromJson flags it and keeps the raw string.
      }
    }
    json['history'] = history;
    final updatedAt = row['updated_at'];
    return Patient.fromJson(json,
        updatedAt: updatedAt == null ? null : '$updatedAt');
  }

  // --- unsynced counter ----------------------------------------------------
  //
  // A per-uid count of dirty rows kept in secure storage, outside the
  // database, so it is still readable when the database is not (keyMismatch,
  // exactly when reset is offered). It only ever errs high: increments happen
  // before the row write, decrements only after the row is confirmed clean.
  // Missing or unreadable means unknown. It is reconciled against the real
  // rows on every successful open and whenever the database is readable.

  /// The unsynced count for the current doctor: exact from the rows when the
  /// database is open, otherwise the stored counter (or unknown).
  @override
  Future<UnsyncedCount> unsyncedCount() {
    return _rowSerial(() async {
      final db = _db;
      final uid = _uid ?? _state.uid;
      if (uid == null) return UnsyncedCount.unknown;
      if (db != null && _uid == uid) {
        try {
          final n = await _countDirty(db);
          await _writeCounter(uid, n);
          return UnsyncedCount.known(n);
        } catch (e) {
          debugPrint('SQLITE unsynced count error: ${_describe(e)}');
        }
      }
      return _readCounter(uid);
    });
  }

  Future<UnsyncedCount> _readCounter(String uid) async {
    try {
      final n = int.tryParse(await _keys.read(unsyncedCounterKeyFor(uid)) ?? '');
      return (n == null || n < 0) ? UnsyncedCount.unknown : UnsyncedCount.known(n);
    } catch (_) {
      return UnsyncedCount.unknown;
    }
  }

  /// Before a row goes dirty. Never lets the counter under-report: if the
  /// new value cannot be stored, the counter is deleted (reads as unknown);
  /// if even that fails, throws [UnsyncedCounterException] and the caller
  /// must not write the row.
  Future<void> _incrementCounter(String uid, DatabaseExecutor db) async {
    final name = unsyncedCounterKeyFor(uid);
    try {
      final current = await _readCounter(uid);
      final next = current is UnsyncedKnown
          ? current.count + 1
          // Unknown: rebuild from the rows (the pending row is not dirty yet).
          : await _countDirty(db) + 1;
      await _keys.write(name, '$next');
    } catch (e) {
      debugPrint('Unsynced counter increment failed: ${e.runtimeType}');
      try {
        await _keys.delete(name);
      } catch (e2) {
        throw UnsyncedCounterException(uid, e2);
      }
    }
  }

  /// After a row is confirmed clean (or deleted). A failure just leaves an
  /// overcount, which is safe; the reconcile on the next open fixes it.
  Future<void> _decrementCounter(String uid, Database db) async {
    try {
      final current = await _readCounter(uid);
      if (current is! UnsyncedKnown) return; // stays unknown until reconcile
      await _keys.write(
          unsyncedCounterKeyFor(uid), '${max(0, current.count - 1)}');
    } catch (e) {
      debugPrint('Unsynced counter decrement failed: ${e.runtimeType}');
    }
  }

  Future<void> _reconcileCounter(String uid, Database db) async {
    try {
      await _writeCounter(uid, await _countDirty(db));
    } catch (e) {
      debugPrint('Unsynced counter reconcile failed: ${_describe(e)}');
      await _forgetCounter(uid);
    }
  }

  /// Sets the exact count. On failure the counter is deleted (unknown); if
  /// that fails too the previous value stays, which never under-reports
  /// because every earlier change kept it at or above the real count.
  Future<void> _writeCounter(String uid, int n) async {
    try {
      await _keys.write(unsyncedCounterKeyFor(uid), '$n');
    } catch (e) {
      debugPrint('Unsynced counter write failed: ${e.runtimeType}');
      await _forgetCounter(uid);
    }
  }

  /// Makes the counter unknown (the strongest warning) rather than stale.
  Future<void> _forgetCounter(String uid) async {
    try {
      await _keys.delete(unsyncedCounterKeyFor(uid));
    } catch (e) {
      debugPrint('Unsynced counter delete failed: ${e.runtimeType}');
    }
  }

  /// Unsynced changes: dirty rows plus delete tombstones.
  Future<int> _countDirty(DatabaseExecutor db) async {
    final r = await db.rawQuery(
        'SELECT (SELECT COUNT(*) FROM patients WHERE sync_state != ?) + '
        '(SELECT COUNT(*) FROM pending_deletes) AS c',
        [SyncState.synced]);
    return r.first['c'] as int;
  }

  Future<bool> _hasTombstone(DatabaseExecutor db, String id) async {
    final r = await db.query('pending_deletes',
        columns: ['patient_id'],
        where: 'patient_id = ?',
        whereArgs: [id],
        limit: 1);
    return r.isNotEmpty;
  }

  Future<bool> _isDirty(Database db, String id) async {
    final r = await db.query('patients',
        columns: ['sync_state'], where: 'id = ?', whereArgs: [id], limit: 1);
    return r.isNotEmpty && r.first['sync_state'] != SyncState.synced;
  }

  // --- keys ----------------------------------------------------------------

  /// 32 bytes from [Random.secure], hex-encoded (64 chars) and used as the
  /// SQLCipher passphrase; hex avoids quoting issues across platforms.
  @visibleForTesting
  static String generateKey() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// The stored key, or null if there is none. Fails closed: a storage
  /// error, or a value that is not exactly 64 hex chars (an empty key would
  /// make SQLCipher create a plaintext file), is keyUnavailable, and the
  /// entry is left as it is.
  Future<String?> _readKey(String name, String uid) async {
    final String? value;
    try {
      value = await _keys.read(name);
    } catch (e) {
      debugPrint('Secure storage read failed: ${_describe(e)}');
      throw DbOpenException(DbOpenError.keyUnavailable, uid: uid, cause: e);
    }
    if (value != null && !_hexKeyPattern.hasMatch(value)) {
      debugPrint('Stored database key is malformed; refusing to use it.');
      throw DbOpenException(DbOpenError.keyUnavailable, uid: uid);
    }
    return value;
  }

  /// Last line of defence before any keyed open: never an empty or
  /// malformed key (legacy keys are only used on migration copies).
  static String _requireKey(String key) {
    if (!_hexKeyPattern.hasMatch(key) &&
        !_legacyUuidPattern.hasMatch(key) &&
        key != _legacyFallbackKey) {
      throw StateError('Refusing to open with a malformed key.');
    }
    return key;
  }

  /// The raw 32 bytes of a 64-hex-char key.
  @visibleForTesting
  static Uint8List hexDecodeKey(String key) {
    if (!_hexKeyPattern.hasMatch(key)) {
      throw StateError('Not a 64-hex-char key.');
    }
    return Uint8List.fromList([
      for (var i = 0; i < key.length; i += 2)
        int.parse(key.substring(i, i + 2), radix: 16),
    ]);
  }

  static String _toHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static final RegExp _kcvFormat = RegExp(r'^v1:([0-9a-f]{64})$');

  /// Whether the key-check sidecar matches [key]. Missing, unreadable or
  /// malformed sidecars are [_Kcv.missing] (ambiguous).
  Future<_Kcv> _checkKcv(String path, String key, String uid) async {
    final String stored;
    try {
      final f = File(kcvPathFor(path));
      if (!await f.exists()) return _Kcv.missing;
      stored = (await f.readAsString()).trim();
    } catch (_) {
      return _Kcv.missing;
    }
    final m = _kcvFormat.firstMatch(stored);
    if (m == null) return _Kcv.missing;
    final storedBytes = [
      for (var i = 0; i < 64; i += 2)
        int.parse(m.group(1)!.substring(i, i + 2), radix: 16),
    ];
    return constantTimeEquals(storedBytes, keyCheckBytes(key, uid))
        ? _Kcv.match
        : _Kcv.mismatch;
  }

  /// Atomically (temp file, flush, rename) binds [key] to the file at
  /// [path]. Throws on failure.
  Future<void> _writeKcv(String path, String key, String uid) async {
    final target = kcvPathFor(path);
    final tmp = '$target.tmp';
    await Directory(p.dirname(path)).create(recursive: true);
    await File(tmp).writeAsString(_kcvText(key, uid), flush: true);
    await File(tmp).rename(target);
  }

  /// Length first, then XOR-accumulates over every byte (no early exit), so
  /// the time taken does not depend on where the values differ.
  @visibleForTesting
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Generates and persists a new key, reading it back before anything is
  /// encrypted with it, so a key that was not saved is never used.
  Future<String> _createKey(String name, String uid) async {
    final key = generateKey();
    try {
      await _keys.write(name, key);
      if (await _keys.read(name) != key) {
        throw StateError('Key read-back mismatch');
      }
      return key;
    } catch (e) {
      debugPrint('Secure storage write failed: ${e.runtimeType}');
      throw DbOpenException(DbOpenError.keyUnavailable, uid: uid, cause: e);
    }
  }

  // --- files & errors ------------------------------------------------------

  void _checkUid(String uid) {
    if (!_uidPattern.hasMatch(uid)) {
      throw ArgumentError.value(uid, 'uid', 'Not a valid owner id (1-128 chars of A-Za-z0-9_-)');
    }
  }

  Future<String> _pathFor(String fileName) async =>
      p.join(await _databasesPath(), fileName);

  Future<bool> _hasData(String path) async {
    final f = File(path);
    return await f.exists() && await f.length() > 0;
  }

  Future<bool> _isReadable(String path) async {
    try {
      await _head(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>> _head(String path) async {
    final raf = await File(path).open();
    try {
      return await raf.read(16);
    } finally {
      await raf.close();
    }
  }

  /// First 16 bytes as hex: for an encrypted file, its random SQLCipher salt.
  Future<String> _headHex(String path) async => (await _head(path))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  Future<bool> _isPlaintext(String path) async {
    final head = await _head(path);
    return head.length == 16 && String.fromCharCodes(head) == _sqliteHeader;
  }

  /// Removes migration work files left by a crash, for every doctor and the
  /// legacy file (they can hold a plaintext copy of patient data).
  Future<void> _sweepStrayTemps() async {
    try {
      final dir = Directory(await _databasesPath());
      if (!await dir.exists()) return;
      await for (final f in dir.list(followLinks: false)) {
        if (f is File && _tempFilePattern.hasMatch(p.basename(f.path))) {
          await _shred(f.path);
        }
      }
    } catch (e) {
      debugPrint('Temp file sweep failed: ${_describe(e)}');
    }
  }

  /// Best effort: overwrite with zeros, then delete. On flash storage this
  /// does not guarantee the old blocks are gone (wear levelling, APFS
  /// copy-on-write); it removes the easy recovery path.
  Future<void> _shred(String path) async {
    final f = File(path);
    try {
      if (!await f.exists()) return;
      var left = await f.length();
      final raf = await f.open(mode: FileMode.append);
      try {
        await raf.setPosition(0);
        final zeros = Uint8List(64 * 1024);
        while (left > 0) {
          final n = min(left, zeros.length);
          await raf.writeFrom(zeros, 0, n);
          left -= n;
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint('Overwrite before delete failed: ${_describe(e)}');
    }
    await _safeDelete(path);
  }

  Future<void> _shredDbFiles(String path) async {
    for (final s in ['', ..._sidecars]) {
      await _shred('$path$s');
    }
  }

  /// Renames the database, its sidecars and its key-check value to
  /// `<name><suffix>...`. Sidecars first; if anything cannot be moved, what
  /// was moved is moved back and the error is rethrown (nothing changed).
  Future<void> _quarantine(String path, String suffix) async {
    final moved = <(String, String)>[];
    Future<void> move(String from, String to) async {
      if (!await File(from).exists()) return;
      await File(from).rename(to);
      moved.add((from, to));
    }

    try {
      for (final s in _sidecars) {
        await move('$path$s', '$path$suffix$s');
      }
      await move(kcvPathFor(path), kcvPathFor('$path$suffix'));
      await move(path, '$path$suffix');
    } catch (e) {
      for (final (from, to) in moved.reversed) {
        try {
          await File(to).rename(from);
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _deleteDbFiles(String path) async {
    for (final s in ['', ..._sidecars]) {
      await _safeDelete('$path$s');
    }
  }

  Future<void> _safeDelete(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('Could not delete ${p.basename(path)}: ${e.runtimeType}');
    }
  }

  static String _sqlQuote(String s) => s.replaceAll("'", "''");

  /// Sanitized description (kind + result code), never the message: sqflite
  /// messages include SQL arguments, which can hold keys or patient data.
  static String _describe(Object e) => describeDbError(e) ?? 'unknown';

  static DbOpenError _classifyFatal(Object e, DbOpenError otherwise) {
    if (e is DbOpenException) return e.error;
    if (e is FileSystemException) {
      final code = e.osError?.errorCode;
      // ENOSPC is 28 on Linux/Android/iOS; 39/112 are Windows disk-full codes.
      if (code == 28 || code == 39 || code == 112) {
        return DbOpenError.storageFull;
      }
    }
    if (e is DatabaseException && e.getResultCode() == 13) {
      return DbOpenError.storageFull;
    }
    final m = e.toString().toLowerCase();
    if (m.contains('database or disk is full') ||
        m.contains('sqlite_full') ||
        m.contains('no space left')) {
      return DbOpenError.storageFull;
    }
    return otherwise;
  }
}

enum _Kcv { match, mismatch, missing }
