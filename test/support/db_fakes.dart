// Hand-written fakes for host unit tests. No extra packages.
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/firestore_helper.dart';
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
      {String? key,
      int? version,
      onCreate,
      onUpgrade,
      onDowngrade}) async {
    calls.add(OpenCall(path, key, version));
    throw error ?? StateError('RecordingOpener: open() must not be called');
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
  Stream<DbOpenState> get states => Stream.value(state);

  @override
  Future<void> openFor(String uid) async {}
  @override
  Future<void> close() async {}

  @override
  Future<UnsyncedCount> unsyncedCount() async =>
      UnsyncedCount.known(dirty.values.where((d) => d).length);

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

  @override
  Future<List<Patient>> dirtyPatients() async =>
      [for (final e in rows.entries) if (dirty[e.key] == true) e.value];

  /// Simulates secure storage failing so the counter cannot be kept honest.
  bool refuseWrites = false;

  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) async {
    if (patient.hasParseErrors) return null;
    if (refuseWrites && !fromCloud) throw const UnsyncedCounterException('doctorA');
    log.add('insert:${patient.id}:${fromCloud ? 'synced' : 'dirty'}');
    rows[patient.id] = patient;
    dirty[patient.id] = !fromCloud;
    return versions[patient.id] = '${++_version}';
  }

  @override
  Future<String?> updatePatient(Patient patient) async {
    if (patient.hasParseErrors || !rows.containsKey(patient.id)) return null;
    log.add('update:${patient.id}:dirty');
    rows[patient.id] = patient;
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

  @override
  Future<void> deletePatient(String id) async {
    log.add('delete:$id');
    rows.remove(id);
    dirty.remove(id);
    versions.remove(id);
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

  @override
  Future<bool> deletePatient(String patientId) async => syncResult;

  @override
  Future<List<Patient>> fetchAllPatients() async => [];
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
