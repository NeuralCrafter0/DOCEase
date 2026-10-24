import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/widgets.dart';

import '../providers/database_helper.dart';
import '../providers/doctor_provider.dart';
import '../providers/medicine_provider.dart';
import '../providers/patient_provider.dart';
import 'legacy_db_inspector.dart';
import 'local_attachment_files.dart';
import 'log_codes.dart';
import 'session_platform.dart';
import 'sync_cancel_token.dart';

/// Where the signed-in session is. The root widget shows HomeScreen only in
/// [ready]; every other phase has its own screen (SessionStatusView).
enum SessionPhase {
  /// Waiting for the first auth event.
  starting,
  signedOut,

  /// Signed in; checking verified email and `approvedDoctors/{uid}`.
  checkingApproval,

  /// Signed in but not allowed yet: see [SessionController.approvalStatus]
  /// (email not verified, not approved, or could not be checked).
  pendingApproval,

  /// The doctor's local database is being opened.
  opening,

  /// A recovery migration is running: see migrationStep / migrationProgress.
  migrating,

  /// A pre-update (unscoped) database was found whose patients do not all
  /// belong to this doctor in Firestore. The UI must ask, then call
  /// [SessionController.resolveLegacyMerge].
  legacyDecision,

  /// Opening failed: see [SessionController.failure]; offer retry, and
  /// reset only when [SessionController.canReset].
  failed,

  /// Local DB ready for this uid; patients, profile and medicines loading.
  ready,
}

enum LegacyMergeChoice {
  /// Claim the legacy database for this doctor (its patients join theirs).
  merge,

  /// Leave it untouched and start this doctor's own database. Remembered
  /// per uid so the question is not asked again.
  keepSeparate,
}

/// Data for the "merge old data?" question.
class LegacyMergePrompt {
  const LegacyMergePrompt({
    required this.uid,
    required this.legacyPatientCount,
    required this.matchingCloudCount,
    required this.cloudCheckFailed,
  });

  final String uid;

  /// Patients in the legacy database; null if it could not be read.
  final int? legacyPatientCount;

  /// How many of them exist in this doctor's Firestore data.
  final int matchingCloudCount;

  /// True when Firestore could not be reached, so ownership is unknown.
  final bool cloudCheckFailed;
}

/// Owns the signed-in session.
///
/// Listens to auth changes. On sign-out or a uid change it cancels running
/// sync, clears PatientProvider, DoctorProvider and MedicineProvider, closes
/// the local DB and drops the Firestore and image caches before the next
/// account loads. Sync never starts until the local DB reports
/// `DbReady(uid)` for the current uid; then patients, profile and medicines
/// load together. The unlock (biometric) screen sits above this.
class SessionController with ChangeNotifier {
  SessionController({
    Stream<User?>? authStateChanges,
    LocalDatabase? db,
    required PatientProvider patients,
    required DoctorProvider doctor,
    required MedicineProvider medicines,
    SessionPlatform? platform,
    LocalAttachmentFiles? localFiles,
    bool observeAppLifecycle = true,
  })  : _patients = patients,
        _localFiles = localFiles ?? LocalAttachmentFiles(),
        _doctor = doctor,
        _medicines = medicines,
        _db = db ?? DatabaseHelper.instance,
        _platform = platform ?? FirebaseSessionPlatform() {
    _dbSub = _db.states.listen(_onDbState);
    _authSub = (authStateChanges ?? FirebaseAuth.instance.authStateChanges())
        .listen(_onAuth, onError: (Object e) => debugPrint('Auth stream error: ${errorCode(e)}'));
    if (observeAppLifecycle) {
      try {
        _lifecycle = AppLifecycleListener(onResume: _onResume);
      } catch (_) {
        // No WidgetsBinding (plain unit tests): no resume hook.
      }
    }
  }

  static const _cacheWipeFlag = 'docease.firestoreCacheWiped.v1';
  static String _approvedFlag(String uid) => 'docease.approved.$uid';
  static String _legacyDeclinedFlag(String uid) => 'docease.legacyDeclined.$uid';

  final PatientProvider _patients;
  final DoctorProvider _doctor;
  final MedicineProvider _medicines;
  final LocalDatabase _db;
  final SessionPlatform _platform;
  final LocalAttachmentFiles _localFiles;

  StreamSubscription<DbOpenState>? _dbSub;
  StreamSubscription<User?>? _authSub;
  AppLifecycleListener? _lifecycle;

  SessionPhase _phase = SessionPhase.starting;
  bool _sawAuthEvent = false;
  User? _latestUser;
  String? _uid;
  ApprovalStatus? _approval;
  DbMigrationStep? _migrationStep;
  double _migrationProgress = 0;
  DbOpenError? _failure;
  LegacyMergePrompt? _legacyPrompt;
  String? _readyUid;
  SyncCancelToken? _token;
  bool _cacheWipeChecked = false;
  bool _disposed = false;

  /// Bumped on every auth change and retry; queued work for an older epoch
  /// stops at its next check.
  int _epoch = 0;
  Future<void> _queue = Future.value();

  SessionPhase get phase => _phase;
  bool get isReady => _phase == SessionPhase.ready;

  /// The uid this session belongs to (null when signed out).
  String? get uid => _uid;
  ApprovalStatus? get approvalStatus => _approval;
  DbMigrationStep? get migrationStep => _migrationStep;
  double get migrationProgress => _migrationProgress;
  DbOpenError? get failure => _failure;
  bool get canReset => _phase == SessionPhase.failed && _failure == DbOpenError.keyMismatch;
  LegacyMergePrompt? get legacyPrompt => _legacyPrompt;

  /// Completes when all queued session work has finished (for tests).
  Future<void> get idle => _queue;

  /// Unsynced local changes, for the reset warning. Never throws.
  Future<UnsyncedCount> unsyncedCount() => _db.unsyncedCount();

  // ---------------------------------------------------------------- auth

  void _onAuth(User? user) {
    final previous = _latestUser?.uid;
    _latestUser = user;
    final first = !_sawAuthEvent;
    _sawAuthEvent = true;
    if (!first && previous == user?.uid) return; // token refresh etc.
    if (_uid != null && _uid != user?.uid) {
      // Stop the old account's work and hide its data right now; the rest
      // of the teardown runs in order on the queue.
      _token?.cancel();
      _clearProviders();
    }
    _schedule();
  }

  void _schedule({bool restart = false}) {
    final e = ++_epoch;
    unawaited(_enqueue(() => _reconcile(e, restart: restart)).catchError((Object err) {
      debugPrint('Session error: ${errorCode(err)}');
    }));
  }

  Future<T> _enqueue<T>(Future<T> Function() job) {
    final c = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        c.complete(await job());
      } catch (e, s) {
        c.completeError(e, s);
      }
    });
    return c.future;
  }

  bool _stale(int e, String uid) => _disposed || e != _epoch || _latestUser?.uid != uid || _uid != uid;

  Future<void> _reconcile(int e, {required bool restart}) async {
    if (_disposed) return;
    final user = _latestUser;
    if (_uid != null && _uid != user?.uid) {
      await _endSession(fullSignOut: user == null);
    }
    if (e != _epoch) return; // a newer event will reconcile
    await _wipeLegacyCacheOnce();
    if (e != _epoch) return;
    if (user == null) {
      // Also covers a cold start that is already signed out (e.g. the app
      // was killed before the previous sign-out finished its cleanup).
      await _purgePickedPhotos();
      if (e != _epoch) return;
      _setPhase(SessionPhase.signedOut);
      return;
    }
    if (_uid == user.uid && !restart) return;
    await _startSession(user, e);
  }

  Future<void> _endSession({required bool fullSignOut}) async {
    _token?.cancel();
    _token = null;
    _clearProviders();
    _uid = null;
    _readyUid = null;
    _approval = null;
    _failure = null;
    _legacyPrompt = null;
    _migrationStep = null;
    _migrationProgress = 0;
    if (fullSignOut) await _platform.signOutGoogle();
    try {
      await _db.close();
    } catch (e) {
      debugPrint('DB close failed: ${errorCode(e)}');
    }
    try {
      await _platform.clearFirestoreCache();
    } catch (e) {
      debugPrint('Firestore cache clear failed: ${errorCode(e)}');
    }
    try {
      _platform.clearImageCache();
    } catch (_) {}
    // Picked visit photos are plain JPEGs outside the encrypted DB; none
    // may survive into the next account (or a signed-out phone).
    await _purgePickedPhotos();
  }

  Future<void> _purgePickedPhotos() async {
    final n = await _localFiles.purgePickedPhotos();
    if (n > 0) debugPrint('Deleted $n leftover picked photo(s)');
  }

  void _clearProviders() {
    _patients.clear();
    _doctor.clear();
    _medicines.clear();
  }

  /// Upgraded phones may still hold the old on-disk Firestore cache
  /// (persistence used to be on). Wipe it once, before any Firestore use.
  Future<void> _wipeLegacyCacheOnce() async {
    if (_cacheWipeChecked) return;
    _cacheWipeChecked = true;
    try {
      if (await _platform.readFlag(_cacheWipeFlag) != null) return;
      await _platform.clearFirestoreCache();
      await _platform.writeFlag(_cacheWipeFlag, '1');
    } catch (e) {
      debugPrint('One-time cache wipe failed (retried next launch): ${errorCode(e)}');
    }
  }

  Future<void> _startSession(User user, int e) async {
    final uid = user.uid;
    _token?.cancel();
    _token = SyncCancelToken();
    _uid = uid;
    _readyUid = null;
    _failure = null;
    _legacyPrompt = null;
    _setPhase(SessionPhase.checkingApproval);

    var status = ApprovalStatus.unknown;
    try {
      status = await _platform.checkApproval(user);
    } catch (_) {}
    if (_stale(e, uid)) return;
    if (status == ApprovalStatus.unknown && await _readFlag(_approvedFlag(uid)) == 'true') {
      // Offline start: trust the last server answer for this uid. The rules
      // still enforce approval on every request.
      status = ApprovalStatus.approved;
    }
    if (_stale(e, uid)) return;
    _approval = status;
    if (status == ApprovalStatus.approved) {
      unawaited(_writeFlag(_approvedFlag(uid), 'true'));
    } else if (status != ApprovalStatus.unknown) {
      unawaited(_deleteFlag(_approvedFlag(uid)));
    }
    if (status != ApprovalStatus.approved) {
      _setPhase(SessionPhase.pendingApproval);
      return;
    }
    await _openDatabase(uid, e);
  }

  // ---------------------------------------------------------- database

  Future<void> _openDatabase(String uid, int e) async {
    _setPhase(SessionPhase.opening);
    var hasLegacy = false;
    try {
      hasLegacy = await _db.hasLegacyDb();
    } catch (_) {}
    if (_stale(e, uid)) return;
    if (hasLegacy && await _readFlag(_legacyDeclinedFlag(uid)) != 'true') {
      if (_stale(e, uid)) return;
      final prompt = await _legacyCheck(uid);
      if (_stale(e, uid)) return;
      if (prompt != null) {
        _legacyPrompt = prompt;
        _setPhase(SessionPhase.legacyDecision);
        return;
      }
      await _claimLegacy(uid, e);
      return;
    }
    await _open(uid, e);
  }

  /// Null when the legacy data may be claimed silently (it is empty, or
  /// every legacy patient id is in this doctor's Firestore data); otherwise
  /// the question to ask.
  Future<LegacyMergePrompt?> _legacyCheck(String uid) async {
    final db = _db;
    Set<String>? legacy;
    try {
      legacy = db is LegacyDbInspector ? await (db as LegacyDbInspector).legacyPatientIds() : null;
    } catch (_) {
      legacy = null;
    }
    if (legacy != null && legacy.isEmpty) return null;
    final cloud = legacy == null ? null : await _platform.cloudPatientIds(uid);
    if (legacy != null && cloud != null && cloud.containsAll(legacy)) return null;
    return LegacyMergePrompt(
      uid: uid,
      legacyPatientCount: legacy?.length,
      matchingCloudCount: legacy == null || cloud == null ? 0 : legacy.where(cloud.contains).length,
      cloudCheckFailed: legacy != null && cloud == null,
    );
  }

  Future<void> _claimLegacy(String uid, int e) async {
    try {
      // false = no legacy file any more, or this doctor already has their own
      // data (then their DB is already open and the legacy file is kept).
      final claimed = await _db.claimLegacyDb(uid);
      if (_stale(e, uid)) return;
      final s = _db.state;
      if (!claimed && !(s is DbReady && s.uid == uid)) await _db.openFor(uid);
    } on DbOpenException catch (ex) {
      _fail(uid, ex.error);
      return;
    } catch (_) {
      _fail(uid, DbOpenError.migrationFailed);
      return;
    }
    if (_stale(e, uid)) return;
    _checkReady(uid);
  }

  Future<void> _open(String uid, int e) async {
    try {
      await _db.openFor(uid);
    } on DbOpenException catch (ex) {
      _fail(uid, ex.error);
      return;
    } catch (_) {
      _fail(uid, DbOpenError.migrationFailed);
      return;
    }
    if (_stale(e, uid)) return;
    _checkReady(uid);
  }

  void _fail(String uid, DbOpenError error) {
    if (_uid != uid) return;
    _failure = error;
    _setPhase(SessionPhase.failed);
  }

  void _checkReady(String uid) {
    final s = _db.state;
    if (s is DbReady && s.uid == uid) _onReady(uid);
  }

  void _onDbState(DbOpenState s) {
    final uid = s.uid;
    if (uid == null || uid != _uid || _disposed) return; // other doctor or closed
    switch (s) {
      case DbOpening():
        if (_phase == SessionPhase.migrating) _setPhase(SessionPhase.opening);
      case DbMigrating(:final step, :final progress):
        if (_phase == SessionPhase.opening || _phase == SessionPhase.migrating) {
          _migrationStep = step;
          _migrationProgress = progress;
          _setPhase(SessionPhase.migrating, force: true);
        }
      case DbFailed(:final error):
        if (_phase == SessionPhase.opening || _phase == SessionPhase.migrating) {
          _fail(uid, error);
        }
      case DbReady():
        _onReady(uid);
      case DbClosed():
        break;
    }
  }

  void _onReady(String uid) {
    if (_uid != uid || _readyUid == uid || _approval != ApprovalStatus.approved) return;
    if (_phase != SessionPhase.opening &&
        _phase != SessionPhase.migrating &&
        _phase != SessionPhase.failed) {
      return; // e.g. still checking approval, or waiting for the legacy answer
    }
    _readyUid = uid;
    _failure = null;
    _migrationStep = null;
    _setPhase(SessionPhase.ready);
    final token = _token ??= SyncCancelToken();
    unawaited(_patients.loadAndSync(uid, cancel: token));
    // Profile and medicines load together.
    unawaited(Future.wait([_doctor.load(uid), _medicines.load(uid)]));
  }

  // ------------------------------------------------------------- actions

  /// Retry after [SessionPhase.failed], or re-check approval in
  /// [SessionPhase.pendingApproval] (for example after verifying email).
  void retry() {
    if (_phase == SessionPhase.failed || _phase == SessionPhase.pendingApproval) {
      _schedule(restart: true);
    }
  }

  /// Answers the [SessionPhase.legacyDecision] question.
  Future<void> resolveLegacyMerge(LegacyMergeChoice choice) {
    final prompt = _legacyPrompt;
    if (_phase != SessionPhase.legacyDecision || prompt == null) return Future.value();
    final e = _epoch;
    return _enqueue(() async {
      final uid = prompt.uid;
      if (_stale(e, uid) || _phase != SessionPhase.legacyDecision) return;
      _legacyPrompt = null;
      _setPhase(SessionPhase.opening);
      if (choice == LegacyMergeChoice.merge) {
        await _claimLegacy(uid, e);
      } else {
        await _writeFlag(_legacyDeclinedFlag(uid), 'true');
        if (_stale(e, uid)) return;
        await _open(uid, e);
      }
    });
  }

  /// Only when [canReset]: discards the undecryptable local database and
  /// starts fresh (patients are pulled from Firestore once ready).
  /// [acknowledgedUnsynced] is the count the doctor was shown; throws
  /// ResetNotConfirmedException (nothing deleted) if it is now worse.
  Future<void> resetAndResync({required UnsyncedCount acknowledgedUnsynced}) {
    if (!canReset) throw StateError('Reset is only offered after a key mismatch');
    final e = _epoch;
    final uid = _uid!;
    return _enqueue(() async {
      if (_stale(e, uid)) return;
      await _db.resetAndResync(acknowledgedUnsynced: acknowledgedUnsynced);
      if (_stale(e, uid)) return;
      _checkReady(uid);
    });
  }

  /// Full sign-out: stops sync and clears providers immediately, signs out
  /// of Google and Firebase; the auth event then closes the DB and drops
  /// the Firestore and image caches.
  Future<void> signOut() async {
    _token?.cancel();
    _clearProviders();
    await _platform.signOutGoogle();
    await _platform.signOutFirebase();
  }

  void _onResume() {
    if (_phase == SessionPhase.ready) {
      unawaited(_patients.retryDirty());
    } else if (_phase == SessionPhase.pendingApproval) {
      retry();
    }
  }

  // ------------------------------------------------------------- helpers

  void _setPhase(SessionPhase p, {bool force = false}) {
    if (_disposed || (_phase == p && !force)) return;
    _phase = p;
    notifyListeners();
  }

  Future<String?> _readFlag(String k) async {
    try {
      return await _platform.readFlag(k);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeFlag(String k, String v) async {
    try {
      await _platform.writeFlag(k, v);
    } catch (_) {}
  }

  Future<void> _deleteFlag(String k) async {
    try {
      await _platform.deleteFlag(k);
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _token?.cancel();
    _dbSub?.cancel();
    _authSub?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
