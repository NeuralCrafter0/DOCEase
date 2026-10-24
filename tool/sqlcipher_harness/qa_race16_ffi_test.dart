// Real SQLCipher via FFI + the real PatientProvider: security L-3 on
// #10 b217f46 (Low for #16). A removed photo must stay removed when a
// stale visit save (form still holding the pre-upload local path L) is
// queued around the removal save, in both orders.
//
// Run: QA_FFI_TEST=qa_race16_ffi_test.dart bash tool/sqlcipher_harness/run_qa.sh
// Env: QA_RACE_LOOPS (default 20).
//
// RACE-01/02 assert the end state through the provider (per-patient lock).
// On #16's next head, updateRecord reads swappedPathsFor + the stored row
// INSIDE the lock; the mutation check is tool/qa_mutations/hoist_spf_outside_lock.py
// (moves that read before the lock) and RACE-01/02 must then fail.
// RACE-CTRL is a positive control that runs today: it does what the bad
// design does (read swappedPathsFor, let the removal land, patch the old
// copy, save it) and must observe the revival, proving the detector works.
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'backend/fakes.dart';
import 'qa_sweep_ffi_test.dart' show RecOpener;
import 'sqlcipher_ffi_test.dart' show MemKeys;

const uidA = 'doctorA';
const u1 = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
// Failing-first on b217f46/#13 7c3ee41 (_syncOne upload rewrite saves a
// whole-row copy OUTSIDE the per-patient _historyChain): QA_FAILING_FIRST=true.
final int loops = int.tryParse(Platform.environment['QA_RACE_LOOPS'] ?? '') ?? 20;
String storageOf(String u, {String pid = 'p1'}) => 'clinical_attachments/$uidA/$pid/$u.jpg';

/// Adds a seeded 0-3 ms delay before the reads/writes that race.
class _JitterDb extends DatabaseHelper {
  _JitterDb(this.rnd, {required super.keyStore, required super.opener, required super.databasesPath});
  final Random rnd;
  Future<void> _j() => Future<void>.delayed(Duration(microseconds: rnd.nextInt(3000)));
  @override
  Future<String?> updatePatient(Patient patient) async {
    await _j();
    return super.updatePatient(patient);
  }
  @override
  Future<Map<String, String>> swappedPathsFor(
      {required String expectedOwner, required String patientId}) async {
    await _j();
    final m = await super.swappedPathsFor(expectedOwner: expectedOwner, patientId: patientId);
    await _j();
    return m;
  }
}

VisitRecord visit(String id, List<String> paths, {String diagnosis = 'd'}) => VisitRecord(
    id: id, date: DateTime(2026, 3, 1), visitType: 'Follow-up',
    symptoms: 's', diagnosis: diagnosis, prescription: 'rx', attachmentPaths: paths);

class _World {
  late Directory tmp;
  late _JitterDb db;
  late LocalPhotoStore photos;
  late FakeStorage storage;
  late PatientProvider provider;
  late String local; // L
  final String s = storageOf(u1); // S

  Future<void> boot(int seed, {required bool deleteLocal, bool swapped = true}) async {
    tmp = Directory.systemTemp.createTempSync('qa_race16_');
    Directory(p.join(tmp.path, 'db')).createSync();
    final support = Directory(p.join(tmp.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    final dir = photos.visitFolderFor(uidA)!;
    Directory(dir).createSync(recursive: true);
    local = (File(p.join(dir, '$u1.jpg'))..writeAsBytesSync(List.filled(64, 7))).path;
    db = _JitterDb(Random(seed),
        keyStore: MemKeys(), opener: RecOpener(), databasesPath: () async => p.join(tmp.path, 'db'));
    await db.openFor(uidA);
    await db.insertPatient(Patient(
        id: 'p1', name: 'Asha', age: '30', gender: 'Female', phone: '',
        history: [visit('v1', swapped ? [local] : const [])]));
    if (!swapped) {
      await _boot2();
      return;
    }
    // The upload was confirmed: row -> S, mapping L -> S, local copy deleted.
    expect(await db.swapAttachmentPath(
        expectedOwner: uidA, patientId: 'p1', localPath: local, storagePath: s), isTrue);
    if (deleteLocal) File(local).deleteSync();
    await _boot2();
  }

  Future<void> _boot2() async {
    storage = FakeStorage();
    provider = PatientProvider(
        db: db,
        firestore: CloudFirestoreHelper(),
        auth: FakeAuth(uidA),
        storage: storage,
        photos: photos,
        retryBaseDelay: const Duration(hours: 1),
        retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(uidA);
  }

  Future<List<String>> storedV1() async => (await db.fetchPatientsStrict())
      .singleWhere((x) => x.id == 'p1')
      .history
      .singleWhere((v) => v.id == 'v1')
      .attachmentPaths;

  Future<List<String>> pushedPaths() async => [
        for (final pt in await db.dirtyPatientsStrict())
          for (final v in pt.history) ...v.attachmentPaths
      ];

  Future<void> dispose() async {
    provider.dispose();
    try {
      await db.close();
    } catch (_) {}
    tmp.deleteSync(recursive: true);
  }
}

Future<Object?> _settle(Future<void> f) => f.then<Object?>((_) => null, onError: (Object e) => e);

// L-1 (security 3a695b0 review): failing-first until #16 accepts only this
// session's picks. Run with QA_FAILING_FIRST=true to see them fail today.
final bool _ffL1 = Platform.environment['QA_FAILING_FIRST'] == 'true';
const _l1Why = 'L-1 (security #16 3a695b0, CONFIRMED): a stale form re-adds a removed photo whose '
    'local copy is still on disk (re-uploaded under a new name); QA_FAILING_FIRST=true until fixed';

/// Any photo at all in v1 after a removal (security L-1: the old detector only
/// looked for the original Storage name / file id).
bool _anyStorage(List<String> got) => got.any((e) => e.startsWith('clinical_attachments/'));

void main() {
  for (final deleteLocal in [true, false]) {
    final variant = deleteLocal ? 'local copy deleted' : 'local copy still on disk';

    test('RACE-01 [$variant] removal queued FIRST, stale save second, x$loops: '
        'S never comes back, never pushed, never re-uploaded', () async {
      final revived = <int>[], danglingL = <int>[], reuploads = <int>[];
      for (var i = 0; i < loops; i++) {
        final w = _World();
        await w.boot(i, deleteLocal: deleteLocal);
        try {
          final removal = w.provider.updateRecord('p1', visit('v1', const []));
          final stale = w.provider.updateRecord('p1', visit('v1', [w.local], diagnosis: 'stale edit'));
          await _settle(removal);
          await _settle(stale);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final got = await w.storedV1();
          final pushed = await w.pushedPaths();
          if (_anyStorage(got) || _anyStorage(pushed)) revived.add(i);
          if (got.any((e) => !e.startsWith('clinical_attachments/'))) danglingL.add(i);
          if (w.storage.uploads.isNotEmpty) reuploads.add(i); // ANY upload (L-1)
        } finally {
          await w.dispose();
        }
      }
      // ignore: avoid_print
      print('RACE-01 [$variant] observed: revived=$revived danglingL=$danglingL reuploads=$reuploads');
      expect(revived, isEmpty, reason: 'removed photo came back as S');
      expect(reuploads, isEmpty, reason: 'removed photo was uploaded again');
      expect(danglingL, isEmpty, reason: 'removed photo came back as its local path');
    }, skip: !deleteLocal && !_ffL1 ? _l1Why : null);

    test('RACE-02 [$variant] stale save queued FIRST, removal second, x$loops: '
        'ends with no photo', () async {
      final bad = <int, List<String>>{};
      for (var i = 0; i < loops; i++) {
        final w = _World();
        await w.boot(1000 + i, deleteLocal: deleteLocal);
        try {
          final stale = w.provider.updateRecord('p1', visit('v1', [w.local], diagnosis: 'stale edit'));
          final removal = w.provider.updateRecord('p1', visit('v1', const []));
          await _settle(stale);
          final err = await _settle(removal);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final got = await w.storedV1();
          if (got.isNotEmpty || err != null || _anyStorage(await w.pushedPaths()) ||
              w.storage.uploads.isNotEmpty) {
            bad[i] = [...got, if (err != null) 'removal error: ${err.runtimeType}'];
          }
        } finally {
          await w.dispose();
        }
      }
      // ignore: avoid_print
      print('RACE-02 [$variant] observed bad=$bad');
      expect(bad, isEmpty, reason: 'the later removal must win and succeed');
    });
  }


  // RACE-04 (QA, 3a695b0): no race at all - the removal has COMPLETED, then
  // a form opened before it is saved. Pins the second layer, the "a form can
  // keep a cloud reference, never introduce one" guard in updateRecord, which
  // the jittered races above cannot reach once the strict reads sit under the
  // per-patient lock (QA mutation `guard` passed RACE-01..03; only backend's
  // stale_visit_form_test caught it).
  for (final (holds, onDisk) in [('S', false), ('L', false), ('L', true)]) {
    test('RACE-04 [form holds $holds${onDisk ? ', file on disk' : ''}] removal completed, then the stale form is saved: '
        'S is not reintroduced, never pushed', () async {
      final w = _World();
      await w.boot(4242, deleteLocal: !onDisk);
      try {
        await w.provider.updateRecord('p1', visit('v1', const []));
        expect(await w.storedV1(), isEmpty, reason: 'precondition: removal saved');
        final formPath = holds == 'S' ? w.s : w.local;
        final err = await _settle(
            w.provider.updateRecord('p1', visit('v1', [formPath], diagnosis: 'stale edit')));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final got = await w.storedV1();
        // ignore: avoid_print
        print('RACE-04 [$holds] observed: stored=$got err=${err?.runtimeType}');
        expect(got, isEmpty, reason: 'stale form brought the removed photo back (any name)');
        expect(_anyStorage(await w.pushedPaths()), isFalse);
        expect(w.storage.uploads.keys, isEmpty, reason: 'no new Storage object at all (L-1)');
      } finally {
        await w.dispose();
      }
    }, skip: onDisk && !_ffL1 ? _l1Why : null);
  }

  test('RACE-03 a NEW photo removed while its upload rewrite is pending, x$loops: '
      'stays removed in the DB, in memory, and in what is pushed', () async {
    final bad = <int, String>{};
    for (var i = 0; i < loops; i++) {
      final w = _World();
      await w.boot(3000 + i, deleteLocal: false, swapped: false);
      try {
        await w.provider.updateRecord('p1', visit('v1', [w.local])); // starts upload + rewrite
        final removal = w.provider.updateRecord('p1', visit('v1', const []));
        final err = await _settle(removal);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final got = await w.storedV1();
        final mem = w.provider.patients.singleWhere((x) => x.id == 'p1')
            .history.singleWhere((v) => v.id == 'v1').attachmentPaths;
        final pushed = await w.pushedPaths();
        if (got.isNotEmpty || err != null || pushed.isNotEmpty) {
          bad[i] = 'db=$got mem=$mem pushed=$pushed err=${err?.runtimeType}';
        }
      } finally {
        await w.dispose();
      }
    }
    // ignore: avoid_print
    print('RACE-03 observed bad=${bad.length}/$loops $bad');
    expect(bad, isEmpty, reason: 'sync rewrite outside the per-patient lock overwrote the removal');
  });
  test('RACE-CTRL positive control (runs today): an OUTSIDE-the-lock '
      'swappedPathsFor patch of an old copy revives the photo, x$loops', () async {
    var revivals = 0;
    for (var i = 0; i < loops; i++) {
      final w = _World();
      await w.boot(2000 + i, deleteLocal: true);
      try {
        final old = (await w.db.fetchPatientsStrict()).single; // the screen's copy
        final staleVisit = visit('v1', [w.local], diagnosis: 'stale edit');
        // Bad design: read the mapping first (outside the lock)...
        final m = await w.db.swappedPathsFor(expectedOwner: uidA, patientId: 'p1');
        // ...the removal lands meanwhile and drops the mapping...
        await w.provider.updateRecord('p1', visit('v1', const []));
        expect(await w.db.swappedPathsFor(expectedOwner: uidA, patientId: 'p1'), isEmpty);
        // ...then the old copy is patched with the stale map and saved.
        final patched = staleVisit.attachmentPaths
            .map((e) => m['attachments/${p.basename(e)}'] ?? e)
            .toList();
        await w.db.updatePatient(Patient(
            id: old.id, name: old.name, age: old.age, gender: old.gender, phone: old.phone,
            history: [visit('v1', patched, diagnosis: 'stale edit')]));
        if ((await w.storedV1()).contains(w.s)) revivals++;
      } finally {
        await w.dispose();
      }
    }
    // ignore: avoid_print
    print('RACE-CTRL observed revivals=$revivals/$loops');
    expect(revivals, loops, reason: 'the detector must see the outside-lock revival');
  });
}
