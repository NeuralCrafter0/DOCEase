// Hand-written fakes for the backend tests (no new packages). Firebase
// classes are implemented with noSuchMethod for everything not used.
// ignore_for_file: subtype_of_sealed_class, must_be_immutable
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/firestore_helper.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/legacy_db_inspector.dart';
import 'package:docease/services/session_platform.dart';
import 'package:docease/services/sync_cancel_token.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../support/db_fakes.dart';

export '../support/db_fakes.dart' show FakeLocalDatabase, FakeFirestoreHelper, testPatient, flushMicrotasks;

// ------------------------------------------------------------------ Auth

class FakeUser implements User {
  FakeUser(this.uid, {this.emailVerified = true});
  @override
  final String uid;
  @override
  bool emailVerified;
  @override
  Future<void> reload() async {}
  @override
  Future<String?> getIdToken([bool forceRefresh = false]) async => 'token';
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeAuth implements FirebaseAuth {
  FakeAuth([String? uid]) : currentUser = uid == null ? null : FakeUser(uid);
  @override
  User? currentUser;
  void signIn(String uid) => currentUser = FakeUser(uid);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ------------------------------------------------------------- Firestore

/// In-memory documents keyed by full path ("doctors/a/settings/medicines").
class FakeFirestore implements FirebaseFirestore {
  final Map<String, Map<String, dynamic>> docs = {};
  final List<String> log = [];
  Object? failWrites;
  Object? failReads;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => FakeCollection(this, path);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeCollection implements CollectionReference<Map<String, dynamic>> {
  FakeCollection(this.fs, this.path);
  final FakeFirestore fs;
  @override
  final String path;
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) => FakeDoc(fs, '$path/$id');
  @override
  Future<QuerySnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    if (fs.failReads != null) throw fs.failReads!;
    final prefix = '$path/';
    final hits = fs.docs.entries
        .where((e) => e.key.startsWith(prefix) && !e.key.substring(prefix.length).contains('/'))
        .map((e) => FakeQueryDoc(e.key.substring(prefix.length), e.value))
        .toList();
    return FakeQuery(hits);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeQuery implements QuerySnapshot<Map<String, dynamic>> {
  FakeQuery(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeQueryDoc implements QueryDocumentSnapshot<Map<String, dynamic>> {
  FakeQueryDoc(this.id, this._data);
  @override
  final String id;
  final Map<String, dynamic> _data;
  @override
  Map<String, dynamic> data() => Map<String, dynamic>.from(_data);
  @override
  bool get exists => true;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeDoc implements DocumentReference<Map<String, dynamic>> {
  FakeDoc(this.fs, this.path);
  final FakeFirestore fs;
  @override
  final String path;
  @override
  String get id => path.split('/').last;
  @override
  CollectionReference<Map<String, dynamic>> collection(String p) => FakeCollection(fs, '$path/$p');
  @override
  Future<DocumentSnapshot<Map<String, dynamic>>> get([GetOptions? options]) async {
    if (fs.failReads != null) throw fs.failReads!;
    fs.log.add('get:$path');
    return FakeDocSnap(id, fs.docs[path]);
  }

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    if (fs.failWrites != null) throw fs.failWrites!;
    final merge = options?.merge ?? false;
    fs.log.add('set:$path:${merge ? 'merge' : 'replace'}');
    fs.docs[path] = merge ? {...?fs.docs[path], ...data} : Map<String, dynamic>.from(data);
  }

  @override
  Future<void> delete() async {
    if (fs.failWrites != null) throw fs.failWrites!;
    fs.log.add('delete:$path');
    fs.docs.remove(path);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeDocSnap implements DocumentSnapshot<Map<String, dynamic>> {
  FakeDocSnap(this.id, this._data);
  @override
  final String id;
  final Map<String, dynamic>? _data;
  @override
  bool get exists => _data != null;
  @override
  Map<String, dynamic>? data() => _data == null ? null : Map<String, dynamic>.from(_data);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// --------------------------------------------------------------- Storage

class FakeStorage implements FirebaseStorage {
  /// fullPath -> content type of each completed upload.
  final Map<String, String?> uploads = {};
  final Map<String, Uint8List> objects = {};
  bool failUploads = false;

  /// Number of putFile calls (a retried swap must not upload again).
  int puts = 0;

  /// Awaited before an upload completes: simulates work landing mid-upload.
  Future<void> Function(String fullPath)? beforeUploadCompletes;

  /// Paths passed to Reference.delete(), in order.
  final List<String> deleted = [];
  bool failDeletes = false;
  @override
  String get bucket => 'demo-docease.appspot.com';
  @override
  Reference ref([String? path]) => FakeRef(this, path ?? '');
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeRef implements Reference {
  FakeRef(this.storage, this.fullPath);
  @override
  final FakeStorage storage;
  @override
  final String fullPath;
  @override
  Reference child(String path) => FakeRef(storage, fullPath.isEmpty ? path : '$fullPath/$path');
  @override
  UploadTask putFile(File file, [SettableMetadata? metadata]) {
    if (storage.failUploads) {
      return FakeUploadTask(Future.error(FirebaseException(plugin: 'storage', code: 'unavailable')));
    }
    storage.puts++;
    final bytes = file.readAsBytesSync();
    void record() {
      storage.uploads[fullPath] = metadata?.contentType;
      storage.objects[fullPath] = bytes;
    }
    final hook = storage.beforeUploadCompletes;
    if (hook == null) {
      record();
      return FakeUploadTask(Future.value(FakeTaskSnapshot()));
    }
    return FakeUploadTask(hook(fullPath).then((_) {
      record();
      return FakeTaskSnapshot();
    }));
  }

  @override
  Future<void> delete() async {
    if (storage.failDeletes) throw FirebaseException(plugin: 'storage', code: 'unavailable');
    storage.deleted.add(fullPath);
    storage.uploads.remove(fullPath);
    storage.objects.remove(fullPath);
  }

  @override
  Future<String> getDownloadURL() async => 'https://firebasestorage.googleapis.com/v0/b/x/o/${Uri.encodeComponent(fullPath)}?token=t';
  @override
  Future<Uint8List?> getData([int maxSize = 10485760]) async => storage.objects[fullPath];
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeTaskSnapshot implements TaskSnapshot {
  @override
  TaskState get state => TaskState.success;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

class FakeUploadTask implements UploadTask {
  FakeUploadTask(this._f) {
    _f.ignore(); // errors are observed by whoever awaits the task
  }
  final Future<TaskSnapshot> _f;
  @override
  Future<R> then<R>(FutureOr<R> Function(TaskSnapshot) onValue, {Function? onError}) =>
      _f.then(onValue, onError: onError);
  @override
  Future<TaskSnapshot> catchError(Function onError, {bool Function(Object error)? test}) =>
      _f.catchError(onError, test: test);
  @override
  Future<TaskSnapshot> whenComplete(FutureOr<void> Function() action) => _f.whenComplete(action);
  @override
  Stream<TaskSnapshot> asStream() => _f.asStream();
  @override
  Future<TaskSnapshot> timeout(Duration timeLimit, {FutureOr<TaskSnapshot> Function()? onTimeout}) =>
      _f.timeout(timeLimit, onTimeout: onTimeout);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

// ---------------------------------------------------- Firestore helper

/// FakeFirestoreHelper that can return cloud patients and records payloads.
class CloudFirestoreHelper extends FakeFirestoreHelper {
  // `cloud` (the patients fetchAllPatients returns) is inherited.
  Completer<List<Patient>>? fetchGate;
  final List<Patient> payloads = [];
  int fetches = 0;
  final List<String> deletes = [];

  @override
  Future<bool> deletePatient(String patientId) {
    deletes.add(patientId);
    return super.deletePatient(patientId); // deleteResult ?? syncResult
  }

  @override
  Future<bool> syncPatient(Patient patient) {
    payloads.add(patient);
    return super.syncPatient(patient);
  }

  @override
  Future<List<Patient>> fetchAllPatients() async {
    fetches++;
    final gate = fetchGate;
    if (gate != null) return gate.future;
    return cloud;
  }
}

// ------------------------------------------------------ local database

/// FakeLocalDatabase plus the DB engineer's confirmed additions
/// (LocalDatabase sync API): applyCloudPatient writes the cloud copy as synced
/// only if the local row is missing or clean and has no tombstone;
/// markPendingDelete removes the row and writes a tombstone in one step
/// (counted as unsynced); clearPendingDelete drops it.
class MergeDb extends FakeLocalDatabase {
  final List<String> applyLog = [];

  // ---- swappedPathsFor: #10's real fake (b217f46) plus test hooks ----
  /// (owner, patientId) of every swappedPathsFor call.
  final List<(String, String)> swappedReads = [];

  /// Thrown by swappedPathsFor (after the call is recorded) when set.
  Object? swappedPathsThrows;

  @override
  Future<Map<String, String>> swappedPathsFor({
    required String expectedOwner,
    required String patientId,
  }) {
    swappedReads.add((expectedOwner, patientId));
    final t = swappedPathsThrows;
    if (t != null) return Future.error(t);
    return super.swappedPathsFor(expectedOwner: expectedOwner, patientId: patientId);
  }

  // ---- swapAttachmentPath: #10's real fake (fed74ca) plus test hooks ----
  int swapCalls = 0;

  /// Thrown by the swap (after the call is counted, writing nothing) when set.
  Object? swapThrows;

  /// Runs at the start of each swap, before its checks.
  void Function(String patientId, String localPath)? beforeSwap;

  /// Runs after each swap that returned true (the row already holds the
  /// Storage path).
  void Function(String patientId, String localPath)? afterSwap;

  /// Delegates to [FakeLocalDatabase.swapAttachmentPath], which follows
  /// the DB engineer's contract: true = swapped (row dirty, new version);
  /// false = no row, tombstoned or no entry with that key (nothing written);
  /// ArgumentError for bad arguments (storage path not exactly
  /// `clinical_attachments/<owner>/<patientId>/<file>`, local path not a
  /// visit photo in the owner's attachments folder); DbReadException
  /// notOpen (also an owner mismatch) / unreadableRow.
  @override
  Future<bool> swapAttachmentPath({
    required String expectedOwner,
    required String patientId,
    required String localPath,
    required String storagePath,
  }) async {
    swapCalls++;
    beforeSwap?.call(patientId, localPath);
    final t = swapThrows;
    if (t != null) throw t;
    final ok = await super.swapAttachmentPath(
        expectedOwner: expectedOwner, patientId: patientId,
        localPath: localPath, storagePath: storagePath);
    if (ok) afterSwap?.call(patientId, localPath);
    return ok;
  }

  /// When set, the strict row reads (fetchPatientsStrict and the one-row
  /// fetchPatientStrict) throw it; the push's dirty read keeps working.
  Object? fetchStrictThrows;
  int strictFetches = 0;

  @override
  Future<List<Patient>> fetchPatientsStrict() async {
    strictFetches++;
    final t = fetchStrictThrows;
    if (t != null) throw t;
    return [for (final p in await super.fetchPatientsStrict()) _stamped(p)];
  }

  int strictOneFetches = 0;

  @override
  Future<Patient?> fetchPatientStrict({required String expectedOwner, required String patientId}) async {
    strictOneFetches++;
    final t = fetchStrictThrows;
    if (t != null) throw t;
    final p = await super.fetchPatientStrict(expectedOwner: expectedOwner, patientId: patientId);
    return p == null ? null : _stamped(p);
  }

  /// Like the real DB, a strict read returns each row with its stored
  /// version as `updatedAt` (the fake keeps the caller's copy otherwise).
  Patient _stamped(Patient p) {
    final v = versions[p.id];
    if (v == null || p.updatedAt == v || p.hasParseErrors) return p;
    return Patient.fromJson(p.toJson(), updatedAt: v);
  }

  /// Runs before each referencedAttachmentKeys scan (e.g. a write from
  /// outside the provider's lock).
  void Function()? beforeKeyScan;
  int keyScans = 0;

  @override
  Future<Set<String>> referencedAttachmentKeys() {
    keyScans++;
    beforeKeyScan?.call();
    return super.referencedAttachmentKeys();
  }

  /// updatePatient throws UnsyncedCounterException (save refused).
  bool refuseUpdates = false;

  /// updatePatient writes nothing and returns null.
  bool updatesReturnNull = false;
  bool refusePendingDelete = false;
  bool failClearPendingDelete = false;

  @override
  Future<String?> updatePatient(Patient patient) async {
    if (refuseUpdates) throw UnsyncedCounterException('doctorA');
    if (updatesReturnNull) return null;
    return super.updatePatient(patient);
  }

  @override
  Future<UnsyncedCount> unsyncedCount() async =>
      UnsyncedCount.known(dirty.values.where((d) => d).length + tombstones.length);

  @override
  Future<void> markPendingDelete(String patientId) async {
    if (refusePendingDelete) throw UnsyncedCounterException('doctorA');
    log.add('markPendingDelete:$patientId');
    rows.remove(patientId);
    dirty.remove(patientId);
    versions.remove(patientId);
    tombstones.add(patientId);
  }

  @override
  Future<List<String>> pendingDeletes() async => tombstones.toList();

  @override
  Future<void> clearPendingDelete(String patientId) async {
    if (failClearPendingDelete) throw StateError('disk full');
    log.add('clearPendingDelete:$patientId');
    tombstones.remove(patientId);
  }

  /// Runs inside the conditional write, before its check: simulates a local
  /// edit committed while the merge was running.
  void Function(String id)? beforeApply;
  bool failDirtyRead = false;

  @override
  Future<List<Patient>> dirtyPatients() async {
    if (failDirtyRead) throw StateError('secret SQL with key x\'00\'');
    return super.dirtyPatients();
  }

  @override
  Future<List<Patient>> dirtyPatientsStrict() async {
    if (failDirtyRead) throw const DbReadException(DbReadFailure.readFailed);
    return [for (final p in await super.dirtyPatientsStrict()) _stamped(p)];
  }

  @override
  Future<bool> applyCloudPatient(Patient patient) async {
    beforeApply?.call(patient.id);
    if (dirty[patient.id] == true || tombstones.contains(patient.id)) {
      applyLog.add('skip:${patient.id}');
      return false;
    }
    applyLog.add('apply:${patient.id}');
    rows[patient.id] = patient;
    dirty[patient.id] = false;
    versions[patient.id] = 'c${applyLog.length}';
    return true;
  }
}

/// Local DB fake with a real state stream, open/close per uid and legacy
/// handling, built on the DB engineer's FakeLocalDatabase rows/dirty logic.
class SessionDb extends FakeLocalDatabase {
  SessionDb() {
    state = const DbClosed();
  }
  final _states = StreamController<DbOpenState>.broadcast(sync: true);
  final List<String> events = [];

  /// When false, openFor leaves the DB in DbOpening (test emits later).
  bool autoReady = true;
  DbOpenException? openError;
  bool legacy = false;

  void emit(DbOpenState s) {
    state = s;
    _states.add(s);
  }

  @override
  Stream<DbOpenState> get states => _states.stream;

  @override
  Future<void> openFor(String uid) async {
    events.add('open:$uid');
    emit(DbOpening(uid));
    final err = openError;
    if (err != null) {
      emit(DbFailed(uid, err.error));
      throw err;
    }
    if (autoReady) emit(DbReady(uid));
  }

  @override
  Future<void> close() async {
    events.add('close');
    emit(const DbClosed());
  }

  @override
  Future<bool> hasLegacyDb() async => legacy;

  @override
  Future<bool> claimLegacyDb(String uid) async {
    events.add('claim:$uid');
    if (!legacy) return false;
    legacy = false;
    emit(DbReady(uid));
    return true;
  }

  int resets = 0;
  @override
  Future<void> resetAndResync(
      {required UnsyncedCount acknowledgedUnsynced, Future<void> Function()? resync}) async {
    events.add('reset');
    resets++;
    emit(DbReady(state.uid!));
  }
}

class InspectableSessionDb extends SessionDb implements LegacyDbInspector {
  Set<String> legacyIds = {};
  @override
  Future<Set<String>> legacyPatientIds() async => legacy ? legacyIds : {};
}

// ------------------------------------------------------- session platform

class FakeSessionPlatform implements SessionPlatform {
  FakeSessionPlatform(this.log);
  final List<String> log;
  final Map<String, String> flags = {};
  ApprovalStatus approval = ApprovalStatus.approved;
  Map<String, ApprovalStatus> approvalByUid = {};
  Set<String>? cloudIds = {};

  @override
  Future<ApprovalStatus> checkApproval(User user) async {
    log.add('approval:${user.uid}');
    return approvalByUid[user.uid] ?? approval;
  }

  @override
  Future<Set<String>?> cloudPatientIds(String uid) async => cloudIds;
  @override
  Future<void> signOutFirebase() async => log.add('firebase.signOut');
  @override
  Future<void> signOutGoogle() async => log.add('google.signOut');
  @override
  Future<void> clearFirestoreCache() async => log.add('firestore.clearCache');
  @override
  void clearImageCache() => log.add('images.clear');
  @override
  Future<String?> readFlag(String key) async => flags[key];
  @override
  Future<void> writeFlag(String key, String value) async => flags[key] = value;
  @override
  Future<void> deleteFlag(String key) async => flags.remove(key);
}

// ------------------------------------------------------------ spy providers

class SpyPatients extends PatientProvider {
  SpyPatients(this.log) : super(db: FakeLocalDatabase(), firestore: FakeFirestoreHelper());
  final List<String> log;
  SyncCancelToken? lastToken;
  @override
  Future<void> loadAndSync(String uid, {SyncCancelToken? cancel}) async {
    lastToken = cancel;
    log.add('patients.load:$uid');
  }

  @override
  Future<void> retryDirty() async => log.add('patients.retry');
  @override
  void clear() {
    log.add('patients.clear');
    super.clear();
  }
}

class SpyDoctor extends DoctorProvider {
  SpyDoctor(this.log) : super(auth: FakeAuth(), firestore: FakeFirestore(), storage: FakeStorage());
  final List<String> log;
  @override
  Future<void> load(String uid) async => log.add('doctor.load:$uid');
  @override
  void clear() {
    log.add('doctor.clear');
    super.clear();
  }
}

class SpyMedicines extends MedicineProvider {
  SpyMedicines(this.log) : super(auth: FakeAuth(), firestore: FakeFirestore());
  final List<String> log;
  @override
  Future<void> load(String uid) async => log.add('medicines.load:$uid');
  @override
  void clear() {
    log.add('medicines.clear');
    super.clear();
  }
}

/// A real FirestoreHelper on fakes, for its own tests.
FirestoreHelper helperOn(FakeFirestore fs, FakeAuth auth, {String? Function()? expectedUid}) =>
    FirestoreHelper(firestore: fs, auth: auth, expectedUid: expectedUid);
