// QA failing-first regression cases for the DB engineer's audit (07:46).
// Backend is fixing these on top of #10 9a8d31b. Each case uses the fake's
// `strictReadFailure`; _RealLikeDb adds what the real DatabaseHelper does
// on a failed read and the fake does not: the LENIENT reads (fetchPatients,
// dirtyPatients, pendingDeletes) return [] instead of their data.
//
// Expected on qa-merged4 (#10 9a8d31b + #13 0e65128 + #16 a8eaf9e):
//   A1a/A1b PASS (already fixed on a8eaf9e: fresh DB scan, fail closed)
//   A2, A3, A4, A5 FAIL until backend's fix lands (failing-first).
// `loadFailed` does not exist yet; it is read dynamically so the file
// compiles today (NoSuchMethodError = not implemented yet).
// Sync is Firebase (parked): fakes only, host unit tests.
import 'dart:convert';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../backend/fakes.dart';
import 'support/strict_read_names.dart';

const doctorA = 'doctorA';

/// Failing-first cases run only with --dart-define=QA_FAILING_FIRST=true
/// until backend's audit fix lands; then drop the gate (skip: null).
const _ff = bool.fromEnvironment('QA_FAILING_FIRST');
const Object? _ffSkip = _ff
    ? null
    : 'failing-first (DB audit 07:46): run with '
        '--dart-define=QA_FAILING_FIRST=true until backend fix lands';

/// MergeDb plus the real DB's lenient-read behaviour on failure.
class _RealLikeDb extends MergeDb {
  bool get _failing => strictReadFailure != null;
  bool scanFails = false;
  bool settingReadFails = false;
  int dirtyStrictCalls = 0;
  int pendingStrictCalls = 0;
  int fetchStrictCalls = 0;

  @override
  Future<List<Patient>> fetchPatients() async =>
      _failing ? <Patient>[] : super.fetchPatients();
  @override
  Future<List<Patient>> dirtyPatients() async =>
      _failing ? <Patient>[] : super.dirtyPatients();
  @override
  Future<List<String>> pendingDeletes() async =>
      _failing ? <String>[] : super.pendingDeletes();
  @override
  Future<List<Patient>> fetchPatientsStrict() {
    fetchStrictCalls++;
    return super.fetchPatientsStrict();
  }

  @override
  Future<List<Patient>> dirtyPatientsStrict() {
    dirtyStrictCalls++;
    return super.dirtyPatientsStrict();
  }

  @override
  Future<List<String>> pendingDeletesStrict() {
    pendingStrictCalls++;
    return super.pendingDeletesStrict();
  }

  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    if (scanFails || _failing) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.readFailed);
    }
    return super.referencedAttachmentKeys();
  }

  @override
  Future<String?> getSetting(String key) async {
    if (settingReadFails) throw qaReadException(QaReadFailure.readFailed);
    return super.getSetting(key);
  }
}

String _uuidName(int i) =>
    '${i.toRadixString(16).padLeft(8, '0')}-0000-4000-8000-0000000a0d17.jpg';

VisitRecord _v(String id, {List<String> photos = const [], String dx = 'd'}) =>
    VisitRecord(
        id: id,
        date: DateTime(2026, 1, 2),
        visitType: 'Consultation',
        symptoms: 's',
        diagnosis: dx,
        prescription: 'p',
        attachmentPaths: photos);

Patient _pt(String id, List<VisitRecord> h, {String name = 'Asha'}) =>
    Patient(
        id: id,
        name: name,
        age: '40',
        gender: 'Female',
        phone: '+9100001',
        updatedAt: '2026-01-02T00:00:00.000',
        history: h);

/// Reads `loadFailed` without a compile-time dependency (not pushed yet).
bool? _loadFailed(PatientProvider pp) {
  try {
    return (pp as dynamic).loadFailed as bool;
  } on NoSuchMethodError {
    return null;
  }
}

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _RealLikeDb db;
  late CloudFirestoreHelper remote;
  late PatientProvider pp;

  PatientProvider build(
          {Duration retry = const Duration(milliseconds: 40),
          bool cloud = true}) =>
      PatientProvider(
          db: db,
          cloudSync: cloud,
          firestore: remote,
          auth: FakeAuth(doctorA),
          storage: FakeStorage(),
          photos: photos,
          retryBaseDelay: retry,
          retryMaxDelay: retry);

  String photo(int i) {
    final dir = photos.visitFolderFor(doctorA)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, _uuidName(i)))..writeAsBytesSync([1, 2, 3])).path;
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('qa_audit');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _RealLikeDb()..state = const DbReady(doctorA);
    remote = CloudFirestoreHelper();
  });

  tearDown(() {
    pp.dispose();
    root.deleteSync(recursive: true);
  });

  group('A1 provider photo cleanup decides "still used" from the DB', () {
    test('A1a stale memory: a row written after load still protects the photo',
        () async {
      final a = photo(1);
      db.rows['p1'] = _pt('p1', [_v('v1', photos: [a])]);
      pp = build(cloud: false);
      await pp.loadAndSync(doctorA);
      // Written behind the provider's back (another path, after load).
      db.rows['p2'] = _pt('p2', [_v('w1', photos: [a])], name: 'Other');
      await pp.deleteRecord('p1', 'v1');
      await flushMicrotasks();
      expect(File(a).existsSync(), isTrue,
          reason: 'DATA LOSS: p2 (in the DB, not in memory) still uses it');
    });

    test('A1b scan fails (strict read failure): cleanup deletes nothing',
        () async {
      final a = photo(2);
      db.rows['p1'] = _pt('p1', [_v('v1', photos: [a])]);
      pp = build(cloud: false);
      await pp.loadAndSync(doctorA);
      db.strictReadFailure = QaReadFailure.readFailed;
      db.scanFails = true;
      await pp.deleteRecord('p1', 'v1');
      await flushMicrotasks();
      expect(File(a).existsSync(), isTrue);
    });
  });

  test('A2-control readable dirty row is pushed by retryDirty', () async {
    db.rows['p1'] = _pt('p1', [_v('v1')]);
    pp = build();
    await pp.loadAndSync(doctorA);
    await flushMicrotasks();
    remote.payloads.clear();
    db.dirty['p1'] = true;
    await pp.retryDirty();
    await flushMicrotasks();
    expect(remote.payloads.map((p) => p.id), contains('p1'));
  });

  test('A3-control readable tombstone is pushed by retryDirty', () async {
    db.rows['p1'] = _pt('p1', [_v('v1')]);
    pp = build();
    await pp.loadAndSync(doctorA);
    await flushMicrotasks();
    db.rows.remove('p1');
    db.tombstones.add('p1');
    await pp.retryDirty();
    await flushMicrotasks();
    expect(remote.deletes, contains('p1'));
  });

  test('A2 dirty rows unreadable: nothing pushed AND the retry stays pending',
      () async {
    db.rows['p1'] = _pt('p1', [_v('v1')]);
    pp = build();
    await pp.loadAndSync(doctorA);
    await flushMicrotasks();
    remote.payloads.clear();
    db.dirty['p1'] = true;
    db.strictReadFailure = QaReadFailure.readFailed;
    await pp.retryDirty();
    expect(remote.payloads, isEmpty);
    // DB recovers; no new trigger from the app. The pending retry must push.
    db.strictReadFailure = null;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await flushMicrotasks();
    expect(remote.payloads.map((p) => p.id), contains('p1'),
        reason: 'retry was reset after an unreadable dirty list');
    expect(db.dirtyStrictCalls, greaterThan(0),
        reason: 'must use dirtyPatientsStrict()');
  }, skip: _ffSkip);

  test('A3 tombstones unreadable: not reported as success, keeps retrying',
      () async {
    db.rows['p1'] = _pt('p1', [_v('v1')]);
    pp = build();
    await pp.loadAndSync(doctorA);
    await flushMicrotasks();
    db.rows.remove('p1');
    db.tombstones.add('p1');
    db.strictReadFailure = QaReadFailure.readFailed;
    await pp.retryDirty();
    expect(remote.deletes, isEmpty);
    db.strictReadFailure = null;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await flushMicrotasks();
    expect(remote.deletes, contains('p1'),
        reason: 'pending delete dropped: [] was treated as "nothing left"');
    expect(db.tombstones, isNot(contains('p1')));
    expect(db.pendingStrictCalls, greaterThan(0),
        reason: 'must use pendingDeletesStrict()');
  }, skip: _ffSkip);

  group('A4 load read fails: no merge, loadFailed, clean rows kept', () {
    // Clean local row with 2 visits; stale cloud copy with 1. The merge
    // rule ("cloud wins if new or has more visits") keeps local on a good
    // read; on a read that looks empty, every cloud patient looks new.
    setUp(() {
      db.rows['p1'] = _pt('p1', [_v('v1'), _v('v2', dx: 'LOCAL-ONLY')]);
      remote.cloud = [
        _pt('p1', [_v('v1')])
      ];
    });

    test('A4-control good read: local kept (premise of A4)', () async {
      pp = build();
      await pp.loadAndSync(doctorA);
      await flushMicrotasks();
      expect(db.rows['p1']!.history.length, 2);
    });

    test('A4 failed read: merge skipped, row intact, loadFailed set',
        () async {
      db.strictReadFailure = QaReadFailure.readFailed;
      pp = build();
      await pp.loadAndSync(doctorA);
      await flushMicrotasks();
      expect(db.rows['p1']!.history.length, 2,
          reason: 'DATA LOSS: clean row replaced by the stale cloud copy');
      expect(db.applyLog, isEmpty, reason: 'merge ran after a failed read');
      expect(remote.fetches, 0, reason: 'cloud pull must be skipped');
      expect(_loadFailed(pp), isTrue,
          reason: 'loadFailed not set (null = not implemented yet)');
      expect(db.fetchStrictCalls, greaterThan(0),
          reason: 'must use fetchPatientsStrict()');
    }, skip: _ffSkip);
  });

  group('A5 medicines: a failed load never overwrites the stored list', () {
    test('A5-control good load: the add appends to the stored list', () async {
      db.settings[MedicineProvider.localSettingKey] = jsonEncode(['Paracetamol 500']);
      final meds = MedicineProvider(
          firestore: FakeFirestore(),
          auth: FakeAuth(doctorA),
          cloudSync: false,
          localDb: db);
      pp = build();
      await meds.load(doctorA);
      await meds.addMedicineIfNew('Azithromycin 500');
      expect(jsonDecode(db.settings[MedicineProvider.localSettingKey]!),
          ['Paracetamol 500', 'Azithromycin 500']);
      meds.dispose();
    });

    test('A5 local: getSetting fails, then addMedicineIfNew', () async {
      const stored = ['Paracetamol 500', 'Metformin 500', 'Amlodipine 5'];
      db.settings[MedicineProvider.localSettingKey] = jsonEncode(stored);
      db.settingReadFails = true;
      final meds = MedicineProvider(
          firestore: FakeFirestore(),
          auth: FakeAuth(doctorA),
          cloudSync: false,
          localDb: db);
      pp = build();
      await meds.load(doctorA);
      await meds.addMedicineIfNew('Azithromycin 500');
      expect(jsonDecode(db.settings[MedicineProvider.localSettingKey]!),
          containsAll(stored),
          reason: 'DATA LOSS: stored list replaced by a one-item list');
      meds.dispose();
    }, skip: _ffSkip);
  });
}
