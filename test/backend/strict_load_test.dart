// Strict patient load and the loadFailed contract (security, #16):
// - PatientProvider loads through a strict read and exposes loadFailed,
//   loadFailure (reason enum only) and reload();
// - a failed reload keeps the list only for the same owner; a session end
//   or owner change clears the list and the failed state;
// - while loadFailed, every patient/visit write and delete is refused with
//   SaveRefusedException, nothing is synced and no photo is deleted;
// - the startup sweep skips while loadFailed is true when it runs.
// Runs in both suite modes: cloudSync: false is injected; nothing depends
// on the define.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/providers/strict_patient_read.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/patient_load_status.dart';
import 'package:docease/services/photo_sweep.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';

/// A DB with #10's strict read (interim interface) that can be made to fail,
/// and that counts writes so "refused" can be checked as "nothing written".
class _StrictDb extends FakeLocalDatabase implements StrictPatientReads {
  PatientReadFailure? failWith;
  Object? scanFailWith;
  int scans = 0;
  int strictReads = 0;
  int writes = 0;

  @override
  Future<List<Patient>> fetchPatientsStrict() async {
    strictReads++;
    final f = failWith;
    if (f != null) throw PatientReadIncomplete(f);
    return rows.values.toList();
  }

  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) {
    writes++;
    return super.insertPatient(patient, fromCloud: fromCloud);
  }

  @override
  Future<String?> updatePatient(Patient patient) {
    writes++;
    return super.updatePatient(patient);
  }

  @override
  Future<void> markPendingDelete(String id) {
    writes++;
    return super.markPendingDelete(id);
  }

  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    scans++;
    final f = scanFailWith;
    if (f != null) throw f;
    return super.referencedAttachmentKeys();
  }
}

/// No strict read: the provider's interim path (fetchPatients() plus the
/// unsynced-counter cross-check on an empty result).
class _LegacyDb extends FakeLocalDatabase {
  bool fetchReturnsEmpty = false;
  bool countUnknown = false;
  @override
  Future<List<Patient>> fetchPatients() async => fetchReturnsEmpty ? [] : super.fetchPatients();
  @override
  Future<UnsyncedCount> unsyncedCount() async => countUnknown ? UnsyncedCount.unknown : super.unsyncedCount();
}

const doctorA = 'doctorA';
const doctorB = 'doctorB';

VisitRecord visit(String id, List<String> photos) => VisitRecord(
    id: id,
    date: DateTime(2026, 1, 2),
    visitType: 'Consultation',
    symptoms: 'cough',
    diagnosis: 'cold',
    prescription: 'rest',
    attachmentPaths: photos);

Patient patient(String id, [List<VisitRecord> history = const []]) => Patient(
    id: id, name: 'Asha $id', age: '30', gender: 'Female', phone: '+91999$id', history: history);

/// App-generated name (`<uuid v4>.<ext>`) standing for [label].
String n(String label) {
  final h = sha256.convert(utf8.encode(label)).toString();
  final ext = label.substring(label.lastIndexOf('.') + 1);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}.$ext';
}

/// Sorted patient ids joined with ',' (records compare lists by identity).
String ids(PatientProvider provider) => (provider.patients.map((p) => p.id).toList()..sort()).join(',');

Matcher refused(PatientSaveOperation op, PatientReadFailure reason) => throwsA(isA<SaveRefusedException>()
    .having((e) => e.operation, 'operation', op)
    .having((e) => e.error, 'error', isA<PatientReadIncomplete>().having((e) => e.reason, 'reason', reason)));

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _StrictDb db;
  late PatientLoadStatus status;
  late int notified;

  PatientProvider make({LocalDatabase? database}) {
    final provider = PatientProvider(
        db: database ?? db, cloudSync: false, photos: photos, loadStatus: status);
    provider.addListener(() => notified++);
    return provider;
  }

  String photo(String owner, String label) {
    final dir = photos.visitFolderFor(owner)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, n(label)))..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9])).path;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_strict');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _StrictDb()..state = const DbReady(doctorA);
    status = PatientLoadStatus();
    notified = 0;
  });

  tearDown(() => root.deleteSync(recursive: true));

  group('strict load: loadFailed, loadFailure, reload()', () {
    test('a failed first load leaves the list empty, sets loadFailed and notifies', () async {
      db.rows['p1'] = patient('p1');
      db.failWith = PatientReadFailure.readFailed;
      final provider = make();
      await provider.loadAndSync(doctorA);
      expect(provider.patients, isEmpty);
      expect(provider.loadFailed, isTrue);
      expect(provider.loadFailure, PatientReadFailure.readFailed);
      expect(notified, greaterThan(0));
      expect(status.isFailed(doctorA), isTrue);
      provider.dispose();
    });

    test('a failed reload keeps the previously loaded list unchanged', () async {
      db.rows['p1'] = patient('p1');
      final provider = make();
      await provider.loadAndSync(doctorA);
      expect((ids(provider), provider.loadFailed), ('p1', false));
      final before = notified;
      db.rows['p2'] = patient('p2');
      db.failWith = PatientReadFailure.unreadableRow;
      await provider.reload();
      expect(ids(provider), 'p1', reason: 'never replaced with []');
      expect(provider.loadFailed, isTrue);
      expect(provider.loadFailure, PatientReadFailure.unreadableRow);
      expect(notified, greaterThan(before));
      provider.dispose();
    });

    test('a successful reload replaces the list and clears loadFailed', () async {
      db.failWith = PatientReadFailure.readFailed;
      final provider = make();
      await provider.loadAndSync(doctorA);
      expect(provider.loadFailed, isTrue);
      db.failWith = null;
      db.rows['p1'] = patient('p1');
      final before = notified;
      await provider.reload();
      expect(ids(provider), 'p1');
      expect(provider.loadFailed, isFalse);
      expect(provider.loadFailure, isNull);
      expect(notified, greaterThan(before));
      expect(status.isLoaded(doctorA), isTrue);
      provider.dispose();
    });

    test('reload() shares a load that is still running', () async {
      final provider = make();
      final first = provider.loadAndSync(doctorA);
      final second = provider.reload();
      await Future.wait([first, second]);
      expect(db.strictReads, 1);
      await provider.reload();
      expect(db.strictReads, 2, reason: 'a finished load is read again');
      provider.dispose();
    });

    test('interim path (no strict read yet): [] with an unreadable counter is a failed load', () async {
      final legacy = _LegacyDb()..state = const DbReady(doctorA);
      legacy.rows['p1'] = patient('p1');
      final provider = make(database: legacy);
      await provider.loadAndSync(doctorA);
      expect((ids(provider), provider.loadFailed), ('p1', false));
      legacy
        ..fetchReturnsEmpty = true
        ..countUnknown = true;
      await provider.reload();
      expect((ids(provider), provider.loadFailed, provider.loadFailure), ('p1', true, PatientReadFailure.readFailed));
      legacy.countUnknown = false; // a genuinely empty, readable DB
      await provider.reload();
      expect((ids(provider), provider.loadFailed), ('', false));
      provider.dispose();
    });

    test('loadFailure and the refusal carry the reason only, never patient data', () async {
      db.rows['p1'] = patient('p1');
      final provider = make();
      await provider.loadAndSync(doctorA);
      db.failWith = PatientReadFailure.readFailed;
      await provider.reload();
      Object? error;
      try {
        await provider.addPatient(patient('p9'));
      } catch (e) {
        error = e;
      }
      final text = '$error ${provider.loadFailure}';
      expect(text, contains('PatientReadIncomplete'));
      for (final leak in ['Asha', '+91999', 'p1', 'p9', doctorA]) {
        expect(text, isNot(contains(leak)));
      }
      provider.dispose();
    });
  });

  group('while loadFailed every write and delete is refused', () {
    late PatientProvider provider;
    late String a;

    setUp(() async {
      a = photo(doctorA, 'a.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a])]);
      provider = make();
      await provider.loadAndSync(doctorA);
      db.failWith = PatientReadFailure.readFailed;
      await provider.reload();
      expect(provider.loadFailed, isTrue);
      db.writes = 0;
    });

    tearDown(() => provider.dispose());

    test('addPatient: no duplicate can be created after a failed load', () async {
      await expectLater(provider.addPatient(patient('p1')), refused(PatientSaveOperation.add, PatientReadFailure.readFailed));
      expect(ids(provider), 'p1');
    });

    test('updatePatient, deletePatient, addRecord, updateRecord, deleteRecord', () async {
      final p1 = provider.findById('p1');
      await expectLater(provider.updatePatient(patient('p1')), refused(PatientSaveOperation.update, PatientReadFailure.readFailed));
      await expectLater(provider.deletePatient('p1'), refused(PatientSaveOperation.delete, PatientReadFailure.readFailed));
      await expectLater(provider.addRecord('p1', visit('v2', const [])), refused(PatientSaveOperation.addVisit, PatientReadFailure.readFailed));
      await expectLater(provider.updateRecord('p1', visit('v1', const [])), refused(PatientSaveOperation.updateVisit, PatientReadFailure.readFailed));
      await expectLater(provider.deleteRecord('p1', 'v1'), refused(PatientSaveOperation.deleteVisit, PatientReadFailure.readFailed));
      expect(db.writes, 0, reason: 'nothing reached the DB');
      expect(identical(provider.findById('p1'), p1), isTrue, reason: 'memory untouched');
      expect(db.rows['p1']!.history.single.attachmentPaths, [a]);
      expect(File(a).existsSync(), isTrue, reason: 'no photo cleanup while loadFailed');
    });

    test('a write queued behind the failure is refused when it runs; a good reload allows writes again', () async {
      db.failWith = null;
      await provider.reload();
      expect(provider.loadFailed, isFalse);
      await provider.deleteRecord('p1', 'v1');
      expect(db.rows['p1']!.history, isEmpty);
      expect(File(a).existsSync(), isFalse, reason: 'cleanup runs again once loaded');
    });

    test('source pins: refusal re-checked before the visit write; cleanup and sync gated', () {
      final s = File('lib/providers/patient_provider.dart').readAsStringSync();
      expect(s, contains('final refusedNow = _loadRefusal(operation); // a reload failed meanwhile'));
      expect(s, contains("debugPrint('Photos: cleanup skipped (loadFailed)');"));
      expect(s, contains('if (_loadFailed) return Future.value(); // reload() syncs once the list is good'));
      expect(s, contains('if (!_dbReadyFor(uid) || _loadFailed) return;'));
    });
  });

  group('the old list is kept only for the same owner', () {
    test('owner change clears the list and loadFailed, even while loadFailed is true', () async {
      db.rows['p1'] = patient('p1');
      final provider = make();
      await provider.loadAndSync(doctorA);
      db.failWith = PatientReadFailure.readFailed;
      await provider.reload();
      expect((ids(provider), provider.loadFailed), ('p1', true));

      // doctorB's DB is not open yet: the list goes at once.
      final before = notified;
      await provider.loadAndSync(doctorB);
      expect(provider.patients, isEmpty);
      expect(provider.loadFailed, isFalse);
      expect(provider.loadFailure, isNull);
      expect(notified, greaterThan(before));
      expect(status.isFailed(doctorA), isFalse);

      // doctorB's DB opens but its first load fails: still never doctorA's list.
      db
        ..state = const DbReady(doctorB)
        ..failWith = PatientReadFailure.readFailed;
      await provider.reload();
      expect(provider.patients, isEmpty);
      expect(provider.loadFailed, isTrue);
      expect(status.isFailed(doctorB), isTrue);

      db
        ..rows.clear()
        ..rows['b1'] = patient('b1')
        ..failWith = null;
      await provider.reload();
      expect((ids(provider), provider.loadFailed), ('b1', false));
      provider.dispose();
    });

    test('owner change straight into a failing load shows nothing of the old owner', () async {
      db.rows['p1'] = patient('p1');
      final provider = make();
      await provider.loadAndSync(doctorA);
      db
        ..state = const DbReady(doctorB)
        ..failWith = PatientReadFailure.notOpen;
      await provider.loadAndSync(doctorB);
      expect(provider.patients, isEmpty);
      expect((provider.loadFailed, provider.loadFailure), (true, PatientReadFailure.notOpen));
      provider.dispose();
    });

    test('session end (clear) resets the list and loadFailed', () async {
      db.rows['p1'] = patient('p1');
      final provider = make();
      await provider.loadAndSync(doctorA);
      db.failWith = PatientReadFailure.readFailed;
      await provider.reload();
      expect(provider.loadFailed, isTrue);
      provider.clear();
      expect(provider.patients, isEmpty);
      expect((provider.loadFailed, provider.loadFailure), (false, null));
      expect(status.isFailed(doctorA), isFalse);
      provider.dispose();
    });
  });

  group('startup sweep and loadFailed (defence in depth)', () {
    late String orphan;
    DateTime later() => DateTime.now().add(const Duration(hours: 1));
    PhotoSweep sweep() => PhotoSweep(db: db, photos: photos, now: later, loadStatus: status);

    setUp(() {
      db.state = const DbReady(kLocalOwnerId);
      orphan = photo(kLocalOwnerId, 'orphan.jpg');
    });

    test('loadFailed is read when the sweep runs, not when it is created', () async {
      final s = sweep(); // created while nothing is failed
      status.failed(kLocalOwnerId);
      final logs = <String>[];
      final r = await captureLogs(logs, () => s.sweep(kLocalOwnerId));
      expect((r.ran, r.reason), (false, 'loadFailed'));
      expect(logs, ['Photos: sweep skipped (loadFailed)']);
      expect(File(orphan).existsSync(), isTrue);
      expect(db.scans, 0, reason: 'skipped before the scan starts');

      status.loaded(kLocalOwnerId);
      final again = await s.sweep(kLocalOwnerId);
      expect((again.ran, again.removed), (true, 1));
    });

    test('it does not need the provider: no load status at all, and another owner\'s failure, still sweep', () async {
      status.failed(doctorB);
      final r = await sweep().sweep(kLocalOwnerId);
      expect((r.ran, r.removed), (true, 1));
    });

    test('its own fresh scan still fails closed while the provider looks loaded', () async {
      status.loaded(kLocalOwnerId);
      db.scanFailWith = const AttachmentScanIncomplete(AttachmentScanFailure.unrecognisedPath);
      final logs = <String>[];
      final r = await captureLogs(logs, () => sweep().sweep(kLocalOwnerId));
      expect(r.ran, isFalse);
      expect(logs, ['Photos: sweep skipped (unrecognisedPath)']);
      expect(File(orphan).existsSync(), isTrue);
    });

    test('QA: the skip log is the AttachmentScanFailure name wherever the failure surfaces', () async {
      for (final reason in AttachmentScanFailure.values) {
        expect(PhotoSweep.skipReason(AttachmentScanIncomplete(reason)), reason.name);
      }
      expect(PhotoSweep.skipReason(StateError('/data/user/0/x/attachments/secret.jpg')), 'StateError');
      final throwing = _ThrowingOpenUidDb()..state = const DbReady(kLocalOwnerId);
      final logs = <String>[];
      final r = await captureLogs(logs, () => PhotoSweep(db: throwing, photos: photos, now: later).sweep(kLocalOwnerId));
      expect(r.reason, 'unrecognisedPath');
      expect(logs, ['Photos: sweep skipped (unrecognisedPath)']);
    });

    test('the app wiring: PatientProvider() and PhotoSweep.forApp() share PatientLoadStatus.instance', () {
      final provider = File('lib/providers/patient_provider.dart').readAsStringSync();
      expect(provider, contains('_loadStatus = loadStatus ?? (db == null ? PatientLoadStatus.instance : null),'));
      final sweepSrc = File('lib/services/photo_sweep.dart').readAsStringSync();
      expect(sweepSrc, contains('PhotoSweep(db: DatabaseHelper.instance, loadStatus: PatientLoadStatus.instance);'));
      expect(sweepSrc, isNot(contains('settled(')), reason: 'never waits on the provider');
    });
  });
}

/// A scan failure surfacing outside the scan's own catch (here: the open
/// owner check) must still be logged by its reason name.
class _ThrowingOpenUidDb extends FakeLocalDatabase {
  @override
  String? get openUid => throw const AttachmentScanIncomplete(AttachmentScanFailure.unrecognisedPath);
}
