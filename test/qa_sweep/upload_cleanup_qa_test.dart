// QA cases for #16 F8-R1 (15a707f): the plain local copy of a picked photo
// is deleted only after its Storage upload is confirmed AND the row now
// holds the Storage path. Adds what backend's upload_cleanup_test.dart does
// not cover: an upload that never completes, one that fails after starting,
// sign-out mid-upload, and confirmed uploads where the row still holds the
// local path (concurrent re-add, edit mid-upload, another patient).
// Every case also checks the invariant "no row points at a deleted local
// file", including after a later sweep. Fakes only; no Firebase.
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../backend/fakes.dart';
import '../support/db_fakes.dart' show captureLogs;
import 'support/app_sweep_wiring.dart';

const doctorA = 'doctorA';
const doctorB = 'doctorB';

/// FakeStorage whose uploads wait on [gate] when it is set.
class _GatedStorage extends FakeStorage {
  Completer<TaskSnapshot>? gate;
  int started = 0;
  @override
  Reference ref([String? path]) => _GatedRef(this, path ?? '');
}

class _GatedRef extends FakeRef {
  _GatedRef(_GatedStorage super.storage, super.fullPath);
  _GatedStorage get _s => storage as _GatedStorage;
  @override
  Reference child(String path) =>
      _GatedRef(_s, fullPath.isEmpty ? path : '$fullPath/$path');
  @override
  UploadTask putFile(File file, [SettableMetadata? metadata]) {
    final g = _s.gate;
    if (g == null) return super.putFile(file, metadata);
    _s.started++;
    final bytes = file.readAsBytesSync();
    return FakeUploadTask(g.future.then((snap) {
      storage.uploads[fullPath] = metadata?.contentType;
      storage.objects[fullPath] = bytes;
      return snap;
    }));
  }
}

int _n = 0;
String _uuid() =>
    '${(++_n).toRadixString(16).padLeft(8, '0')}-0000-4000-8000-00000000f8a1.jpg';

VisitRecord _visit(String id, List<String> photos, {String dx = 'd'}) =>
    VisitRecord(
        id: id,
        date: DateTime(2026, 1, 2),
        visitType: 'Consultation',
        symptoms: 's',
        diagnosis: dx,
        prescription: 'p',
        attachmentPaths: photos);

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late MergeDb db;
  late CloudFirestoreHelper remote;
  late _GatedStorage storage;
  late PatientProvider provider;
  late List<String> logs;

  String pick() {
    final dir = photos.visitFolderFor(doctorA)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, _uuid()))..writeAsBytesSync(List.filled(64, 7)))
        .path;
  }

  List<String> rowPaths(String id) =>
      db.rows[id]!.history.expand((r) => r.attachmentPaths).toList();

  bool isLocal(String e) =>
      !e.startsWith('clinical_attachments/') && !e.startsWith('http');

  /// No DB row may reference a local file that is gone; then a sweep an
  /// hour later must not break that either.
  Future<void> noDangling() async {
    void check(String when) {
      for (final r in db.rows.values) {
        for (final e in r.history.expand((v) => v.attachmentPaths)) {
          if (isLocal(e)) {
            expect(File(e).existsSync(), isTrue,
                reason: 'DATA LOSS ($when): ${r.id} still points at a deleted '
                    'local photo');
          }
        }
      }
    }

    check('after save/upload');
    await appSweep(db, photos,
            () => DateTime.now().add(const Duration(hours: 1)))
        .sweep(doctorA);
    check('after a later sweep');
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('qa_f8r1');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = MergeDb()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1');
    remote = CloudFirestoreHelper();
    storage = _GatedStorage();
    logs = [];
    provider = PatientProvider(
        db: db,
        firestore: remote,
        auth: FakeAuth(doctorA),
        storage: storage,
        photos: photos,
        retryBaseDelay: const Duration(hours: 1),
        retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(doctorA);
  });

  tearDown(() {
    final g = storage.gate;
    if (g != null && !g.isCompleted) g.completeError(StateError('teardown'));
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  test('F8-QA-01 upload never completes: local copy kept, row local',
      () async {
    storage.gate = Completer<TaskSnapshot>();
    final a = pick();
    await captureLogs(logs, () async {
      await provider.addRecord('p1', _visit('v1', [a]));
      await flushMicrotasks();
    });
    expect(storage.started, 1, reason: 'upload should have started');
    expect(storage.uploads, isEmpty);
    expect(rowPaths('p1'), contains(a));
    expect(File(a).existsSync(), isTrue);
    expect(logs.where((l) => l.startsWith('Photos: removed')), isEmpty);
    await noDangling();
    expect(File(a).existsSync(), isTrue, reason: 'sweep ate a pending upload');
  });

  test('F8-QA-02 upload fails after starting: local copy kept', () async {
    storage.gate = Completer<TaskSnapshot>();
    final a = pick();
    await provider.addRecord('p1', _visit('v1', [a]));
    await flushMicrotasks();
    storage.gate!.completeError(
        FirebaseException(plugin: 'storage', code: 'canceled'));
    await flushMicrotasks();
    expect(storage.uploads, isEmpty);
    expect(rowPaths('p1'), contains(a));
    expect(File(a).existsSync(), isTrue);
    await noDangling();
  });

  test('F8-QA-03 sign-out mid-upload, then it completes: file kept, '
      'signed-out row not rewritten', () async {
    storage.gate = Completer<TaskSnapshot>();
    final a = pick();
    await provider.addRecord('p1', _visit('v1', [a]));
    await flushMicrotasks();
    final before = rowPaths('p1');
    provider.clear();
    db.state = const DbReady(doctorB);
    storage.gate!.complete(FakeTaskSnapshot());
    await flushMicrotasks();
    expect(File(a).existsSync(), isTrue,
        reason: 'deleted a photo after the session ended');
    expect(rowPaths('p1'), before,
        reason: 'rewrote a row after the session ended');
  });

  test('F8-QA-04 confirmed upload but a concurrent visit re-added the same '
      'local path: file kept', () async {
    storage.gate = Completer<TaskSnapshot>();
    final a = pick();
    await provider.addRecord('p1', _visit('v1', [a]));
    await flushMicrotasks();
    await provider.addRecord('p1', _visit('v2', [a]));
    await flushMicrotasks();
    storage.gate!.complete(FakeTaskSnapshot());
    await flushMicrotasks();
    await flushMicrotasks();
    if (rowPaths('p1').contains(a)) {
      expect(File(a).existsSync(), isTrue,
          reason: 'DATA LOSS: row still holds the local path');
    }
    await noDangling();
  });

  test('F8-QA-05 visit edited mid-upload: never left pointing at a deleted '
      'file', () async {
    storage.gate = Completer<TaskSnapshot>();
    final a = pick();
    await provider.addRecord('p1', _visit('v1', [a]));
    await flushMicrotasks();
    await provider.updateRecord('p1', _visit('v1', [a], dx: 'edited'));
    await flushMicrotasks();
    storage.gate!.complete(FakeTaskSnapshot());
    await flushMicrotasks();
    await flushMicrotasks();
    expect(db.rows['p1']!.history.firstWhere((v) => v.id == 'v1').diagnosis,
        'edited', reason: 'the edit must survive the upload rewrite');
    await noDangling();
  });

  test('F8-QA-06 confirmed upload, another patient still holds the local '
      'path: file kept', () async {
    final a = pick();
    db.rows['p2'] = Patient(
        id: 'p2',
        name: 'Other',
        age: '40',
        gender: 'Male',
        phone: '+9100001',
        history: [_visit('w1', [a])]);
    await provider.addRecord('p1', _visit('v1', [a]));
    await flushMicrotasks();
    await flushMicrotasks();
    expect(storage.uploads, isNotEmpty, reason: 'precondition: confirmed');
    expect(File(a).existsSync(), isTrue,
        reason: 'DATA LOSS: p2 still references the local copy');
    await noDangling();
  });

  test('F8-QA-07 control: confirmed upload, row rewritten, nobody else uses '
      'it: deleted', () async {
    final a = pick();
    await provider.addRecord('p1', _visit('v1', [a]));
    await flushMicrotasks();
    await flushMicrotasks();
    expect(rowPaths('p1').where(isLocal), isEmpty);
    expect(File(a).existsSync(), isFalse);
    await noDangling();
  });
}
