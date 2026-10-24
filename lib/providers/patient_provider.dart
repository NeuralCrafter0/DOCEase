import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../config/dev_mode.dart';
import '../models/patient.dart';
import '../services/attachments.dart';
import '../services/local_photo_store.dart';
import '../services/log_codes.dart';
import '../services/sync_cancel_token.dart';
import 'database_helper.dart';
import 'firestore_helper.dart';
import 'save_refused_exception.dart';
import 'swapped_paths_source.dart';
import '../services/patient_load_status.dart';

export 'save_refused_exception.dart';

/// Patients of the signed-in doctor. The local (encrypted, per-doctor)
/// database is the source of truth; Firestore is the backup.
///
/// SessionController drives the lifecycle: [loadAndSync] once the local DB
/// reports `DbReady(uid)`, [clear] on sign-out or account switch.
///
/// A row stays `dirty` in the local DB until Firestore confirmed that exact
/// version. What is pushed is always the stored row as
/// `dirtyPatientsStrict` returns it (never the in-memory copy), and
/// `markSynced` gets that row's own `updatedAt`. Dirty rows are
/// pushed again on [loadAndSync] (app start), [retryDirty] (app resume),
/// right after any successful write (reconnect), and on a backoff timer
/// after a failed push. Firestore's own offline queue is not relied on:
/// persistence is off (configureFirestoreForEncryptedLocalStore), so it is
/// in memory only.
class PatientProvider with ChangeNotifier {
  /// Defaults to the real SQLCipher database, Firestore, Auth and Storage
  /// (resolved lazily); tests inject fakes.
  PatientProvider({
    LocalDatabase? db,
    FirestoreHelper? firestore,
    FirebaseAuth? auth,
    FirebaseStorage? storage,
    Duration retryBaseDelay = const Duration(seconds: 30),
    Duration retryMaxDelay = const Duration(minutes: 5),
    bool cloudSync = true,
    LocalPhotoStore? photos,
    PatientLoadStatus? loadStatus,
  })  : _db = db ?? DatabaseHelper.instance,
        // The app's provider (no injected DB) publishes for the photo sweep.
        _loadStatus = loadStatus ?? (db == null ? PatientLoadStatus.instance : null),
        _cloudSync = cloudSync,
        _photosOverride = photos,
        _firestoreOverride = firestore,
        _authOverride = auth,
        _storageOverride = storage,
        _retryBase = retryBaseDelay,
        _retryMax = retryMaxDelay,
        _retryDelay = retryBaseDelay;

  final LocalDatabase _db;
  final PatientLoadStatus? _loadStatus;

  /// False in dev mode (kDevMode): Firestore, Auth and Storage are never
  /// touched; push, pull, retry and upload are skipped (rows stay dirty)
  /// and picked photos are kept on the phone in [LocalPhotoStore].
  final bool _cloudSync;

  /// Cloud work is allowed only when [cloudSync] is on AND neither the
  /// session nor the open DB belongs to the dev owner [kLocalOwnerId]:
  /// dev data never reaches Firestore or Storage, whatever the flag says.
  bool get _cloud =>
      _cloudSync && !isLocalOwner(_uid) && !isLocalOwner(_openDbUid);
  final LocalPhotoStore? _photosOverride;
  LocalPhotoStore get _photos => _photosOverride ?? LocalPhotoStore.instance;

  /// Whether this provider syncs with Firebase (false in dev mode).
  bool get cloudSync => _cloudSync;
  final FirestoreHelper? _firestoreOverride;
  final FirebaseAuth? _authOverride;
  final FirebaseStorage? _storageOverride;

  /// The default helper refuses to act once the signed-in user is no longer
  /// this provider's session uid.
  late final FirestoreHelper _firestore =
      _firestoreOverride ?? FirestoreHelper(auth: _authOverride, expectedUid: () => _uid);
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

  List<Patient> _patients = [];
  String _searchQuery = '';
  bool _isSyncing = false;

  /// The doctor whose patients are loaded (null before the first session or
  /// after [clear]). Cloud work is tied to it with [_token].
  String? _uid;
  SyncCancelToken _token = SyncCancelToken();
  Future<void>? _loading;
  /// The load run still in progress ([reload] shares it).
  Future<void>? _activeLoad;
  /// The owner [_patients] was read for (null: nothing loaded).
  String? _listOwner;
  bool _loadFailed = false;
  DbReadFailure? _loadFailure;
  Future<void>? _pushInFlight;

  /// Local files the doctor picked in this session that are not uploaded
  /// yet. Only these are ever uploaded: a local path read back from the
  /// local DB or Firestore is never sent to Storage.
  final Set<String> _pendingUploads = {};

  /// Local path -> Storage path this session's putFile wrote whose swap
  /// into the row has not succeeded yet (it threw). The retry swaps again
  /// with the same object instead of uploading a new one.
  final Map<String, String> _unswapped = {};


  /// Per-patient async lock (security #16 re-review): a queue keyed by
  /// patient id. The upload's swap, its strict refresh and the local
  /// delete hold it, and so do [updatePatient], every visit change
  /// ([_mutateHistory]) and [deletePatient], so no whole-row save can
  /// interleave with a swap. Never taken re-entrantly.
  final Map<String, Future<void>> _patientLocks = {};

  /// Patients written locally in this session whose push Firestore has not
  /// confirmed yet (in-memory dirty check; the DB's dirty flag is the other).
  final Set<String> _unconfirmed = {};

  final Duration _retryBase;
  final Duration _retryMax;
  Duration _retryDelay;
  Timer? _retryTimer;

  List<Patient> get patients {
    // --- SMART SEARCH FIX ---
    final String cleanQuery = _searchQuery.trim().toLowerCase();

    if (cleanQuery.isEmpty) return [..._patients];

    return _patients.where((p) {
      final nameMatch = p.name.toLowerCase().contains(cleanQuery);
      final phoneMatch = p.phone.contains(cleanQuery);
      return nameMatch || phoneMatch;
    }).toList();
  }

  bool get isSyncing => _isSyncing;

  /// True when the last load of this owner's patients failed. The list is
  /// then the one loaded before for the same owner (empty on a first load,
  /// never another owner's), and every patient or visit write or delete is
  /// refused with [SaveRefusedException] until [reload] succeeds: edits to
  /// a stale list could overwrite newer rows. Sync, photo cleanup and the
  /// startup sweep do not run either.
  bool get loadFailed => _loadFailed;

  /// The reason enum value of the failed load ([DbReadFailure]), for
  /// diagnostics only; null when [loadFailed] is false.
  Object? get loadFailure => _loadFailure;

  /// The uid whose data is loaded.
  String? get sessionUid => _uid;

  bool isPhoneRegistered(String phone) => _patients.any((p) => p.phone.trim() == phone.trim());

  bool _live(String? uid, SyncCancelToken token) => !token.isCancelled && _uid == uid;

  String? get _signedInUid {
    if (!_cloud) return _uid;
    try {
      return _auth.currentUser?.uid;
    } catch (_) {
      return null; // Firebase not initialised (tests)
    }
  }

  String? get _bucket {
    if (!_cloud) return null;
    try {
      return _storage.bucket;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------- loading

  /// Loads [uid]'s local patients, pushes unconfirmed local changes, then
  /// pulls from Firestore. Does nothing unless the local DB is `DbReady`
  /// for [uid]. Repeated calls for the same session share one run; results
  /// are dropped once [cancel] is cancelled or [clear] runs.
  Future<void> loadAndSync(String uid, {SyncCancelToken? cancel}) {
    final running = _loading;
    if (_uid == uid && running != null && !_token.isCancelled &&
        (cancel == null || identical(cancel, _token))) {
      return running;
    }
    if (_uid != uid) {
      _token.cancel();
      // Owner change: the old owner's list and load state go, even while
      // loadFailed is true (security: never one doctor's patients for the next).
      final had = _patients.isNotEmpty || _loadFailed || _listOwner != null;
      _resetLoadState();
      if (had) notifyListeners();
    }
    final token = cancel ?? (_token.isCancelled || _uid != uid ? SyncCancelToken() : _token);
    _uid = uid;
    _token = token;
    // Not ready: nothing to share, so the next call (on DbReady) runs.
    if (!_dbReadyFor(uid)) return Future.value();
    final run = _loadAndSync(uid, token);
    _loading = run;
    _activeLoad = run;
    void done() {
      if (identical(_activeLoad, run)) _activeLoad = null;
    }
    unawaited(run.then((_) => done(), onError: (Object _) => done()));
    return run;
  }

  /// Reads the current owner's patients again (e.g. after [loadFailed]).
  /// Success replaces the list and clears [loadFailed]; a failure keeps the
  /// list. Shares a load that is still running; does nothing without a
  /// session or while the owner's database is not open.
  Future<void> reload() {
    final uid = _uid;
    if (uid == null || _token.isCancelled) return Future.value();
    final active = _activeLoad;
    if (active != null) return active;
    _loading = null;
    return loadAndSync(uid);
  }

  void _resetLoadState() {
    _patients = [];
    _listOwner = null;
    _loadFailed = false;
    _loadFailure = null;
    _activeLoad = null;
    _loadStatus?.cleared();
  }

  /// A failed load keeps the list only if it is this owner's.
  void _markLoadFailed(String uid, Object error) {
    if (_listOwner != uid) {
      _patients = [];
      _listOwner = null;
    }
    _loadFailed = true;
    _loadFailure = error is DbReadException ? error.reason : DbReadFailure.readFailed;
    _loadStatus?.failed(uid);
    notifyListeners();
  }

  /// Every patient of [uid], or throws [DbReadException] (never a partial or
  /// empty list on a read error): #10's [LocalDatabase.fetchPatientsStrict].
  /// Note it also throws `unreadableRow` when any row would come back
  /// flagged, so one unreadable row makes the whole load fail (loadFailed).
  Future<List<Patient>> _readPatients(String uid) async {
    // The strict read checks that *a* database is open; this checks it is uid's.
    if (_openDbUid != uid) throw const DbReadException(DbReadFailure.notOpen);
    return _db.fetchPatientsStrict();
  }

  /// Security (#16 loadFailed contract): the refusal for [operation] while
  /// the last load failed, else null.
  SaveRefusedException? _loadRefusal(PatientSaveOperation operation) => _loadFailed
      ? SaveRefusedException(operation, DbReadException(_loadFailure ?? DbReadFailure.readFailed))
      : null;

  /// Kept for existing callers (HomeScreen). Loading is started by
  /// SessionController when the DB is ready; this only waits for that run
  /// and never opens or reads a database by itself.
  Future<void> fetchAndSetPatients() async {
    final uid = _signedInUid;
    if (uid == null || uid != _uid) return;
    await _loading;
  }

  /// The uid of the open local database.
  /// TODO(db-merge): use the DB engineer's open-DB uid accessor once it
  /// lands; until then the uid of the `DbReady` state.
  String? get _openDbUid {
    final s = _db.state;
    return s is DbReady ? s.uid : null;
  }

  /// Whether [uid] is the signed-in user. Fails closed when signed out, and
  /// when Firebase is unavailable. The one exception is a unit test that
  /// injected a FirestoreHelper but no auth: that injected helper is the
  /// only thing that can be reached, so the open-DB uid check decides. The
  /// app never injects a helper (PatientProvider()), so it always fails
  /// closed. The dev owner is refused separately by [_cloud].
  bool _isSignedIn(String uid) {
    if (!_cloud) return true; // dev mode: the open-DB uid check decides
    try {
      return _auth.currentUser?.uid == uid;
    } catch (_) {
      return _firestoreOverride != null && _authOverride == null;
    }
  }

  /// Sync, merge and retry run only while the open DB belongs to [uid] AND
  /// [uid] is the signed-in user (not merely "some DB is open").
  bool _dbReadyFor(String uid) => _openDbUid == uid && _isSignedIn(uid);

  Future<void> _loadAndSync(String uid, SyncCancelToken token) async {
    if (!_dbReadyFor(uid)) {
      if (_live(uid, token)) _loading = null;
      return;
    }
    final List<Patient> local;
    try {
      local = await _readPatients(uid);
    } catch (e) {
      debugPrint('Local load failed: ${errorCode(e)}');
      if (_live(uid, token)) {
        _loading = null;
        _markLoadFailed(uid, e);
      }
      return;
    }
    if (!_live(uid, token)) return;
    _patients = local;
    _listOwner = uid;
    _loadFailed = false;
    _loadFailure = null;
    _loadStatus?.loaded(uid);
    if (!_cloud) {
      notifyListeners(); // dev mode: on-phone data only, no push or pull
      return;
    }
    _isSyncing = true;
    notifyListeners();
    try {
      await _pushDirty(uid, token);
      if (!_live(uid, token)) return;
      await _pullFromCloud(uid, token);
    } catch (e) {
      debugPrint('Sync Error: ${errorCode(e)}');
    } finally {
      if (_live(uid, token)) {
        _isSyncing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _pullFromCloud(String uid, SyncCancelToken token) async {
    // Never read or merge cloud data unless the local DB is open for uid,
    // nor into a stale list (loadFailed).
    if (!_dbReadyFor(uid) || _loadFailed) return;
    final cloudPatients = await _firestore.fetchAllPatients();
    if (!_live(uid, token) || cloudPatients.isEmpty) return;
    // Never overwrite a local change Firestore has not confirmed yet. If
    // the dirty rows can't be read, don't merge at all.
    final dirtyIds = await _dirtyIds();
    if (dirtyIds == null || !_live(uid, token)) return;
    final mergedMap = {for (final p in _patients) p.id: p};
    var hasChanges = false;
    var skippedDirty = false;
    for (final cp in cloudPatients) {
      // A doc that failed to parse is skipped: never stored or re-synced.
      // Likewise never overwrite a local row that failed to parse.
      if (cp.hasParseErrors || (mergedMap[cp.id]?.hasParseErrors ?? false)) {
        debugPrint('Sync: skipping unparsed patient ${cp.id}');
        continue;
      }
      // Dirty rows and tombstones are refused atomically by the DB's
      // conditional write (applyCloudPatient); the in-memory checks below
      // then keep the local copy.
      if (dirtyIds.contains(cp.id)) skippedDirty = true;
      final local = mergedMap[cp.id];
      // Unchanged heuristic (known issue, follow-up): cloud wins only for
      // new patients or when it has more visits.
      if (local == null || cp.history.length > local.history.length) {
        if (!_live(uid, token) || !_dbReadyFor(uid)) return;
        final applied = await _applyCloud(cp);
        if (!_live(uid, token)) return;
        if (!applied || _unconfirmed.contains(cp.id)) {
          // Edited locally while the pull ran: not an error, keep local.
          skippedDirty = true;
          continue;
        }
        // Don't replace an in-memory edit made while the write ran.
        if (!identical(_byId(cp.id), local)) {
          skippedDirty = true;
          continue;
        }
        mergedMap[cp.id] = cp;
        hasChanges = true;
      }
    }
    if (hasChanges && _live(uid, token)) {
      final current = {for (final p in _patients) p.id: p};
      _patients = [
        for (final p in current.values) mergedMap[p.id] ?? p,
        for (final p in mergedMap.values) if (!current.containsKey(p.id)) p,
      ];
      notifyListeners();
    }
    if (skippedDirty) _scheduleRetry(uid, token);
  }

  /// Stores a cloud copy as synced only if the local row is missing or
  /// clean. False = skipped because the row is dirty (or nothing written).
  Future<bool> _applyCloud(Patient cp) => _db.applyCloudPatient(cp);

  /// Ids of dirty local rows; null if they can't be read (strict read: an
  /// error is never mistaken for "no dirty rows").
  Future<Set<String>?> _dirtyIds() async {
    try {
      return (await _db.dirtyPatientsStrict()).map((p) => p.id).toSet();
    } catch (e) {
      debugPrint('Reading unsynced rows failed: ${errorCode(e)}');
      return null;
    }
  }

  // ------------------------------------------------------------ retrying

  /// Pushes every dirty local row again (SessionController calls this on
  /// app resume). Safe to call any time; concurrent calls share one run.
  Future<void> retryDirty() async {
    final uid = _uid;
    if (!_cloud || uid == null || _token.isCancelled || !_dbReadyFor(uid)) return;
    await _pushDirty(uid, _token);
  }

  Future<void> _pushDirty(String uid, SyncCancelToken token) {
    if (_loadFailed) return Future.value(); // reload() syncs once the list is good
    final inFlight = _pushInFlight;
    if (inFlight != null) return inFlight;
    final run = _pushDirtyNow(uid, token);
    _pushInFlight = run;
    run.whenComplete(() {
      if (identical(_pushInFlight, run)) _pushInFlight = null;
    });
    return run;
  }

  Future<void> _pushDirtyNow(String uid, SyncCancelToken token) async {
    final List<Patient> dirty;
    try {
      // Strict: a failed read throws instead of returning [] (which would
      // push nothing and then reset the retry as if all were synced).
      dirty = await _db.dirtyPatientsStrict(); // oldest edit first
    } catch (e) {
      debugPrint('Reading unsynced rows failed: ${errorCode(e)}');
      _scheduleRetry(uid, token); // keep the retry pending
      return;
    }
    for (final p in dirty) {
      if (!_live(uid, token)) return;
      final ok = await _syncOne(uid, token, p.id, stored: p); // the stored row, never memory
      if (!ok) {
        _scheduleRetry(uid, token); // probably offline
        return;
      }
    }
    if (!await _pushPendingDeletes(uid, token)) {
      if (_live(uid, token)) _scheduleRetry(uid, token);
      return;
    }
    if (!_live(uid, token)) return;
    if (_pendingUploads.isEmpty) {
      _resetRetry();
    } else {
      _scheduleRetry(uid, token); // an upload failed: try it again later
    }
  }

  bool _hasPendingUploads(Patient p) =>
      _pendingUploads.isNotEmpty &&
      p.history.any((r) => r.attachmentPaths.any(_pendingUploads.contains));

  /// Retries cloud deletes that Firestore has not confirmed. A tombstone is
  /// cleared only after the delete is confirmed. False = retry later.
  Future<bool> _pushPendingDeletes(String uid, SyncCancelToken token) async {
    final List<String> ids;
    try {
      // Strict: [] on a read error would report success and stop retrying.
      ids = await _db.pendingDeletesStrict();
    } catch (e) {
      debugPrint('Reading pending deletes failed: ${errorCode(e)}');
      return false;
    }
    for (final id in ids) {
      if (!_live(uid, token) || !_dbReadyFor(uid)) return false;
      if (!await _confirmCloudDelete(id)) return false;
    }
    return true;
  }

  Future<bool> _confirmCloudDelete(String id) async {
    if (!await _firestore.deletePatient(id)) return false;
    try {
      await _db.clearPendingDelete(id);
    } catch (e) {
      // Tombstone stays; the delete is retried (idempotent).
      debugPrint('clearPendingDelete failed for $id: ${errorCode(e)}');
    }
    return true;
  }

  void _scheduleRetry(String? uid, SyncCancelToken token) {
    if (uid == null || !_live(uid, token) || (_retryTimer?.isActive ?? false)) return;
    final delay = _retryDelay;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (_live(uid, token)) unawaited(_pushDirty(uid, token));
    });
    _retryDelay = Duration(
        milliseconds: math.min(delay.inMilliseconds * 2, _retryMax.inMilliseconds));
  }

  void _resetRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryDelay = _retryBase;
  }

  // ------------------------------------------------------- write helpers

  /// Uploads [patientId]'s pending files, writes the patient to Firestore,
  /// and marks the local row synced if it is still the version that was
  /// sent. Returns false when the push failed (retry later).
  ///
  /// What is pushed is always the STORED dirty row ([stored], as
  /// [LocalDatabase.dirtyPatientsStrict] returned it, or read strictly
  /// here), never the provider's in-memory copy: since #10's
  /// attachment_swaps a local save may store a Storage path S where memory
  /// still holds the local path L, and pushing memory would send L to the
  /// cloud while markSynced marks the row (holding S) synced. markSynced
  /// gets that pushed row's own `updatedAt` (compare-and-set: a newer
  /// edit meanwhile stays dirty and is pushed by the next round).
  ///
  /// [savedVersion] (the version the triggering save returned) is used
  /// only if the stored row carries no `updatedAt`. The real DB always
  /// sets it; #10's shared FakeLocalDatabase returns the caller's copy.
  /// Safe either way: the row was read after that save, so markSynced's
  /// compare-and-set succeeds only while the stored row is still that
  /// version, i.e. the row that was pushed.
  Future<bool> _syncOne(String? uid, SyncCancelToken token, String patientId,
      {Patient? stored, String? savedVersion}) async {
    if (!_live(uid, token)) return false;
    // Hard guard: the dev owner's data is never pushed.
    if (!_cloud || isLocalOwner(uid ?? _openDbUid)) return false;
    if (uid != null && !_dbReadyFor(uid)) return false; // other doctor's DB or user
    Patient? current = stored;
    if (current == null) {
      final List<Patient> dirty;
      try {
        // TODO(db-strict-read): a single-row strict read on #10 would do.
        dirty = await _db.dirtyPatientsStrict();
      } catch (e) {
        debugPrint('Reading the saved row failed: ${errorCode(e)}');
        return false; // stays dirty; retried
      }
      if (!_live(uid, token)) return false;
      current = dirty.where((p) => p.id == patientId).firstOrNull;
    }
    if (current == null) return true; // synced or deleted meanwhile
    if (current.hasParseErrors) return true; // read-only; never synced
    var sentVersion = current.updatedAt ?? savedVersion;

    // The owner whose database the upload starts on (security #16): the
    // swap is checked against it, and nothing is swapped or deleted if a
    // different database is open by then (e.g. a sign-out mid-upload).
    final uploadOwner = _openDbUid;
    final replacements = await _uploadPending(uid, token, current);
    if (!_live(uid, token)) return false;
    if (replacements.isNotEmpty) {
      if (uploadOwner == null || _openDbUid != uploadOwner) return false;
      // Security #16 re-review: the DB swaps each path in the stored row
      // (one transaction); the stale snapshot is never written back.
      final swap = await _swapUploaded(uploadOwner, uid, token, patientId, replacements);
      if (!_live(uid, token) || _openDbUid != uploadOwner) return false;
      if (swap.gone.isNotEmpty) await _deleteOwnUploads(uploadOwner, uid, token, patientId, swap.gone);
      if (swap.swapped.isNotEmpty) {
        // The swap changed the row's version: push the row as the strict
        // refresh read it, with its own version, so markSynced's
        // compare-and-set matches. No refresh: stays dirty, retried.
        final stored = swap.stored;
        if (stored == null) return false;
        current = stored;
        sentVersion = stored.updatedAt;
      }
      notifyListeners();
    }

    final ok = await _firestore.syncPatient(_cloudSafe(current, uid ?? _signedInUid));
    if (!ok) return false;
    // A file still waiting to upload keeps the row dirty, so the retry
    // uploads it and pushes its Storage path.
    if (sentVersion != null && _live(uid, token) && !_hasPendingUploads(current)) {
      // Compare-and-set: false means a newer edit happened meanwhile; it
      // stays dirty and is pushed by its own write or the next retry.
      try {
        if (await _db.markSynced(patientId, sentVersion)) _unconfirmed.remove(patientId);
      } catch (e) {
        debugPrint('markSynced failed for $patientId: ${errorCode(e)}');
      }
    }
    return true;
  }

  /// After a local write: push now. On failure schedule a retry; on success
  /// flush anything else that was waiting (connectivity is back).
  Future<void> _afterLocalWrite(String patientId, String? savedVersion) async {
    if (!_cloud) return; // dev mode: the row stays dirty; nothing is pushed
    final uid = _uid;
    final token = _token;
    _unconfirmed.add(patientId);
    final ok = await _syncOne(uid, token, patientId, savedVersion: savedVersion);
    if (!_live(uid, token)) return;
    final p = _byId(patientId);
    if (!ok || (p != null && _hasPendingUploads(p))) {
      _scheduleRetry(uid, token);
    } else if (_retryTimer != null && uid != null) {
      _resetRetry();
      unawaited(_pushDirty(uid, token));
    }
  }

  Future<Map<String, String>> _uploadPending(String? sessionUid, SyncCancelToken token, Patient p) async {
    final out = <String, String>{};
    if (_pendingUploads.isEmpty) return out;
    final uid = sessionUid ?? _signedInUid;
    // Hard guard: nothing of the dev owner is uploaded to Storage.
    if (uid == null || !_cloud || isLocalOwner(uid)) return out;
    final folder = LocalPhotoStore.ownerFolderName(_openDbUid ?? uid);
    var notSwappable = 0;
    for (final r in p.history) {
      for (final path in r.attachmentPaths) {
        if (!_pendingUploads.contains(path) || out.containsKey(path)) continue;
        if (!_live(sessionUid, token) || _signedInUid != uid) return out;
        // #10's swap only takes a visit photo in the owner's attachments/
        // folder (PR #8 writes picks there). Anything else would be
        // uploaded but never swapped: it stays local (never deleted, never
        // sent to Firestore by _cloudSafe) and is no longer pending.
        final key = AttachmentRefs.attachmentKey(path, ownerFolderName: folder);
        if (key == null || !key.startsWith('attachments/')) {
          _pendingUploads.remove(path);
          notSwappable++;
          continue;
        }
        final uploaded = _unswapped[path];
        if (uploaded != null) {
          out[path] = uploaded; // already uploaded; only its swap is retried
          continue;
        }
        final type = UploadImageType.forPath(path);
        if (type == null) continue; // validated on save; defensive
        final storagePath =
            '${AttachmentPolicy.attachmentFolder(uid, p.id)}/${const Uuid().v4()}.${type.fileExtension}';
        try {
          await _storage
              .ref(storagePath)
              .putFile(File(path), SettableMetadata(contentType: type.contentType));
          out[path] = storagePath;
          _unswapped[path] = storagePath; // until its swap succeeds or the path is gone
        } catch (e) {
          debugPrint('Attachment upload failed for patient ${p.id}: ${errorCode(e)}');
          return out; // keeps the local path; retried with the row
        }
      }
    }
    if (notSwappable > 0) debugPrint('Upload: $notSwappable photo(s) outside the owner folder kept local');
    return out;
  }

  /// Swaps each uploaded local path for its Storage path in [patientId]'s
  /// stored row through #10's one-transaction [LocalDatabase.swapAttachmentPath]
  /// (never by writing a row snapshot back). Everything here runs under
  /// [patientId]'s lock ([_underPatientLock]), so no whole-row save
  /// (updatePatient, a visit change, a delete) can interleave:
  ///
  /// 1. swap each path; true = swapped (row marked dirty), false = the
  ///    photo is gone (no row, tombstoned, no entry): nothing written;
  /// 2. after any true, refresh that patient in memory from a strict read
  ///    ([_refreshFromDb]), so no later save starts from a pre-swap copy;
  /// 3. delete a swapped local copy only if a fresh strict
  ///    [LocalDatabase.referencedAttachmentKeys] scan no longer references
  ///    its key ([_deleteUnreferencedPhotos]); the swap result alone is
  ///    never enough. Referenced (a stale write got through) or a scan
  ///    or refresh that fails: the file is kept for the sweep or the next
  ///    upload.
  ///
  /// A swap that throws (ArgumentError, DbReadException notOpen /
  /// unreadableRow / readFailed, UnsyncedCounterException) changes and
  /// deletes nothing: the path stays pending and the next retry swaps the
  /// same object again (no new upload).
  Future<({Map<String, String> swapped, List<String> gone, Patient? stored})> _swapUploaded(
      String owner, String? uid, SyncCancelToken token, String patientId, Map<String, String> uploaded) {
    return _underPatientLock(patientId, () async {
      final swapped = <String, String>{};
      final gone = <String>[];
      var failed = 0;
      for (final MapEntry(key: local, value: storagePath) in uploaded.entries) {
        if (!_live(uid, token) || _openDbUid != owner) break; // owner changed: no swap
        try {
          if (await _swapPath(owner, patientId, local, storagePath)) {
            swapped[local] = storagePath;
          } else {
            gone.add(storagePath); // photo or visit removed mid-upload
          }
          _unswapped.remove(local);
          _pendingUploads.remove(local);
        } catch (e) {
          failed++;
          if (failed == 1) debugPrint('Upload: swap failed (${errorCode(e)}); retried later');
        }
      }
      Patient? stored;
      if (swapped.isNotEmpty && _live(uid, token) && _openDbUid == owner) {
        stored = await _refreshFromDb(owner, uid, token, patientId);
        if (stored == null) {
          // The DB holds the Storage paths; memory follows without a
          // re-read, and the local copies stay (no delete without a scan
          // after a confirmed refresh).
          final latest = _byId(patientId);
          if (latest != null && _live(uid, token)) {
            _replaceInMemory(_withAttachmentsReplaced(latest, swapped));
          }
        } else {
          await _deleteUnreferencedPhotos(owner, swapped.keys, after: 'an upload');
        }
      }
      return (swapped: swapped, gone: gone, stored: stored);
    });
  }

  /// F8-R1: only an object in [owner]'s own Storage folder for [patientId]
  /// is ever swapped in (#10 checks this too and throws ArgumentError);
  /// anything else throws, so nothing is deleted.
  Future<bool> _swapPath(String owner, String patientId, String local, String storagePath) {
    final folder = '${AttachmentPolicy.attachmentFolder(owner, patientId)}/';
    if (!storagePath.startsWith(folder) || storagePath.contains('..')) {
      throw ArgumentError('upload outside the owner folder');
    }
    return _db.swapAttachmentPath(
        expectedOwner: owner, patientId: patientId, localPath: local, storagePath: storagePath);
  }

  /// Strict re-read of [patientId] after a swap: replaces it in memory and
  /// returns it. Null (memory unchanged, nothing deleted, push retried) if
  /// the read throws, the row is gone or unreadable, or the session or
  /// owner changed meanwhile. Logs only the error code.
  ///
  /// TODO(db-strict-read): a single-row `fetchPatientStrict(id)` on #10
  /// would avoid reading every row here.
  Future<Patient?> _refreshFromDb(String owner, String? uid, SyncCancelToken token, String patientId) async {
    final List<Patient> rows;
    try {
      rows = await _db.fetchPatientsStrict();
    } catch (e) {
      debugPrint('Upload: refresh after swap failed (${errorCode(e)})');
      return null;
    }
    if (!_live(uid, token) || _openDbUid != owner) return null;
    final row = rows.where((p) => p.id == patientId).firstOrNull;
    if (row == null || row.hasParseErrors) return null;
    if (_byId(patientId) == null) return null; // forgotten meanwhile
    _replaceInMemory(row);
    notifyListeners();
    return row;
  }

  /// After a successful local save: replaces [patientId] in memory with
  /// the row as stored (strict read), so the UI shows what the DB kept
  /// (e.g. #10's attachment_swaps storing S over a stale L) and the next
  /// edit starts from it. Returns it, or null (memory left as the caller's
  /// copy; the push still sends the stored row) when the read fails, the
  /// row is gone or unreadable, or the session changed. Logs only the code.
  Future<Patient?> _refreshSaved(String patientId) async {
    final uid = _uid;
    final token = _token;
    final List<Patient> rows;
    try {
      rows = await _db.fetchPatientsStrict();
    } catch (e) {
      debugPrint('Refresh after save failed (${errorCode(e)})');
      return null;
    }
    if (!_live(uid, token)) return null;
    final row = rows.where((p) => p.id == patientId).firstOrNull;
    if (row == null || row.hasParseErrors || _byId(patientId) == null) return null;
    _replaceInMemory(row);
    notifyListeners();
    return row;
  }

  /// #10's attachment_swaps for [patientId] (local key -> Storage path),
  /// strict: throws DbReadException when it cannot read.
  // Interim until #10 posts LocalDatabase.swappedPathsFor: then call it
  // directly and delete swapped_paths_source.dart.
  Future<Map<String, String>> _swappedPathsFor(String owner, String patientId) {
    final db = _db;
    if (db is SwappedPathsSource) {
      return (db as SwappedPathsSource)
          .swappedPathsFor(expectedOwner: owner, patientId: patientId);
    }
    return Future.value(const <String, String>{});
  }

  /// A form opened before an upload's swap still names the local path L:
  /// each entry whose key #10 swapped is written as its Storage path S. An
  /// entry that maps onto a path already in the list is dropped (no
  /// duplicate reference); unmapped entries are left as they are.
  static VisitRecord _mapSwappedRecord(
      VisitRecord r, String owner, Map<String, String> swapped) {
    if (swapped.isEmpty) return r;
    final folder = LocalPhotoStore.ownerFolderName(owner);
    final mapped = [
      for (final e in r.attachmentPaths)
        (switch (AttachmentRefs.attachmentKey(e, ownerFolderName: folder)) {
          final String key when key.startsWith('attachments/') => swapped[key],
          _ => null,
        }) ?? e,
    ];
    // Drop an entry only when it duplicates a Storage path that came from
    // a mapping ([L, S] or [S, L] -> [S]); other entries are untouched.
    final fromMapping = {
      for (var k = 0; k < mapped.length; k++)
        if (mapped[k] != r.attachmentPaths[k]) mapped[k],
    };
    final out = <String>[];
    for (final e in mapped) {
      if (fromMapping.contains(e) && out.contains(e)) continue;
      out.add(e);
    }
    return _copyRecord(r, out);
  }

  /// Runs [body] after every earlier holder of [patientId]'s lock finished
  /// (success or error). See [_patientLocks].
  Future<T> _underPatientLock<T>(String patientId, Future<T> Function() body) {
    final previous = _patientLocks[patientId] ?? Future<void>.value();
    final run = previous.then((_) => body());
    final Future<void> tail = run.then((_) {}, onError: (_) {});
    _patientLocks[patientId] = tail;
    unawaited(tail.then((_) {
      if (identical(_patientLocks[patientId], tail)) _patientLocks.remove(patientId);
    }));
    return run;
  }

  /// Security #16: after a swap returned false, the object this upload just
  /// wrote is unused. Each is deleted only at that exact path (the one its
  /// putFile wrote, in [owner]'s folder for [patientId]; never by prefix or
  /// listing), only while [owner]'s DB is still open, and only if a strict
  /// scan ([LocalDatabase.referencedAttachmentPaths]) shows no row
  /// references it. If the scan throws, nothing is deleted. Counts only.
  Future<void> _deleteOwnUploads(String owner, String? uid, SyncCancelToken token,
      String patientId, List<String> created) async {
    if (!_live(uid, token) || _openDbUid != owner) return;
    final folder = '${AttachmentPolicy.attachmentFolder(owner, patientId)}/';
    final Set<String> referenced;
    try {
      referenced = await _db.referencedAttachmentPaths();
    } on AttachmentScanIncomplete catch (e) {
      final reason = e.reason.name; // an AttachmentScanFailure enum name, never a path
      debugPrint('Upload: unused upload kept ($reason)');
      return;
    } catch (e) {
      debugPrint('Upload: unused upload kept (${errorCode(e)})');
      return;
    }
    if (!_live(uid, token) || _openDbUid != owner) return;
    var removed = 0;
    var failed = 0;
    for (final path in created) {
      if (!path.startsWith(folder) || referenced.contains(path)) continue;
      try {
        await _storage.ref(path).delete();
        removed++;
      } catch (_) {
        failed++;
      }
    }
    if (removed > 0) debugPrint('Upload: removed $removed unused upload(s)');
    if (failed > 0) debugPrint('Upload: $failed unused upload(s) not removed');
  }

  /// The patient as it may be written to Firestore: attachment entries that
  /// are not Storage paths (or legacy download URLs) in this doctor's and
  /// patient's folder are left out, so local paths, foreign URLs and other
  /// doctors' paths never reach the cloud.
  Patient _cloudSafe(Patient p, String? uid) {
    final owner = uid ?? '';
    final bucket = _bucket;
    return Patient(
      id: p.id, name: p.name, age: p.age, gender: p.gender, phone: p.phone,
      relation: p.relation, updatedAt: p.updatedAt,
      history: [
        for (final r in p.history)
          _copyRecord(r, r.attachmentPaths
              .where((e) => AttachmentPolicy.isCloudSafe(e, owner, p.id, bucket: bucket))
              .toList()),
      ],
    );
  }

  static VisitRecord _copyRecord(VisitRecord r, List<String> attachments) => VisitRecord(
        id: r.id, date: r.date, visitType: r.visitType,
        symptoms: r.symptoms, diagnosis: r.diagnosis, prescription: r.prescription,
        notes: r.notes, bp: r.bp, temp: r.temp, pulse: r.pulse, weight: r.weight, sugar: r.sugar,
        attachmentPaths: attachments,
      );

  static Patient _withAttachmentsReplaced(Patient p, Map<String, String> repl) => Patient(
        id: p.id, name: p.name, age: p.age, gender: p.gender, phone: p.phone,
        relation: p.relation, updatedAt: p.updatedAt,
        history: [
          for (final r in p.history)
            _copyRecord(r, [for (final e in r.attachmentPaths) repl[e] ?? e]),
        ],
      );

  Patient? _byId(String id) {
    for (final p in _patients) {
      if (p.id == id) return p;
    }
    return null;
  }

  void _replaceInMemory(Patient p) {
    final i = _patients.indexWhere((x) => x.id == p.id);
    if (i != -1) _patients[i] = p;
  }

  /// Patients with unreadable records are read-only: saving them would
  /// overwrite the stored data with placeholders.
  void _ensureWritable(Patient patient) {
    if (patient.hasParseErrors) throw UnreadablePatientException(patient.id);
  }

  /// Checks every newly added attachment before anything changes and
  /// returns the local files to upload. Throws
  /// [UnsupportedAttachmentException] naming the first bad file; then
  /// nothing is uploaded and nothing is saved.
  Future<List<String>> _validateNewAttachments(String patientId, Iterable<String> entries) async {
    final uid = _uid ?? _signedInUid ?? '';
    final bucket = _bucket;
    final toUpload = <String>[];
    for (final e in entries) {
      switch (AttachmentPolicy.classify(e, uid, patientId, bucket: bucket)) {
        case AttachmentEntryKind.storagePath:
        case AttachmentEntryKind.legacyDownloadUrl:
          break;
        case AttachmentEntryKind.localFile:
          await AttachmentPolicy.validateLocalImage(e, maxBytes: AttachmentPolicy.maxAttachmentBytes);
          toUpload.add(e);
        case AttachmentEntryKind.invalid:
          throw UnsupportedAttachmentException(
              AttachmentPolicy.displayName(e), AttachmentRejection.notAFile);
      }
    }
    return toUpload;
  }

  // ------------------------------------------------------------- display

  /// How the UI should treat an attachment entry of [patientId].
  AttachmentEntryKind attachmentKind(String entry, String patientId) =>
      AttachmentPolicy.classify(entry, _uid ?? _signedInUid ?? '', patientId, bucket: _bucket);

  /// Whether [path] is a local file picked in this session (the only local
  /// files the UI should render).
  /// In dev mode also every photo kept in the app's photo folders.
  bool isPickedThisSession(String path) =>
      _pendingUploads.contains(path) ||
      (!_cloud && _photoOwner != null && _photos.isAppPhoto(path, owner: _photoOwner));

  /// Owner of the photo folders in use: the session (or open DB) owner.
  String? get _photoOwner => _uid ?? _openDbUid;

  /// Downloads a `clinical_attachments/{uid}/...` object through the
  /// Storage SDK (so the rules apply). Null for other paths or on error.
  Future<Uint8List?> loadAttachmentBytes(String storagePath) async {
    if (!_cloud) return null; // dev mode: no Storage
    final uid = _uid;
    if (uid == null || !storagePath.startsWith('clinical_attachments/$uid/')) return null;
    try {
      return await _storage.ref(storagePath).getData(AttachmentPolicy.maxAttachmentBytes);
    } catch (e) {
      debugPrint('Attachment download failed: ${errorCode(e)}');
      return null;
    }
  }

  // ------------------------------------------------------------ mutations

  void setSearchQuery(String query) { _searchQuery = query; notifyListeners(); }

  /// Throws [SaveRefusedException] when the save is refused (for example
  /// the counter can't be kept, `UnsyncedCounterException`, or the patient
  /// is unreadable). The patient is then no longer in the list and nothing
  /// is synced.
  Future<void> addPatient(Patient patient) async {
    final refused = _loadRefusal(PatientSaveOperation.add);
    if (refused != null) throw refused; // no duplicates after a failed load
    try {
      _ensureWritable(patient);
    } catch (e, st) {
      Error.throwWithStackTrace(SaveRefusedException(PatientSaveOperation.add, e), st);
    }
    _patients.add(patient);
    notifyListeners();
    final String? version;
    try {
      version = await _db.insertPatient(patient);
    } catch (e, st) {
      // Save refused: don't show it as saved, don't sync.
      _patients.removeWhere((p) => identical(p, patient));
      notifyListeners();
      Error.throwWithStackTrace(SaveRefusedException(PatientSaveOperation.add, e), st);
    }
    await _refreshSaved(patient.id);
    unawaited(_afterLocalWrite(patient.id, version));
  }

  /// The patient-details save (security F16-R4). Applies ONLY [patient]'s
  /// detail fields (name, age, gender, phone, relation) to the patient's
  /// CURRENT stored row; [patient]'s history and attachments are ignored.
  /// A details screen keeps the copy it was opened with, so its history can
  /// be stale (an upload swapped and deleted a local photo meanwhile, or a
  /// visit was saved after it opened); writing it back would point a visit
  /// at a deleted file, orphan the Storage object and drop the newer visit.
  /// History changes only go through [addRecord], [updateRecord] and
  /// [deleteRecord]. Same as [updatePatientDetails].
  Future<void> updatePatient(Patient patient) => updatePatientDetails(
        patient.id,
        name: patient.name,
        age: patient.age,
        gender: patient.gender,
        phone: patient.phone,
        relation: patient.relation,
      );

  /// Explicit details-only save: sets the given fields (null = unchanged)
  /// on [patientId]'s current stored row and leaves its history exactly as
  /// stored. Inside [patientId]'s lock ([_underPatientLock], shared with
  /// the upload swap and every visit change) the row is read strictly
  /// ([LocalDatabase.fetchPatientsStrict]), the fields are applied and the
  /// whole row is written back, so nothing can change the history in
  /// between. Memory then shows the stored history.
  ///
  /// Does nothing if no patient with this id is loaded. Throws
  /// [SaveRefusedException] (nothing written, memory unchanged, nothing
  /// synced) when the read fails, the stored row is gone or unreadable,
  /// or the write is refused.
  Future<void> updatePatientDetails(
    String patientId, {
    String? name,
    String? age,
    String? gender,
    String? phone,
    String? relation,
  }) async {
    final refused = _loadRefusal(PatientSaveOperation.update);
    if (refused != null) throw refused;
    await _underPatientLock(patientId, () async {
      final refusedNow = _loadRefusal(PatientSaveOperation.update);
      if (refusedNow != null) throw refusedNow;
      final shown = _byId(patientId);
      if (shown == null) return;
      Never refuse(Object e, StackTrace st) =>
          Error.throwWithStackTrace(SaveRefusedException(PatientSaveOperation.update, e), st);
      final Patient stored;
      try {
        _ensureWritable(shown);
        final row = (await _db.fetchPatientsStrict()).where((p) => p.id == patientId).firstOrNull;
        if (row == null) throw StoredPatientMissingException(patientId);
        _ensureWritable(row);
        stored = row;
      } catch (e, st) {
        refuse(e, st);
      }
      final updated = Patient(
        id: stored.id,
        name: name ?? stored.name,
        age: age ?? stored.age,
        gender: gender ?? stored.gender,
        phone: phone ?? stored.phone,
        relation: relation ?? stored.relation,
        history: stored.history, // never the caller's
        updatedAt: stored.updatedAt,
      );
      final String? version;
      try {
        version = await _db.insertPatient(updated);
      } catch (e, st) {
        refuse(e, st);
      }
      if (_byId(patientId) != null) {
        _replaceInMemory(updated);
        notifyListeners();
      }
      await _refreshSaved(patientId); // shows the row as stored (S, not L)
      unawaited(_afterLocalWrite(patientId, version));
    });
  }

  /// Deletes a patient. With the tombstone API the row is removed and a
  /// pending-delete tombstone written in one local transaction (counted as
  /// unsynced, so a failed cloud delete is retried on startup and reconnect
  /// and the patient never comes back on merge); the tombstone is cleared
  /// only once Firestore confirms. Throws (nothing changed) when the local
  /// delete is refused.
  ///
  /// Once the local delete succeeded, the patient's visit photos in the
  /// owner's photo folder are deleted (the tombstone keeps only the id and
  /// time, so they are no longer referenced). A refused delete removes
  /// nothing. See [_deleteUnreferencedPhotos].
  Future<void> deletePatient(String id) async {
    final refused = _loadRefusal(PatientSaveOperation.delete);
    if (refused != null) throw refused;
    final uid = _uid;
    final token = _token;
    final owner = _photoOwner;
    await _underPatientLock(id, () async {
      final removed = _byId(id);
      await _db.markPendingDelete(id); // throws: nothing changed, no photo removed
      _forget(id);
      if (removed != null && owner != null) {
        await _deleteUnreferencedPhotos(owner, [for (final r in removed.history) ...r.attachmentPaths]);
      }
    });
    if (!_cloud) return; // dev mode: the tombstone stays; no cloud delete
    final ok = await _confirmCloudDelete(id);
    if (!ok && _live(uid, token)) _scheduleRetry(uid, token);
  }

  void _forget(String id) {
    final removed = _byId(id);
    _patients.removeWhere((p) => p.id == id);
    _unconfirmed.remove(id);
    if (removed != null) {
      for (final r in removed.history) {
        _pendingUploads.removeAll(r.attachmentPaths);
      }
    }
    notifyListeners();
  }

  /// Visit changes run one at a time and on a copy of the patient: the copy
  /// is saved locally first and replaces the in-memory patient only once
  /// the save succeeded, so a refused save leaves memory (and the next
  /// save) untouched. Throws [LocalSaveFailedException] when nothing was
  /// written, or rethrows the DB's error (e.g. UnsyncedCounterException).
  ///
  /// With [awaitPush] the returned future also waits for the cloud push
  /// (deleteRecord's existing contract); the queue is released as soon as
  /// the local write is done, so an offline push never blocks later saves.
  Future<void> _mutateHistory(
    String patientId,
    Future<List<VisitRecord>?> Function(Patient current) change, {
    required PatientSaveOperation operation,
    bool awaitPush = false,
    List<String>? newCopies,
  }) {
    final run = _historyChain.then<(Future<void>,)?>((_) => _underPatientLock(patientId, () async {
      final refused = _loadRefusal(operation);
      if (refused != null) throw refused;
      final current = _byId(patientId);
      if (current == null) return null;
      _ensureWritable(current);
      final uid = _uid;
      final token = _token;
      final owner = _photoOwner;
      final history = await change(current);
      if (history == null) return null;
      final latest = _byId(patientId);
      if (latest == null || !_live(uid, token)) return null; // deleted or session ended
      final updated = _withHistory(latest, history);
      final refusedNow = _loadRefusal(operation); // a reload failed meanwhile
      if (refusedNow != null) throw refusedNow;
      final String? version;
      try {
        version = await _db.updatePatient(updated);
      } catch (e) {
        notifyListeners();
        rethrow;
      }
      if (version == null) {
        notifyListeners();
        throw LocalSaveFailedException(patientId);
      }
      // Saved: from here on the visit references its photos, so never
      // report "not saved" (that would discard kept photo copies).
      if (!_live(uid, token)) return (Future<void>.value(),); // the startup sweep catches its photos
      _replaceInMemory(updated);
      // Show the row as stored: #10 may have kept a Storage path S where
      // [updated] still had the local path L (attachment_swaps).
      final saved = await _refreshSaved(patientId) ?? updated;
      final fresh = _newLocalFiles(latest, saved);
      if (_cloud) _pendingUploads.addAll(fresh);
      notifyListeners();
      // Saved: photos the change dropped (a deleted visit, or a photo
      // removed while editing) are no longer referenced.
      if (owner != null) await _deleteUnreferencedPhotos(owner, _droppedEntries(latest, saved));
      return (_afterLocalWrite(patientId, version),); // a record: not awaited here
    }));
    _historyChain = run.then((_) {}, onError: (_) {});
    if (newCopies != null) {
      // Photo copies made for this save are deleted only when nothing was
      // saved (refused, failed or skipped before the write).
      unawaited(run.then((pending) async {
        if (pending == null) await _discardCopies(newCopies);
      }, onError: (Object _) => _discardCopies(newCopies)));
    }
    return run.then((pending) async {
      if (pending == null) return;
      final push = pending.$1;
      if (awaitPush) {
        await push;
      } else {
        unawaited(push);
      }
    });
  }

  Future<void> _historyChain = Future.value();

  /// Local files on [after] that were not on [before] and were validated
  /// as fresh picks (recorded in [_validatedPicks]).
  Iterable<String> _newLocalFiles(Patient before, Patient after) {
    final had = {for (final r in before.history) ...r.attachmentPaths};
    final out = <String>[];
    for (final r in after.history) {
      for (final e in r.attachmentPaths) {
        if (!had.contains(e) && _validatedPicks.remove(e)) out.add(e);
      }
    }
    return out;
  }

  /// Attachment entries on [before] that are not on [after].
  static List<String> _droppedEntries(Patient before, Patient after) {
    final now = {for (final r in after.history) ...r.attachmentPaths};
    return [
      for (final r in before.history)
        for (final e in r.attachmentPaths)
          if (!now.contains(e)) e,
    ];
  }

  /// Deletes the files of [owner]'s visit folder that [entries] (stored
  /// attachment entries just removed from the DB) name, after the DB
  /// change succeeded (a delete, an edit that dropped a photo, or a
  /// confirmed upload whose Storage path replaced the local one). The
  /// provider is the single owner of this cleanup (PR #8's screen hooks
  /// become redundant).
  ///
  /// Fails closed: does nothing when the photo owner changed since the
  /// change started, or when any patient in memory has parse errors (its
  /// references may be incomplete). "Still used" is never taken from
  /// memory alone (memory was loaded with `fetchPatients()`, which returns
  /// an empty list on a read error): a fresh [LocalDatabase.referencedAttachmentKeys]
  /// scan must also succeed, and any failure aborts the whole cleanup. A
  /// still-used local entry (memory, a save in progress, a pending upload)
  /// that cannot be keyed aborts it too ([AttachmentRefs.referencedKeys],
  /// security #16 Low-2). Entries are compared by key
  /// ([AttachmentRefs.attachmentKey], #10): a null key (Storage path, web link, another owner's
  /// folder, `..`) is never deleted, nor is a key still referenced by any
  /// visit in memory, by a save in progress or by an upload still pending.
  /// Only regular files inside
  /// the owner's `attachments/` folder are deleted
  /// ([LocalPhotoStore.deleteOwnedVisitFile]); a missing file is ignored,
  /// so a second delete (e.g. #8's screen hook) is harmless. Never throws.
  /// Whatever this skips is left to the startup sweep ([PhotoSweep]).
  Future<void> _deleteUnreferencedPhotos(String owner, Iterable<String> entries,
      {String after = 'a delete'}) async {
    try {
      final list = entries.toList();
      if (list.isEmpty || _photoOwner != owner) return;
      if (_loadFailed) {
        debugPrint('Photos: cleanup skipped (loadFailed)'); // left to the sweep
        return;
      }
      if (_patients.any((p) => p.hasParseErrors)) return;
      final folder = LocalPhotoStore.ownerFolderName(owner);
      final stillUsed = AttachmentRefs.referencedKeys([
        for (final p in _patients)
          for (final r in p.history) ...r.attachmentPaths,
        ..._validatedPicks,
        ..._pendingUploads,
      ], ownerFolderName: folder);
      if (_db.openUid != owner) return;
      stillUsed.addAll(await _db.referencedAttachmentKeys());
      if (_photoOwner != owner || _db.openUid != owner) return;
      await _photos.init();
      var removed = 0;
      for (final e in list) {
        final key = AttachmentRefs.attachmentKey(e, ownerFolderName: folder);
        if (key == null || stillUsed.contains(key)) continue;
        final path = _photos.visitPathForKey(owner, key);
        if (path == null) continue;
        if (await _photos.deleteOwnedVisitFile(path, owner: owner)) removed++;
      }
      if (removed > 0) debugPrint('Photos: removed $removed after $after');
    } on AttachmentScanIncomplete catch (e) {
      final reason = e.reason.name; // an AttachmentScanFailure enum name, never a path
      debugPrint('Photos: cleanup skipped ($reason)'); // left to the sweep
    } catch (e) {
      debugPrint('Photos: cleanup failed (${errorCode(e)})');
    }
  }

  /// Files that passed [_validateNewAttachments] for a save in progress.
  final Set<String> _validatedPicks = {};

  static Patient _withHistory(Patient p, List<VisitRecord> history) => Patient(
        id: p.id, name: p.name, age: p.age, gender: p.gender, phone: p.phone,
        relation: p.relation, updatedAt: p.updatedAt, history: history,
      );

  /// Adds a visit. Every attachment is checked first: if one is not a
  /// JPEG/PNG/WebP image, or is missing, empty or over 10 MiB, this throws
  /// [UnsupportedAttachmentException] naming the file and nothing is
  /// uploaded or saved. Files are then uploaded to
  /// `clinical_attachments/{uid}/{patientId}/{uuid}.{jpg|png|webp}` and the
  /// visit stores those Storage paths. When the local save is refused the
  /// visit is not kept (memory unchanged) and the error is rethrown.
  ///
  /// In dev mode nothing is uploaded: each new photo is kept in the app's
  /// photo folder (copied there unless it already is) and the visit stores
  /// that path.
  Future<void> addRecord(String patientId, VisitRecord record) {
    final copies = <String>[];
    return _mutateHistory(patientId, (current) async {
      final toUpload = await _validateNewAttachments(patientId, record.attachmentPaths);
      final kept = await _keepLocally(toUpload, copies);
      _validatedPicks.addAll(toUpload.map((e) => kept[e] ?? e));
      final latest = _byId(patientId) ?? current;
      return [_withPaths(record, kept), ...latest.history];
    }, operation: PatientSaveOperation.addVisit, newCopies: copies);
  }

  /// Edits a visit. Only attachments not already on the stored visit are
  /// new picks (validated and uploaded as in [addRecord]); stored entries
  /// are kept, and only cloud-safe ones are written to Firestore. A refused
  /// save leaves the old visit in memory.
  Future<void> updateRecord(String patientId, VisitRecord record) {
    final copies = <String>[];
    return _mutateHistory(patientId, (current) async {
      // Under the per-patient lock: the stored row and #10's swaps, both
      // strict. Either read failing refuses the save (nothing written);
      // never fall back to the form's paths.
      final owner = _photoOwner;
      final Patient? storedRow;
      final Map<String, String> swapped;
      try {
        if (owner == null) throw const DbReadException(DbReadFailure.notOpen);
        storedRow = (await _db.fetchPatientsStrict())
            .where((p) => p.id == patientId)
            .firstOrNull;
        swapped = await _swappedPathsFor(owner, patientId);
      } catch (e, st) {
        Error.throwWithStackTrace(
            SaveRefusedException(PatientSaveOperation.updateVisit, e), st);
      }
      // In memory (checked by _mutateHistory) but not in the DB: the save
      // cannot happen, so it is refused rather than silently dropped.
      if (storedRow == null) throw LocalSaveFailedException(patientId);
      if (storedRow.hasParseErrors) {
        throw SaveRefusedException(PatientSaveOperation.updateVisit,
            const DbReadException(DbReadFailure.unreadableRow));
      }
      // A form opened before an upload's swap still names the local path:
      // map swapped keys to their Storage path BEFORE the exists check, so
      // only genuinely missing, unswapped local paths are refused.
      record = _mapSwappedRecord(record, owner, swapped);
      final i = storedRow.history.indexWhere((r) => r.id == record.id);
      if (i == -1) return null;
      final stored = storedRow.history[i].attachmentPaths.toSet();
      final added = record.attachmentPaths.where((e) => !stored.contains(e)).toList();
      final toUpload = await _validateNewAttachments(patientId, added);
      final kept = await _keepLocally(toUpload, copies);
      _validatedPicks.addAll(toUpload.map((e) => kept[e] ?? e));
      // Built on the stored history: a photo the form removed (as L or S)
      // is absent from the saved row, so no broken reference remains.
      return [...storedRow.history]..[i] = _withPaths(record, kept);
    }, operation: PatientSaveOperation.updateVisit, newCopies: copies);
  }

  /// Dev mode: keeps each validated pick in the app's photo folder and
  /// returns original -> kept path for those that were copied (recorded in
  /// [copies]). In cloud mode nothing is copied (the upload path is used).
  Future<Map<String, String>> _keepLocally(List<String> picks, List<String> copies) async {
    final out = <String, String>{};
    if (_cloud) return out;
    final owner = _photoOwner;
    if (owner == null) throw StateError('No open database for these photos');
    for (final path in picks) {
      final type = UploadImageType.forPath(path);
      if (type == null) continue; // validated already; defensive
      final kept = await _photos.keepVisitPhoto(owner, path, type);
      if (kept != path) {
        out[path] = kept;
        copies.add(kept);
      }
    }
    return out;
  }

  static VisitRecord _withPaths(VisitRecord r, Map<String, String> repl) => repl.isEmpty
      ? r
      : _copyRecord(r, [for (final e in r.attachmentPaths) repl[e] ?? e]);

  /// Deletes photo copies of a save that did not happen. Never deletes a
  /// file a visit in memory still references.
  Future<void> _discardCopies(List<String> copies) async {
    final referenced = {
      for (final p in _patients)
        for (final r in p.history) ...r.attachmentPaths,
    };
    final owner = _photoOwner;
    if (owner == null) return; // session gone: keep (fail closed)
    for (final c in copies) {
      if (!referenced.contains(c)) await _photos.deleteAppPhoto(c, owner: owner);
    }
  }

  /// Deletes a visit; a refused save keeps it in memory.
  Future<void> deleteRecord(String patientId, String recordId) =>
      _mutateHistory(patientId, (current) async {
        if (!current.history.any((r) => r.id == recordId)) return null;
        return current.history.where((r) => r.id != recordId).toList();
      }, operation: PatientSaveOperation.deleteVisit, awaitPush: true);

  Patient findById(String id) => _patients.firstWhere((p) => p.id == id);

  /// Runs one push of dirty rows and tombstones, then one pull, for the
  /// current session (tests only; PR #10's sync-state tests use it).
  /// Whether a sync retry is scheduled (tests only).
  @visibleForTesting
  bool get retryPendingForTesting => _retryTimer?.isActive ?? false;

  @visibleForTesting
  Future<void> syncNowForTesting() async {
    final uid = _uid ?? _openDbUid;
    if (!_cloud || uid == null || !_dbReadyFor(uid)) return;
    _uid ??= uid;
    await _pushDirty(uid, _token);
    await _pullFromCloud(uid, _token);
  }

  // ------------------------------------------------------------ session

  /// Drops everything of the current doctor (sign-out / account switch)
  /// and cancels any load, sync, upload or retry still running.
  void clear() {
    _token.cancel();
    _token = SyncCancelToken();
    _uid = null;
    _loading = null;
    _pushInFlight = null;
    _resetRetry();
    _pendingUploads.clear();
    _unswapped.clear();
    _unconfirmed.clear();
    _validatedPicks.clear();
    _resetLoadState();
    _searchQuery = '';
    _isSyncing = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _token.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }
}

/// A details save found no stored row for a patient still shown (deleted
/// meanwhile, or never written). Nothing was written.
class StoredPatientMissingException implements Exception {
  const StoredPatientMissingException(this.patientId);
  final String patientId;
  @override
  String toString() => 'StoredPatientMissingException';
}

/// The local database wrote nothing for this change (it returned no
/// version); the change was not kept.
class LocalSaveFailedException implements Exception {
  const LocalSaveFailedException(this.patientId);
  final String patientId;
  @override
  String toString() => 'LocalSaveFailedException';
}
