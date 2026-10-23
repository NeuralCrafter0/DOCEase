import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';
import '../services/attachments.dart';
import '../services/local_database_sync.dart';
import '../services/log_codes.dart';
import '../services/local_attachment_files.dart';
import '../services/sync_cancel_token.dart';
import 'database_helper.dart';
import 'firestore_helper.dart';

/// Patients of the signed-in doctor. The local (encrypted, per-doctor)
/// database is the source of truth; Firestore is the backup.
///
/// SessionController drives the lifecycle: [loadAndSync] once the local DB
/// reports `DbReady(uid)`, [clear] on sign-out or account switch.
///
/// A row stays `dirty` in the local DB until Firestore confirmed that exact
/// version (`markSynced` with the token from insert/update). Dirty rows are
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
    LocalAttachmentFiles? localFiles,
    Duration retryBaseDelay = const Duration(seconds: 30),
    Duration retryMaxDelay = const Duration(minutes: 5),
  })  : _db = db ?? DatabaseHelper.instance,
        _localFiles = localFiles ?? LocalAttachmentFiles(),
        _firestoreOverride = firestore,
        _authOverride = auth,
        _storageOverride = storage,
        _retryBase = retryBaseDelay,
        _retryMax = retryMaxDelay,
        _retryDelay = retryBaseDelay;

  final LocalDatabase _db;
  final LocalAttachmentFiles _localFiles;
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
  Future<void>? _pushInFlight;

  /// Local files the doctor picked in this session that are not uploaded
  /// yet. Only these are ever uploaded: a local path read back from the
  /// local DB or Firestore is never sent to Storage.
  final Set<String> _pendingUploads = {};

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

  /// The uid whose data is loaded.
  String? get sessionUid => _uid;

  bool isPhoneRegistered(String phone) => _patients.any((p) => p.phone.trim() == phone.trim());

  bool _live(String? uid, SyncCancelToken token) => !token.isCancelled && _uid == uid;

  String? get _signedInUid {
    try {
      return _auth.currentUser?.uid;
    } catch (_) {
      return null; // Firebase not initialised (tests)
    }
  }

  String? get _bucket {
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
    if (_uid != uid) _token.cancel();
    final token = cancel ?? (_token.isCancelled || _uid != uid ? SyncCancelToken() : _token);
    _uid = uid;
    _token = token;
    // Not ready: nothing to share, so the next call (on DbReady) runs.
    if (!_dbReadyFor(uid)) return Future.value();
    final run = _loadAndSync(uid, token);
    _loading = run;
    return run;
  }

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

  /// Whether [uid] is the signed-in user. Fails closed when signed out. Only
  /// when Firebase itself is unavailable and no auth was injected (plain
  /// unit tests; the app never gets here without Firebase) is the check
  /// left to the open-DB uid.
  bool _isSignedIn(String uid) {
    try {
      return _auth.currentUser?.uid == uid;
    } catch (_) {
      return _authOverride == null;
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
      local = await _db.fetchPatients();
    } catch (e) {
      debugPrint('Local load failed: ${errorCode(e)}');
      if (_live(uid, token)) _loading = null;
      return;
    }
    if (!_live(uid, token)) return;
    _patients = local;
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
    // Never read or merge cloud data unless the local DB is open for uid.
    if (!_dbReadyFor(uid)) return;
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
      if (dirtyIds.contains(cp.id) || _unconfirmed.contains(cp.id)) {
        skippedDirty = true; // local edit wins; the retry pushes it
        continue;
      }
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
  Future<bool> _applyCloud(Patient cp) async {
    final db = _db;
    if (db is LocalDatabaseSync) {
      return (db as LocalDatabaseSync).applyCloudPatient(cp);
    }
    // Interim until LocalDatabase.applyCloudPatient lands: re-check right
    // before writing (not atomic; the conditional write closes the gap).
    final dirty = await _dirtyIds();
    if (dirty == null || dirty.contains(cp.id)) return false;
    return await db.insertPatient(cp, fromCloud: true) != null;
  }

  /// Ids of dirty local rows; null if they can't be read.
  Future<Set<String>?> _dirtyIds() async {
    try {
      return (await _db.dirtyPatients()).map((p) => p.id).toSet();
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
    if (uid == null || _token.isCancelled || !_dbReadyFor(uid)) return;
    await _pushDirty(uid, _token);
  }

  Future<void> _pushDirty(String uid, SyncCancelToken token) {
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
      dirty = await _db.dirtyPatients(); // oldest edit first
    } catch (e) {
      debugPrint('Reading unsynced rows failed: ${errorCode(e)}');
      return;
    }
    for (final p in dirty) {
      if (!_live(uid, token)) return;
      final ok = await _syncOne(uid, token, p.id, p.updatedAt, fallback: p);
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
    final db = _db;
    if (db is! LocalDatabaseSync) return true;
    final sync = db as LocalDatabaseSync;
    final List<String> ids;
    try {
      ids = await sync.pendingDeletes();
    } catch (e) {
      debugPrint('Reading pending deletes failed: ${errorCode(e)}');
      return false;
    }
    for (final id in ids) {
      if (!_live(uid, token) || !_dbReadyFor(uid)) return false;
      if (!await _confirmCloudDelete(sync, id)) return false;
    }
    return true;
  }

  Future<bool> _confirmCloudDelete(LocalDatabaseSync sync, String id) async {
    if (!await _firestore.deletePatient(id)) return false;
    try {
      await sync.clearPendingDelete(id);
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
  Future<bool> _syncOne(String? uid, SyncCancelToken token, String patientId, String? version,
      {Patient? fallback}) async {
    if (!_live(uid, token)) return false;
    if (uid != null && !_dbReadyFor(uid)) return false; // other doctor's DB or user
    var current = _byId(patientId) ?? fallback;
    if (current == null) return true; // deleted meanwhile
    if (current.hasParseErrors) return true; // read-only; never synced
    var sentVersion = version;

    final replacements = await _uploadPending(uid, token, current);
    if (!_live(uid, token)) return false;
    if (replacements.isNotEmpty) {
      final latest = _byId(patientId) ?? current;
      current = _withAttachmentsReplaced(latest, replacements);
      _replaceInMemory(current);
      try {
        sentVersion = await _db.updatePatient(current);
      } catch (e) {
        debugPrint('Saving uploaded paths failed for $patientId: ${errorCode(e)}');
        sentVersion = null; // stays dirty; retried later
      }
      // Upload confirmed and the visit now saved locally with the Storage
      // path: the plain local copy (outside the encrypted DB) can go.
      if (sentVersion != null) await _deleteUploadedCopies(current, replacements);
      if (!_live(uid, token)) return false;
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
  Future<void> _afterLocalWrite(String patientId, String? version) async {
    final uid = _uid;
    final token = _token;
    _unconfirmed.add(patientId);
    final ok = await _syncOne(uid, token, patientId, version);
    if (!_live(uid, token)) return;
    final p = _byId(patientId);
    if (!ok || (p != null && _hasPendingUploads(p))) {
      _scheduleRetry(uid, token);
    } else if (_retryTimer != null && uid != null) {
      _resetRetry();
      unawaited(_pushDirty(uid, token));
    }
  }

  /// Deletes the local copy of each uploaded file whose Storage path is in
  /// [saved] (the row just written locally), unless something still refers
  /// to the local path. Only app-owned files are deleted (see
  /// [LocalAttachmentFiles]); a failed upload never reaches here, so its
  /// file stays for the retry.
  Future<void> _deleteUploadedCopies(Patient saved, Map<String, String> replacements) async {
    final savedEntries = {for (final r in saved.history) ...r.attachmentPaths};
    for (final MapEntry(key: local, value: storagePath) in replacements.entries) {
      if (!savedEntries.contains(storagePath)) continue; // visit edited meanwhile
      if (savedEntries.contains(local) || _pendingUploads.contains(local)) continue;
      final stillUsed = _patients.any((p) => p.history.any((r) => r.attachmentPaths.contains(local)));
      if (stillUsed) continue;
      await _localFiles.deleteIfAppOwned(local);
    }
  }

  Future<Map<String, String>> _uploadPending(String? sessionUid, SyncCancelToken token, Patient p) async {
    final out = <String, String>{};
    if (_pendingUploads.isEmpty) return out;
    final uid = sessionUid ?? _signedInUid;
    if (uid == null) return out;
    for (final r in p.history) {
      for (final path in r.attachmentPaths) {
        if (!_pendingUploads.contains(path) || out.containsKey(path)) continue;
        if (!_live(sessionUid, token) || _signedInUid != uid) return out;
        final type = UploadImageType.forPath(path);
        if (type == null) continue; // validated on save; defensive
        final storagePath =
            '${AttachmentPolicy.attachmentFolder(uid, p.id)}/${const Uuid().v4()}.${type.fileExtension}';
        try {
          await _storage
              .ref(storagePath)
              .putFile(File(path), SettableMetadata(contentType: type.contentType));
          out[path] = storagePath;
          _pendingUploads.remove(path);
        } catch (e) {
          debugPrint('Attachment upload failed for patient ${p.id}: ${errorCode(e)}');
          return out; // keeps the local path; retried with the row
        }
      }
    }
    return out;
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
  bool isPickedThisSession(String path) => _pendingUploads.contains(path);

  /// Downloads a `clinical_attachments/{uid}/...` object through the
  /// Storage SDK (so the rules apply). Null for other paths or on error.
  Future<Uint8List?> loadAttachmentBytes(String storagePath) async {
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

  /// Throws [UnsyncedCounterException] (patient not kept, nothing synced)
  /// when the local save is refused.
  Future<void> addPatient(Patient patient) async {
    _ensureWritable(patient);
    _patients.add(patient);
    notifyListeners();
    final String? version;
    try {
      version = await _db.insertPatient(patient);
    } catch (e) {
      // Save refused: don't show it as saved, don't sync.
      _patients.removeWhere((p) => identical(p, patient));
      notifyListeners();
      rethrow;
    }
    unawaited(_afterLocalWrite(patient.id, version));
  }

  /// Throws [UnsyncedCounterException] (previous version restored, nothing
  /// synced) when the local save is refused.
  Future<void> updatePatient(Patient patient) async {
    final index = _patients.indexWhere((p) => p.id == patient.id);
    if (index != -1) {
      _ensureWritable(_patients[index]);
      _ensureWritable(patient);
      final previous = _patients[index];
      _patients[index] = patient;
      notifyListeners();
      final String? version;
      try {
        version = await _db.insertPatient(patient);
      } catch (e) {
        final i = _patients.indexWhere((p) => identical(p, patient));
        if (i != -1) _patients[i] = previous;
        notifyListeners();
        rethrow;
      }
      unawaited(_afterLocalWrite(patient.id, version));
    }
  }

  /// Deletes a patient. With the tombstone API the row is removed and a
  /// pending-delete tombstone written in one local transaction (counted as
  /// unsynced, so a failed cloud delete is retried on startup and reconnect
  /// and the patient never comes back on merge); the tombstone is cleared
  /// only once Firestore confirms. Throws (nothing changed) when the local
  /// delete is refused.
  Future<void> deletePatient(String id) async {
    final db = _db;
    final uid = _uid;
    final token = _token;
    if (db is LocalDatabaseSync) {
      await (db as LocalDatabaseSync).markPendingDelete(id); // throws: nothing changed
    } else {
      // TODO(db-merge): 09a405f API, no tombstone (failed cloud deletes
      // are not retried).
      await db.deletePatient(id);
    }
    _forget(id);
    final ok = db is LocalDatabaseSync
        ? await _confirmCloudDelete(db as LocalDatabaseSync, id)
        : await _firestore.deletePatient(id);
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
    bool awaitPush = false,
  }) {
    final run = _historyChain.then<(Future<void>,)?>((_) async {
      final current = _byId(patientId);
      if (current == null) return null;
      _ensureWritable(current);
      final uid = _uid;
      final token = _token;
      final history = await change(current);
      if (history == null) return null;
      final latest = _byId(patientId);
      if (latest == null || !_live(uid, token)) return null; // deleted or session ended
      final updated = _withHistory(latest, history);
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
      if (!_live(uid, token)) return null;
      _replaceInMemory(updated);
      _pendingUploads.addAll(_newLocalFiles(latest, updated));
      notifyListeners();
      return (_afterLocalWrite(patientId, version),); // a record: not awaited here
    });
    _historyChain = run.then((_) {}, onError: (_) {});
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
  Future<void> addRecord(String patientId, VisitRecord record) =>
      _mutateHistory(patientId, (current) async {
        final toUpload = await _validateNewAttachments(patientId, record.attachmentPaths);
        _validatedPicks.addAll(toUpload);
        final latest = _byId(patientId) ?? current;
        return [record, ...latest.history];
      });

  /// Edits a visit. Only attachments not already on the stored visit are
  /// new picks (validated and uploaded as in [addRecord]); stored entries
  /// are kept, and only cloud-safe ones are written to Firestore. A refused
  /// save leaves the old visit in memory.
  Future<void> updateRecord(String patientId, VisitRecord record) =>
      _mutateHistory(patientId, (current) async {
        final i = current.history.indexWhere((r) => r.id == record.id);
        if (i == -1) return null;
        final stored = current.history[i].attachmentPaths.toSet();
        final added = record.attachmentPaths.where((e) => !stored.contains(e)).toList();
        final toUpload = await _validateNewAttachments(patientId, added);
        _validatedPicks.addAll(toUpload);
        final latest = _byId(patientId) ?? current;
        final j = latest.history.indexWhere((r) => r.id == record.id);
        if (j == -1) return null;
        return [...latest.history]..[j] = record;
      });

  /// Deletes a visit; a refused save keeps it in memory.
  Future<void> deleteRecord(String patientId, String recordId) =>
      _mutateHistory(patientId, (current) async {
        if (!current.history.any((r) => r.id == recordId)) return null;
        return current.history.where((r) => r.id != recordId).toList();
      }, awaitPush: true);

  Patient findById(String id) => _patients.firstWhere((p) => p.id == id);

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
    _unconfirmed.clear();
    _validatedPicks.clear();
    _patients = [];
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

/// The local database wrote nothing for this change (it returned no
/// version); the change was not kept.
class LocalSaveFailedException implements Exception {
  const LocalSaveFailedException(this.patientId);
  final String patientId;
  @override
  String toString() => 'LocalSaveFailedException';
}
