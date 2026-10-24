import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
import 'package:sqflite_sqlcipher/sqflite.dart'
    show
        ConflictAlgorithm,
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
  // Same (default) options as the previous implementation so the existing
  // legacy key stays readable; changing options can hide it.
  const SecureStorageKeyStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String name) => _storage.read(key: name);
  @override
  Future<void> write(String name, String value) =>
      _storage.write(key: name, value: value);
  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}

/// Opens SQLCipher databases. Implementations MUST verify the key during
/// [open] (throw if it does not decrypt the file). A `null` key means
/// plaintext. Every call returns a fresh connection (no single-instance
/// caching) that the caller must close.
abstract class CipherDatabaseOpener {
  Future<Database> open(
    String path, {
    String? key,
    int? version,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
  });
}

/// Production opener backed by sqflite_sqlcipher. Both the Android and iOS
/// plugins verify the key at open time by querying the schema.
class SqlCipherOpener implements CipherDatabaseOpener {
  const SqlCipherOpener();
  @override
  Future<Database> open(
    String path, {
    String? key,
    int? version,
    OnDatabaseCreateFn? onCreate,
    OnDatabaseVersionChangeFn? onUpgrade,
    OnDatabaseVersionChangeFn? onDowngrade,
  }) {
    return sqlcipher.openDatabase(
      path,
      password: key ?? '',
      version: version,
      onCreate: onCreate,
      onUpgrade: onUpgrade,
      onDowngrade: onDowngrade,
      singleInstance: false,
    );
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
    @visibleForTesting int schemaVersion = currentSchemaVersion,
    @visibleForTesting MigrationHook? migrationHook,
  })  : assert(schemaVersion >= 1 && schemaVersion <= currentSchemaVersion),
        _keys = keyStore ?? const SecureStorageKeyStore(),
        _opener = opener ?? const SqlCipherOpener(),
        _databasesPath = databasesPath ?? sqlcipher.getDatabasesPath,
        _schemaVersion = schemaVersion,
        _hook = migrationHook;

  /// App-wide instance with the production dependencies.
  static final DatabaseHelper instance = DatabaseHelper();

  final DbKeyStore _keys;
  final CipherDatabaseOpener _opener;
  final Future<String> Function() _databasesPath;
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

  static String dbFileNameFor(String uid) => 'docease_$uid.db';
  static String keyNameFor(String uid) => 'db_key_$uid';
  static String unsyncedCounterKeyFor(String uid) => 'unsynced_count_$uid';

  // Firebase uids are <=128 chars, alphanumeric in practice. Anything else is
  // rejected so a uid can never escape the databases directory.
  static final RegExp _uidPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
  static final RegExp _hexKeyPattern = RegExp(r'^[0-9a-f]{64}$');
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
      if (_schemaVersion >= 2) await _reconcileCounter(uid, db);
      _emit(DbReady(uid));
      return db;
    } on DbOpenException catch (e) {
      _emit(DbFailed(uid, e.error, e.cause));
      rethrow;
    } catch (e) {
      final err = _classifyFatal(e, DbOpenError.migrationFailed);
      _emit(DbFailed(uid, err, e));
      throw DbOpenException(err, uid: uid, cause: e);
    }
  }

  Future<Database> _openScopedLocked(String uid) async {
    final path = await _pathFor(dbFileNameFor(uid));
    final keyName = keyNameFor(uid);
    await _deleteStrayTemps(path);

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
      await _replaceFile(out!, path);
    }

    if (key == null) {
      // An encrypted file and no key for it: nothing can decrypt it.
      throw DbOpenException(DbOpenError.keyMismatch, uid: uid);
    }
    return _openMain(path, key, uid);
  }

  Future<Database> _openMain(String path, String key, String uid) async {
    try {
      return await _opener.open(
        path,
        key: key,
        version: _schemaVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: _onDowngrade,
      );
    } catch (e) {
      if (_isNotADatabase(e) && await _isReadable(path)) {
        throw DbOpenException(DbOpenError.keyMismatch, uid: uid, cause: e);
      }
      throw DbOpenException(_classifyFatal(e, DbOpenError.migrationFailed),
          uid: uid, cause: e);
    }
  }

  Future<Database> _createFresh(String path, String key, String uid) async {
    try {
      await Directory(p.dirname(path)).create(recursive: true);
      await _deleteDbFiles(path); // only an empty/zero-byte file can be here
      return await _opener.open(path,
          key: key,
          version: _schemaVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
          onDowngrade: _onDowngrade);
    } catch (e) {
      // A brand-new file holds no user data: remove partial output.
      await _deleteDbFiles(path);
      throw DbOpenException(_classifyFatal(e, DbOpenError.migrationFailed),
          uid: uid, cause: e);
    }
  }

  // --- legacy (unscoped) database ------------------------------------------

  @override
  Future<bool> hasLegacyDb() => _serial(() async {
        final legacy = await _pathFor(legacyDbFileName);
        await _finishInterruptedClaim(legacy);
        return _hasData(legacy);
      });

  /// Returns true if the legacy database was claimed (and [uid]'s database is
  /// now open), or false, changing nothing, if there was nothing to claim, so
  /// a repeated claim (or a claim by another doctor afterwards) is a no-op.
  ///
  /// If `docease_{uid}.db` already exists it is replaced only when it holds
  /// no patients; otherwise this throws [StateError] (merging two databases
  /// is a product decision made elsewhere).
  @override
  Future<bool> claimLegacyDb(String uid) {
    _checkUid(uid);
    return _serial(() async {
      final legacy = await _pathFor(legacyDbFileName);
      final target = await _pathFor(dbFileNameFor(uid));
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
    await _deleteStrayTemps(target);
    final keyName = keyNameFor(uid);
    String? key = await _readKey(keyName, uid);
    if (await _hasData(target)) {
      if (key == null) throw DbOpenException(DbOpenError.keyMismatch, uid: uid);
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
      // Commit: marker (with the new file's salt), then atomic rename.
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

  /// Whether the existing target database has no patients.
  Future<bool> _isEmptyTarget(String target, String key, String uid) async {
    final Database db;
    try {
      db = await _opener.open(target, key: key);
    } catch (e) {
      if (_isNotADatabase(e)) {
        throw DbOpenException(DbOpenError.keyMismatch, uid: uid, cause: e);
      }
      rethrow;
    }
    try {
      final counts = await _rowCounts(db);
      return (counts['patients'] ?? 0) == 0;
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
    throw DbOpenException(DbOpenError.keyMismatch, uid: uid);
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
    if (committed) await _deleteDbFiles(legacy);
    await marker.delete();
  }

  // --- recovery engine -----------------------------------------------------

  /// Copies [sourcePath] (plus any journal/WAL sidecars, so SQLite can
  /// recover them) to a work file next to [workBase], converts the copy into
  /// an encrypted database under [targetKey], and verifies every table's row
  /// count, user_version and quick_check. Returns the verified output path.
  /// The source file itself is never opened or modified.
  ///
  /// With [probeOnly], a wrong [sourceKey] returns `null` instead of failing.
  Future<String?> _convertToEncrypted({
    required String uid,
    required String sourcePath,
    required String workBase,
    required String? sourceKey,
    required String targetKey,
    required DbMigrationStep step,
    bool probeOnly = false,
  }) async {
    if (!_hexKeyPattern.hasMatch(targetKey) && !_isLegacyUuidKey(targetKey)) {
      throw StateError('Refusing to migrate to a malformed key.');
    }
    final work = '$workBase.migrating';
    final exported = '$workBase.encrypting';
    await _deleteDbFiles(work);
    await _deleteDbFiles(exported);
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
        db = await _opener.open(work, key: sourceKey);
      } catch (e) {
        if (probeOnly && _isNotADatabase(e)) {
          await _deleteDbFiles(work);
          return null;
        }
        rethrow;
      }
      final expected = await _rowCounts(db);
      final userVersion = await _userVersion(db);
      _emit(DbMigrating(uid, step, 0.3));

      final String out;
      if (sourceKey == null) {
        await db.execute(
            'ATTACH DATABASE ? AS docease_enc KEY ?', [exported, targetKey]);
        await db.rawQuery("SELECT sqlcipher_export('docease_enc')");
        await db.rawQuery('PRAGMA docease_enc.user_version = $userVersion');
        await db.execute('DETACH DATABASE docease_enc');
        await db.close();
        db = null;
        await _deleteDbFiles(work);
        out = exported;
      } else {
        await db.rawQuery('PRAGMA journal_mode = DELETE');
        await db.rawQuery("PRAGMA rekey = '${_sqlQuote(targetKey)}'");
        await db.close();
        db = null;
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
      await _deleteDbFiles(work);
      await _deleteDbFiles(exported);
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
    final db = await _opener.open(path, key: key);
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

  /// Discards the current doctor's undecryptable database, starts a fresh one
  /// under a new key, then runs [resync] (for example a Firestore pull).
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
        // New key first: if storage fails, nothing has been deleted yet.
        final key = await _createKey(keyNameFor(uid), uid);
        await _deleteDbFiles(path);
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
    }
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

  /// Inserts or replaces a patient. Local edits are marked dirty; pass
  /// [fromCloud] for data that just came from Firestore. Returns the row's
  /// write version (for [markSynced]), or `null` if nothing was written.
  /// A patient with parse errors is never written (it would overwrite the
  /// stored data with placeholders).
  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) {
    if (_refuseUnparsed(patient)) return Future.value(null);
    return _rowSerial(() async {
      final (db, wasDirty) = await _prepareWrite(patient.id);
      if (db == null) return null;
      final uid = _uid!;
      // Counter never under-reports: count a new dirty row before writing it
      // (throws UnsyncedCounterException, refusing the save, if it can't)...
      if (!fromCloud && !wasDirty) await _incrementCounter(uid, db);
      try {
        final version = _nextVersion();
        await db.insert(
            'patients',
            {
              ..._row(patient),
              'sync_state': fromCloud ? SyncState.synced : SyncState.dirty,
              'updated_at': version,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        // ...and uncount a cleaned row only after the write succeeded.
        if (fromCloud && wasDirty) await _decrementCounter(uid, db);
        return '$version';
      } catch (e) {
        debugPrint('SQLITE insert error: ${_describe(e)}');
        return null;
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
        final n = await db.update(
            'patients',
            {
              ..._row(patient),
              'sync_state': SyncState.dirty,
              'updated_at': version,
            },
            where: 'id = ?',
            whereArgs: [patient.id]);
        return n > 0 ? '$version' : null;
      } catch (e) {
        debugPrint('SQLITE update error: ${_describe(e)}');
        return null;
      }
    });
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

  @override
  Future<void> deletePatient(String id) {
    return _rowSerial(() async {
      try {
        final db = await database;
        final wasDirty = await _isDirty(db, id);
        final n = await db.delete('patients', where: 'id = ?', whereArgs: [id]);
        if (wasDirty && n > 0) await _decrementCounter(_uid!, db);
      } catch (e) {
        debugPrint('SQLITE delete error: ${_describe(e)}');
      }
    });
  }

  /// All patients. Each row is parsed on its own, so one bad row no longer
  /// hides every patient; a row that fails to parse comes back flagged
  /// ([Patient.hasParseErrors]) with its stored data kept, and is read-only.
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
  Future<void> _incrementCounter(String uid, Database db) async {
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

  Future<int> _countDirty(Database db) async {
    final r = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM patients WHERE sync_state != ?',
        [SyncState.synced]);
    return r.first['c'] as int;
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

  Future<String?> _readKey(String name, String uid) async {
    try {
      return await _keys.read(name);
    } catch (e) {
      debugPrint('Secure storage read failed: ${e.runtimeType}');
      throw DbOpenException(DbOpenError.keyUnavailable, uid: uid, cause: e);
    }
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

  // Pre-v2 keys were UUID v4 strings; they remain valid passphrases.
  static bool _isLegacyUuidKey(String k) =>
      RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(k);

  // --- files & errors ------------------------------------------------------

  void _checkUid(String uid) {
    if (!_uidPattern.hasMatch(uid)) {
      throw ArgumentError.value(uid, 'uid', 'Not a valid Firebase uid');
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

  Future<void> _deleteStrayTemps(String base) async {
    await _deleteDbFiles('$base.migrating');
    await _deleteDbFiles('$base.encrypting');
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

  /// Error description without SQL arguments (which can contain patient data).
  static String _describe(Object e) => e is DatabaseException
      ? 'DatabaseException(code ${e.getResultCode()})'
      : e.runtimeType.toString();

  static bool _isNotADatabase(Object e) {
    if (e is DatabaseException && e.getResultCode() == 26) return true;
    final m = e.toString().toLowerCase();
    // Android/FFI: "file is not a database (code 26)". iOS reports a failed
    // key check only as a generic "open_failed".
    return m.contains('not a database') ||
        m.contains('sqlite_notadb') ||
        m.contains('open_failed');
  }

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
