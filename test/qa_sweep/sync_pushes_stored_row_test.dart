// Sync catch on #10 3227338 (attachment_swaps): a local save can be stored
// differently from the in-memory copy the provider saved (an entry whose
// local key was swapped is stored as the Storage path S). Backend's fix on
// the rebase to 3227338:
//   - the push sends only rows read from dirtyPatientsStrict(), never the
//     provider's in-memory list;
//   - markSynced gets the updatedAt of the row that was pushed;
//   - the provider refreshes the patient from the DB after each local save,
//     so the screen shows S.
// Host-only with #16's fakes (sync/cloud parked). The DB-level swap is done
// on the fake directly, standing in for the provider wiring backend adds.
//
// SYNC-01/02/03 FAIL on a8eaf9e + 3227338 (failing-first):
//   flutter test --dart-define=QA_FAILING_FIRST=true test/qa_sweep/sync_pushes_stored_row_test.dart
// SYNC-04 is a contract that must hold before and after the fix.
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../backend/fakes.dart';

const doctorA = 'doctorA';
const _uuid = '00000001-0000-4000-8000-0000000016a4';
const _s = 'clinical_attachments/$doctorA/p1/$_uuid.jpg';
const _ff = bool.fromEnvironment('QA_FAILING_FIRST');
const Object? _ffSkip = _ff
    ? null
    : 'failing-first (sync catch, 3227338): run with '
        '--dart-define=QA_FAILING_FIRST=true until the push reads '
        'dirtyPatientsStrict() and the provider refreshes after local saves';

/// Records, for every stored version, the attachment entries of that row.
class _VersionedDb extends MergeDb {
  final Map<String, List<String>> stored = {};
  final List<(String, String, bool)> marks = [];

  void _snap(String id) {
    final v = versions[id];
    final r = rows[id];
    if (v != null && r != null) {
      stored[v] = [for (final h in r.history) ...h.attachmentPaths];
    }
  }

  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) async {
    final v = await super.insertPatient(patient, fromCloud: fromCloud);
    _snap(patient.id);
    return v;
  }

  @override
  Future<String?> updatePatient(Patient patient) async {
    final v = await super.updatePatient(patient);
    _snap(patient.id);
    return v;
  }

  @override
  Future<bool> swapAttachmentPath(
      {required String expectedOwner,
      required String patientId,
      required String localPath,
      required String storagePath}) async {
    final ok = await super.swapAttachmentPath(
        expectedOwner: expectedOwner,
        patientId: patientId,
        localPath: localPath,
        storagePath: storagePath);
    _snap(patientId);
    return ok;
  }

  @override
  Future<bool> markSynced(String id, String version) async {
    final ok = await super.markSynced(id, version);
    marks.add((id, version, ok));
    return ok;
  }
}

/// CloudFirestoreHelper whose pushes can be held.
class _GatedCloud extends CloudFirestoreHelper {
  Completer<void>? gate;
  @override
  Future<bool> syncPatient(Patient patient) async {
    final g = gate;
    final r = super.syncPatient(patient); // records the payload at send time
    if (g != null) await g.future;
    return r;
  }
}

VisitRecord _visit(String id, List<String> photos) => VisitRecord(
    id: id,
    date: DateTime(2026, 1, id == 'v1' ? 2 : 3),
    visitType: 'Consultation',
    symptoms: 's',
    diagnosis: 'd',
    prescription: 'p',
    attachmentPaths: photos);

List<String> _paths(Patient p) => [for (final v in p.history) ...v.attachmentPaths];

Patient _withName(Patient p, String name) => Patient(
    id: p.id,
    name: name,
    age: p.age,
    gender: p.gender,
    phone: p.phone,
    relation: p.relation,
    updatedAt: p.updatedAt,
    history: p.history);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  late Directory root;
  late LocalPhotoStore photos;
  late _VersionedDb db;
  late _GatedCloud cloud;
  late PatientProvider provider;
  late String local;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('qa_syncrow');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    final dir = photos.visitFolderFor(doctorA)!;
    Directory(dir).createSync(recursive: true);
    local = (File(p.join(dir, '$_uuid.jpg'))
          ..writeAsBytesSync(File('test/fixtures/attachments/rot6.jpg').readAsBytesSync()))
        .path;
    db = _VersionedDb()..state = const DbReady(doctorA);
    final seed = testPatient('p1');
    db.rows['p1'] = Patient(
        id: 'p1',
        name: seed.name,
        age: seed.age,
        gender: seed.gender,
        phone: seed.phone,
        updatedAt: seed.updatedAt,
        history: [_visit('v1', [local])]);
    cloud = _GatedCloud();
    provider = PatientProvider(
        db: db,
        firestore: cloud,
        auth: FakeAuth(doctorA),
        storage: FakeStorage(),
        photos: photos,
        retryBaseDelay: const Duration(hours: 1),
        retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(doctorA);
    await flushMicrotasks();
    expect(_paths(provider.findById('p1')), [local], reason: 'precondition: memory holds L');
    // The DB-level swap (stands in for the provider's confirmed upload), then
    // F8-R1's local delete. The provider's in-memory copy still holds L.
    expect(
        await db.swapAttachmentPath(
            expectedOwner: doctorA, patientId: 'p1', localPath: local, storagePath: _s),
        isTrue);
    File(local).deleteSync();
    cloud.payloads.clear();
    db.marks.clear();
  });

  tearDown(() {
    final g = cloud.gate;
    if (g != null && !g.isCompleted) g.complete();
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  /// The rewritten save: a details edit from the in-memory copy (holds L);
  /// 3227338 stores S instead.
  Future<void> rewrittenSave() async {
    await provider.updatePatient(_withName(provider.findById('p1'), 'Asha New'));
    for (var i = 0; i < 6; i++) {
      await flushMicrotasks();
    }
    expect(_paths(db.rows['p1']!), [_s], reason: 'precondition: DB stored S (3227338 re-apply)');
    expect(db.rows['p1']!.name, 'Asha New');
  }

  String observed() =>
      'payloads=${cloud.payloads.map(_paths).toList()} marks=${db.marks} '
      'dirty=${db.dirty['p1']} memory=${_paths(provider.findById('p1'))}';

  test('SYNC-01 after a rewritten save the in-memory L copy never reaches the cloud; '
      'what is pushed is the stored row (with S)', () async {
    await rewrittenSave();
    // ignore: avoid_print
    print('SYNC-01 observed: ${observed()}');
    expect(cloud.payloads, isNotEmpty, reason: 'the save is pushed');
    for (final pl in cloud.payloads) {
      expect(_paths(pl), [_s],
          reason: 'payload built from the in-memory copy (L stripped => photo missing)');
      expect(pl.name, 'Asha New');
    }
  }, skip: _ffSkip);

  test('SYNC-02 markSynced gets the updatedAt of the pushed row (never marks S clean '
      'when S was not sent)', () async {
    await rewrittenSave();
    // ignore: avoid_print
    print('SYNC-02 observed: ${observed()}');
    final ok = db.marks.where((m) => m.$1 == 'p1' && m.$3).toList();
    if (db.dirty['p1'] == false) {
      expect(ok, isNotEmpty);
      final last = cloud.payloads.last;
      expect(db.stored[ok.last.$2], _paths(last),
          reason: 'marked clean a version whose content differs from what was pushed');
      expect(_paths(last), [_s], reason: 'row is clean but the cloud never got S');
    } else {
      fail('row still dirty after a successful push: ${observed()}');
    }
  }, skip: _ffSkip);

  test('SYNC-03 the screen shows S after the save (provider refreshed from the DB)', () async {
    await rewrittenSave();
    expect(_paths(provider.findById('p1')), [_s],
        reason: 'in-memory copy still holds the deleted local path L');
  }, skip: _ffSkip);

  test('SYNC-04 contract: a confirm for a stale updatedAt leaves the row dirty; it is '
      'never clean unless the cloud has the newest content', () async {
    cloud.gate = Completer<void>();
    unawaited(provider.updatePatient(_withName(provider.findById('p1'), 'First')));
    for (var i = 0; i < 6; i++) {
      await flushMicrotasks();
    }
    final firstVersion = db.versions['p1'];
    await db.updatePatient(_withName(db.rows['p1']!, 'Second')); // newer local edit
    expect(db.versions['p1'], isNot(firstVersion));
    cloud.gate!.complete();
    for (var i = 0; i < 6; i++) {
      await flushMicrotasks();
    }
    // ignore: avoid_print
    print('SYNC-04 observed: ${observed()}');
    expect(db.marks.where((m) => m.$2 == firstVersion && m.$3), isEmpty,
        reason: 'stale version confirmed clean');
    expect(db.dirty['p1'], isTrue, reason: 'newer edit must stay dirty until pushed');
    expect(await db.markSynced('p1', firstVersion!), isFalse);
    expect(db.dirty['p1'], isTrue);
  });
}
