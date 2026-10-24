// Hand-written fakes for host unit tests. No extra packages.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/firestore_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' show Database;

/// In-memory [DbKeyStore] with switchable failures.
class MemoryKeyStore implements DbKeyStore {
  final Map<String, String> values = {};
  final List<String> log = [];
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;

  /// Only fail reads/writes of names matching this (null = all names).
  bool Function(String name)? failOnly;

  bool _fails(bool flag, String name) =>
      flag && (failOnly == null || failOnly!(name));

  @override
  Future<String?> read(String name) async {
    log.add('read:$name');
    if (_fails(failRead, name)) throw const OSError('keystore unavailable');
    return values[name];
  }

  @override
  Future<void> write(String name, String value) async {
    log.add('write:$name');
    if (_fails(failWrite, name)) throw const OSError('keystore unavailable');
    values[name] = value;
  }

  @override
  Future<void> delete(String name) async {
    log.add('delete:$name');
    if (_fails(failDelete, name)) throw const OSError('keystore unavailable');
    values.remove(name);
  }
}

class OpenCall {
  OpenCall(this.path, this.key, this.version);
  final String path;
  final String? key;
  final int? version;
  @override
  String toString() => 'open($path, key: ${key == null ? 'null' : '***'})';
}

/// [CipherDatabaseOpener] that records calls and fails with [error]. It never
/// returns a database, so a test using it proves nothing was opened.
class RecordingOpener implements CipherDatabaseOpener {
  RecordingOpener([this.error]);
  Object? error;
  final List<OpenCall> calls = [];

  @override
  Future<Database> open(String path,
      {required String key,
      int? version,
      onCreate,
      onUpgrade,
      onDowngrade}) async {
    calls.add(OpenCall(path, key, version));
    throw error ?? StateError('RecordingOpener: open() must not be called');
  }

  @override
  Future<Database> openPlaintext(String path,
      {int? version, onCreate}) async {
    calls.add(OpenCall(path, null, version));
    throw error ?? StateError('RecordingOpener: openPlaintext() must not be called');
  }
}

/// Records backup-exclusion requests; never touches the platform.
class RecordingBackupExcluder implements BackupExcluder {
  final List<String> excluded = [];
  bool fail = false;
  @override
  Future<void> exclude(String path) async {
    if (fail) throw const OSError('exclusion failed');
    excluded.add(path);
  }
}

/// Captures debugPrint output while [body] runs.
Future<T> captureLogs<T>(List<String> sink, Future<T> Function() body) async {
  final previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) sink.add(message);
  };
  try {
    return await body();
  } finally {
    debugPrint = previous;
  }
}

/// In-memory [LocalDatabase] for PatientProvider tests.
class FakeLocalDatabase implements LocalDatabase {
  final Map<String, Patient> rows = {};
  final Map<String, bool> dirty = {};
  final Map<String, String> versions = {};
  final List<String> log = [];
  int _version = 0;

  @override
  DbOpenState state = const DbReady('doctorA');

  @override
  String? get openUid => state is DbReady ? state.uid : null;

  final Set<String> tombstones = {};

  /// attachment_swaps: patientId -> local key -> Storage path.
  final Map<String, Map<String, String>> swaps = {};

  /// [patient] with recorded swaps re-applied, as a local save does.
  Patient _keepingSwaps(Patient patient) {
    final recorded = swaps[patient.id];
    final uid = openUid;
    if (recorded == null || recorded.isEmpty || uid == null) return patient;
    final json = patient.toJson();
    final (history, n) = AttachmentRefs.applySwapsToHistoryJson(
        jsonEncode(json['history']), recorded,
        uid: uid, patientId: patient.id);
    final gone = AttachmentRefs.unreferencedSwapKeys(history, recorded, uid: uid);
    recorded.removeWhere((k, _) => gone.contains(k));
    if (n == 0) return patient;
    return Patient.fromJson({...json, 'history': jsonDecode(history)},
        updatedAt: patient.updatedAt);
  }

  @override
  Stream<DbOpenState> get states => Stream.value(state);

  @override
  Future<void> openFor(String uid) async {}
  @override
  Future<void> close() async {}

  @override
  Future<UnsyncedCount> unsyncedCount() async =>
      UnsyncedCount.known(dirty.values.where((d) => d).length + tombstones.length);

  @override
  Future<void> resetAndResync(
          {required UnsyncedCount acknowledgedUnsynced,
          Future<void> Function()? resync}) async =>
      throw UnimplementedError();

  @override
  Future<bool> hasLegacyDb() async => false;
  @override
  Future<bool> claimLegacyDb(String uid) async => false;

  @override
  Future<List<Patient>> fetchPatients() async => rows.values.toList();

  /// When set, every strict read throws DbReadException(strictReadFailure)
  /// while the lenient reads keep returning what they hold.
  DbReadFailure? strictReadFailure;
  Future<T> _strict<T>(T Function() read) async {
    final f = strictReadFailure;
    if (f != null) throw DbReadException(f);
    if (openUid == null) throw const DbReadException(DbReadFailure.notOpen);
    return read();
  }

  @override
  Future<List<Patient>> fetchPatientsStrict() => _strict(() {
        if (rows.values.any((p) => p.hasParseErrors)) {
          throw const DbReadException(DbReadFailure.unreadableRow);
        }
        return rows.values.toList();
      });

  @override
  Future<List<Patient>> dirtyPatientsStrict() async {
    final list = await _strict(() => [
          for (final e in rows.entries) if (dirty[e.key] == true) e.value
        ]);
    if (list.any((p) => p.hasParseErrors)) {
      throw const DbReadException(DbReadFailure.unreadableRow);
    }
    return list;
  }

  @override
  Future<List<String>> pendingDeletesStrict() =>
      _strict(() => tombstones.toList());

  @override
  Future<Map<String, String>> swappedPathsFor(
      {required String expectedOwner, required String patientId}) async {
    if (expectedOwner.isEmpty) {
      throw ArgumentError.value('', 'expectedOwner', 'must not be empty');
    }
    if (patientId.isEmpty) {
      throw ArgumentError.value('', 'patientId', 'must not be empty');
    }
    return _strict(() {
      if (openUid != expectedOwner) {
        throw const DbReadException(DbReadFailure.notOpen);
      }
      return AttachmentRefs.validSwapMappings([
        for (final e in (swaps[patientId] ?? const {}).entries)
          {'local_key': e.key, 'storage_path': e.value},
      ], uid: expectedOwner, patientId: patientId);
    });
  }

  @override
  Future<List<Patient>> dirtyPatients() async =>
      [for (final e in rows.entries) if (dirty[e.key] == true) e.value];

  /// Simulates secure storage failing so the counter cannot be kept honest.
  bool refuseWrites = false;

  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) async {
    if (patient.hasParseErrors) return null;
    if (fromCloud) {
      if (!await applyCloudPatient(patient)) return null;
      return versions[patient.id];
    }
    if (refuseWrites) throw UnsyncedCounterException('doctorA');
    log.add('insert:${patient.id}:${fromCloud ? 'synced' : 'dirty'}');
    rows[patient.id] = _keepingSwaps(patient);
    dirty[patient.id] = !fromCloud;
    return versions[patient.id] = '${++_version}';
  }

  @override
  Future<String?> updatePatient(Patient patient) async {
    if (patient.hasParseErrors || !rows.containsKey(patient.id)) return null;
    log.add('update:${patient.id}:dirty');
    rows[patient.id] = _keepingSwaps(patient);
    dirty[patient.id] = true;
    return versions[patient.id] = '${++_version}';
  }

  @override
  Future<bool> markSynced(String id, String version) async {
    log.add('markSynced:$id:$version');
    if (versions[id] != version || dirty[id] != true) return false;
    dirty[id] = false;
    return true;
  }

  /// Same gate as the real helper: never over a dirty row or a tombstone.
  @override
  Future<bool> applyCloudPatient(Patient patient) async {
    if (patient.hasParseErrors ||
        dirty[patient.id] == true ||
        tombstones.contains(patient.id)) {
      log.add('cloudSkipped:${patient.id}');
      return false;
    }
    log.add('insert:${patient.id}:synced');
    rows[patient.id] = patient;
    dirty[patient.id] = false;
    versions[patient.id] = '${++_version}';
    return true;
  }

  /// When true, markPendingDelete throws as if no database were open.
  bool refuseDeletes = false;

  @override
  Future<void> markPendingDelete(String id) async {
    if (refuseWrites) throw UnsyncedCounterException('doctorA');
    if (refuseDeletes) {
      throw DbOpenException(DbOpenError.migrationFailed, uid: 'doctorA');
    }
    log.add('tombstone:$id');
    rows.remove(id);
    swaps.remove(id);
    dirty.remove(id);
    versions.remove(id);
    tombstones.add(id);
  }

  @override
  Future<void> deletePatient(String id) => markPendingDelete(id);

  /// Same contract as the real helper (argument checks, owner check, key
  /// matching, false only when the photo is gone, dirty + version bump).
  @override
  Future<bool> swapAttachmentPath(
      {required String expectedOwner,
      required String patientId,
      required String localPath,
      required String storagePath}) async {
    final key = AttachmentRefs.swapKeyFor(
        expectedOwner: expectedOwner,
        patientId: patientId,
        localPath: localPath,
        storagePath: storagePath);
    if (openUid != expectedOwner) {
      throw const DbReadException(DbReadFailure.notOpen);
    }
    if (refuseWrites) throw UnsyncedCounterException(expectedOwner);
    if (tombstones.contains(patientId)) return false;
    final p = rows[patientId];
    if (p == null) return false;
    if (p.hasParseErrors) {
      throw const DbReadException(DbReadFailure.unreadableRow);
    }
    final json = p.toJson();
    final next = AttachmentRefs.swapInHistoryJson(jsonEncode(json['history']),
        key: key,
        ownerFolderName: AttachmentRefs.ownerFolderNameFor(expectedOwner),
        storagePath: storagePath);
    if (next == null) return false;
    log.add('swap:$patientId');
    (swaps[patientId] ??= {})[key] = storagePath;
    final version = '${++_version}';
    rows[patientId] = Patient.fromJson({...json, 'history': jsonDecode(next)},
        updatedAt: version);
    dirty[patientId] = true;
    versions[patientId] = version;
    return true;
  }

  @override
  Future<List<String>> pendingDeletes() async => tombstones.toList();

  @override
  Future<void> clearPendingDelete(String id) async {
    log.add('clearTombstone:$id');
    tombstones.remove(id);
  }

  final Map<String, String> settings = {};
  void _requireOpen() {
    if (state is! DbReady) throw StateError('No doctor database is open.');
  }

  @override
  Future<String?> getSetting(String key) async {
    _requireOpen();
    return settings[key];
  }

  @override
  Future<void> putSetting(String key, String value) async {
    _requireOpen();
    settings[key] = value;
  }

  @override
  Future<void> deleteSetting(String key) async {
    _requireOpen();
    settings.remove(key);
  }

  /// Same pure collectors as DatabaseHelper, over the in-memory rows.
  Set<String> _scan() {
    final st = state;
    if (st is DbFailed) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.openFailed);
    }
    if (st is! DbReady) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.noDatabase);
    }
    return AttachmentRefs.collectReferencedPaths(
      historyValues: rows.values.map(
          (p) => jsonEncode(p.history.map((r) => r.toJson()).toList())),
      doctorProfileValue: settings[AttachmentRefs.doctorProfileSettingKey],
    );
  }

  @override
  Future<Set<String>> referencedAttachmentPaths() async => _scan();

  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    final paths = _scan();
    return AttachmentRefs.referencedKeys(paths,
        ownerFolderName: AttachmentRefs.ownerFolderNameFor(openUid!));
  }
}

/// [FirestoreHelper] fake: never touches Firebase. Each write waits for
/// [gate] (if set), then reports [syncResult].
class FakeFirestoreHelper implements FirestoreHelper {
  bool syncResult = true;

  /// When true, each syncPatient call waits on its own completer in
  /// [inFlight]; the test completes them (true = confirmed) in any order.
  bool manual = false;
  final List<Completer<bool>> inFlight = [];
  final List<String> synced = [];

  @override
  Future<bool> syncPatient(Patient patient) async {
    synced.add(patient.id);
    if (manual) {
      final c = Completer<bool>();
      inFlight.add(c);
      return c.future;
    }
    return syncResult;
  }

  final List<String> deleted = [];

  /// Result of each cloud delete (default: [syncResult]).
  bool? deleteResult;

  @override
  Future<bool> deletePatient(String patientId) async {
    deleted.add(patientId);
    return deleteResult ?? syncResult;
  }

  /// What fetchAllPatients returns.
  List<Patient> cloud = [];

  @override
  Future<List<Patient>> fetchAllPatients() async => cloud;
}

Patient testPatient(String id, {String name = 'Asha', List<VisitRecord>? history}) =>
    Patient(
        id: id,
        name: name,
        age: '34',
        gender: 'Female',
        phone: '+919990000000',
        history: history ?? []);

/// Lets unawaited futures (fire-and-forget cloud pushes) complete.
Future<void> flushMicrotasks() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Lowercase hex of [bytes].
String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
