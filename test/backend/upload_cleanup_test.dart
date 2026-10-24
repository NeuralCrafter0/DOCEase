// Upload -> row swap -> local cleanup (security F8-R1, #16 re-review):
// - after a confirmed upload the DB swaps the local path for the Storage
//   path in the stored row (swapAttachmentPath, one transaction); a stale
//   snapshot of the row is never written back;
// - the plain local copy is deleted only after the swap returned true, and
//   only inside the owner's own folder;
// - a swap that throws (wrong owner, bad path, corrupt row) deletes
//   nothing, local or remote; the row stays dirty and the retry swaps the
//   same object again (no new upload);
// - a swap that returns false (photo or visit removed mid-upload) deletes
//   the object this upload just wrote, at that exact path, only if a
//   strict scan shows nothing references it.
// Cloud mode against fakes only (FakeStorage, CloudFirestoreHelper); nothing
// is deployed or contacted. Runs in both suite modes.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart' show captureLogs;
import 'fakes.dart';

const doctorA = 'doctorA';

/// MergeDb whose strict attachment scan can be made to fail, and that
/// records every whole-row write (a swap must not be one).
class _SwapDb extends MergeDb {
  Object? scanThrows;
  int rowWrites = 0;

  /// When set, markSynced returns it without marking anything.
  bool? markSyncedResult;

  @override
  Future<bool> markSynced(String id, String version) async =>
      markSyncedResult ?? await super.markSynced(id, version);

  @override
  Future<String?> updatePatient(Patient patient) {
    rowWrites++;
    return super.updatePatient(patient);
  }

  @override
  Future<Set<String>> referencedAttachmentPaths() async {
    final t = scanThrows;
    if (t != null) throw t;
    return super.referencedAttachmentPaths();
  }
}

/// App-generated name (`<uuid v4>.<ext>`) standing for [label].
String n(String label) {
  final h = sha256.convert(utf8.encode(label)).toString();
  final ext = label.substring(label.lastIndexOf('.') + 1);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}.$ext';
}

VisitRecord visit(String id, List<String> photos, {String diagnosis = 'd'}) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: diagnosis, prescription: 'p', attachmentPaths: photos);

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _SwapDb db;
  late CloudFirestoreHelper remote;
  late FakeStorage storage;
  late PatientProvider provider;

  /// Deterministic wait: the provider's background work (push, upload,
  /// swap, refresh, file deletes) has finished. No timers, no polling.
  Future<void> settle() => provider.backgroundIdleForTesting();

  String photoIn(String dir, String name) {
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, name))..writeAsBytesSync(List.filled(64, 7))).path;
  }

  /// Where PR #8's AttachmentStorage writes a pick: <support>/attachments/<ownerHash>/.
  /// Registered as #8 will after its copy (security #16 L-1).
  String pick(String name, {String owner = doctorA, String patientId = 'p1'}) {
    final path = photoIn(photos.visitFolderFor(owner)!, n(name));
    provider.registerPickedAttachment(patientId: patientId, localPath: path);
    return path;
  }

  List<String> rowPaths(String id) => db.rows[id]!.history.expand((r) => r.attachmentPaths).toList();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_upload_cleanup');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _SwapDb()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1');
    remote = CloudFirestoreHelper();
    storage = FakeStorage();
    provider = PatientProvider(
        db: db, firestore: remote, auth: FakeAuth(doctorA), storage: storage, photos: photos,
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
  });

  Future<void> load() => provider.loadAndSync(doctorA);

  tearDown(() {
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  test('swap returned true: the local copy is deleted and the stored row is pushed and marked synced', () async {
    await load();
    final a = pick('a.jpg');
    final logs = <String>[];
    await captureLogs(logs, () async {
      await provider.addRecord('p1', visit('v1', [a]));
      await settle();
    });

    final storagePath = storage.uploads.keys.single;
    expect(storagePath, startsWith('clinical_attachments/$doctorA/p1/'));
    expect(db.swapCalls, 1);
    expect(db.rowWrites, 1, reason: 'only the visit save writes the whole row; the swap does not');
    expect(rowPaths('p1'), [storagePath]);
    expect(provider.findById('p1').history.single.attachmentPaths, [storagePath]);
    expect(remote.payloads.last.history.single.attachmentPaths, [storagePath]);
    expect(db.dirty['p1'], isFalse, reason: "markSynced used the swapped row's own version");
    expect(File(a).existsSync(), isFalse);
    expect(storage.deleted, isEmpty);
    expect(logs.where((l) => l.startsWith('Photos:')), ['Photos: removed 1 after an upload']);
    expect(logs.join('\n'), isNot(contains(p.basename(a))));
  });

  test('a failed upload keeps the file for the retry; the confirmed retry swaps and deletes it', () async {
    await load();
    storage.failUploads = true;
    final a = pick('a.jpg');
    await provider.addRecord('p1', visit('v1', [a]));
    await settle();
    expect((storage.uploads.length, db.swapCalls), (0, 0));
    expect(rowPaths('p1'), [a]);
    expect(File(a).existsSync(), isTrue);

    storage.failUploads = false;
    await provider.retryDirty();
    await settle();
    expect(storage.uploads.length, 1);
    expect(rowPaths('p1'), [storage.uploads.keys.single]);
    expect(File(a).existsSync(), isFalse);
  });

  for (final (name, error) in [
    ('wrong owner', StateError('wrong owner')),
    ('bad storage path', ArgumentError('bad storage path')),
    ('corrupt row', StateError('corrupt row')),
  ]) {
    test('swap throws ($name): nothing is deleted, the row stays dirty, the retry reuses the upload', () async {
      await load();
      db.swapThrows = error;
      final a = pick('a.jpg');
      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.addRecord('p1', visit('v1', [a]));
        await settle();
      });
      expect((storage.puts, db.swapCalls), (1, 1));
      expect(rowPaths('p1'), [a], reason: 'the swap wrote nothing');
      expect(db.dirty['p1'], isTrue);
      expect(File(a).existsSync(), isTrue);
      expect(storage.deleted, isEmpty, reason: 'a throw never deletes the remote object');
      expect(remote.payloads.expand((x) => x.history).expand((r) => r.attachmentPaths),
          isNot(contains(a)), reason: 'local paths never reach Firestore');
      expect(logs.where((l) => l.startsWith('Upload: swap failed')), hasLength(1));
      expect(logs.join('\n'), isNot(contains(p.basename(a))));

      db.swapThrows = null;
      await provider.retryDirty();
      await settle();
      expect(storage.puts, 1, reason: 'the retry swaps the object already uploaded');
      expect(db.swapCalls, 2);
      expect(rowPaths('p1'), [storage.uploads.keys.single]);
      expect(File(a).existsSync(), isFalse);
      expect(storage.deleted, isEmpty);
    });
  }

  test('owner changed mid-upload: no swap, nothing deleted', () async {
    await load();
    final a = pick('a.jpg');
    storage.beforeUploadCompletes = (_) async => db.state = const DbReady('doctorB');
    await provider.addRecord('p1', visit('v1', [a]));
    await settle();
    expect(storage.puts, 1);
    expect(db.swapCalls, 0);
    expect(rowPaths('p1'), [a]);
    expect(File(a).existsSync(), isTrue);
    expect(storage.deleted, isEmpty);
  });

  test('swap returned false (photo removed mid-upload): that exact object is deleted, the local file is left to the sweep', () async {
    await load();
    final a = pick('a.jpg');
    storage.beforeUploadCompletes = (_) async {
      storage.beforeUploadCompletes = null;
      await provider.updateRecord('p1', visit('v1', const [])); // the photo is removed while it uploads
    };
    final logs = <String>[];
    await captureLogs(logs, () async {
      await provider.addRecord('p1', visit('v1', [a]));
      await settle();
    });
    final storagePath = storage.puts == 1 ? storage.deleted.single : '';
    expect(storagePath, startsWith('clinical_attachments/$doctorA/p1/'));
    expect(storage.uploads, isEmpty, reason: 'deleted at the path its putFile wrote');
    expect(rowPaths('p1'), isEmpty);
    expect(db.swapCalls, 1);
    expect(File(a).existsSync(), isTrue, reason: 'never deleted by the upload path while it was pending');
    expect(logs, contains('Upload: removed 1 unused upload(s)'));
    expect(logs.join('\n'), isNot(contains(storagePath)));
  });

  test('swap returned false but a row references the object: it is kept', () async {
    await load();
    final a = pick('a.jpg');
    db.beforeSwap = (patientId, localPath) {
      final storagePath = storage.uploads.keys.single;
      db.rows['p1'] = testPatient('p1'); // the photo's visit is gone ...
      db.rows['p2'] = testPatient('p2').copyWithHistoryForTest([visit('v9', [storagePath])]); // ... but p2 names it
    };
    await provider.addRecord('p1', visit('v1', [a]));
    await settle();
    expect(db.swapCalls, 1);
    expect(storage.deleted, isEmpty);
    expect(storage.uploads.length, 1);
  });

  test('swap returned false and the strict scan fails: nothing is deleted, only the reason is logged', () async {
    await load();
    final a = pick('a.jpg');
    db.beforeSwap = (_, _) => db.rows['p1'] = testPatient('p1');
    db.scanThrows = const AttachmentScanIncomplete(AttachmentScanFailure.readFailed);
    final logs = <String>[];
    await captureLogs(logs, () async {
      await provider.addRecord('p1', visit('v1', [a]));
      await settle();
    });
    expect(storage.deleted, isEmpty);
    expect(storage.uploads.length, 1);
    expect(logs, contains('Upload: unused upload kept (readFailed)'));
  });

  test('an edit saved mid-upload is kept: the swap changes only the path', () async {
    await load();
    final a = pick('a.jpg');
    storage.beforeUploadCompletes = (_) async {
      storage.beforeUploadCompletes = null;
      await provider.updateRecord('p1', visit('v1', [a], diagnosis: 'edited mid-upload'));
    };
    await provider.addRecord('p1', visit('v1', [a]));
    await settle();
    final storagePath = storage.uploads.keys.single;
    final stored = db.rows['p1']!.history.single;
    expect(stored.diagnosis, 'edited mid-upload');
    expect(stored.attachmentPaths, [storagePath]);
    final shown = provider.findById('p1').history.single;
    expect(shown.diagnosis, 'edited mid-upload');
    expect(shown.attachmentPaths, [storagePath]);
    expect(File(a).existsSync(), isFalse);
  });

  test('a stale snapshot saved after the swap gets the Storage path, never the deleted local one', () async {
    await load();
    final a = pick('a.jpg');
    await provider.addRecord('p1', visit('v1', [a]));
    final stalePatient = provider.findById('p1'); // taken before the swap
    await settle();
    final storagePath = storage.uploads.keys.single;
    expect(File(a).existsSync(), isFalse);

    // A patient-details form opened before the swap.
    final staleForm = stalePatient.copyWithHistoryForTest([visit('v1', [a])]);
    await provider.updatePatient(staleForm);
    expect(rowPaths('p1'), [storagePath]);

    // A visit form opened before the swap: saved (not refused as a missing file).
    await provider.updateRecord('p1', visit('v1', [a], diagnosis: 'later'));
    await settle();
    expect(rowPaths('p1'), [storagePath]);
    expect(db.rows['p1']!.history.single.diagnosis, 'later');
  });

  group('details save applies only detail fields (security F16-R4)', () {
    Patient detailsForm(Patient opened, {required String name, required String phone}) => Patient(
        id: opened.id, name: name, age: opened.age, gender: opened.gender, phone: phone,
        relation: opened.relation, history: opened.history);

    test('exact flow: visit with photo, details opened, upload swaps and deletes, details saved from the snapshot', () async {
      await load();
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      final opened = provider.findById('p1'); // details screen opens: snapshot names the local file
      expect(opened.history.single.attachmentPaths, [a]);
      await settle(); // upload, swap, local copy deleted
      final storagePath = storage.uploads.keys.single;
      expect(File(a).existsSync(), isFalse);
      await provider.addRecord('p1', visit('v2', [])); // a visit saved after the screen opened
      await settle();

      await provider.updatePatient(detailsForm(opened, name: 'Renamed', phone: '+91 99999'));
      await settle();

      final row = db.rows['p1']!;
      expect((row.name, row.phone), ('Renamed', '+91 99999'), reason: 'new detail fields apply');
      final byId = {for (final r in row.history) r.id: r};
      expect(byId.keys.toSet(), {'v1', 'v2'}, reason: 'the later visit survives');
      expect(byId['v1']!.attachmentPaths, [storagePath], reason: 'the visit keeps the Storage path');
      final shown = provider.findById('p1');
      expect((shown.name, shown.phone), ('Renamed', '+91 99999'));
      expect({for (final r in shown.history) r.id: r.attachmentPaths}, {'v1': [storagePath], 'v2': <String>[]});
      expect(File(a).existsSync(), isFalse);
      expect(storage.uploads.length, 1, reason: 'no re-upload');
      expect(storage.deleted, isEmpty, reason: 'the Storage object is not orphaned or removed');
      final pushed = remote.payloads.last;
      expect(pushed.name, 'Renamed');
      expect({for (final r in pushed.history) r.id: r.attachmentPaths}, {'v1': [storagePath], 'v2': <String>[]});
      expect(db.dirty['p1'], isFalse);
    });

    test("the caller's history is ignored both ways: no visit added, none dropped, no path changed", () async {
      db.rows['p1'] = testPatient('p1', history: [visit('v1', []), visit('v2', [])]);
      await load();
      final opened = provider.findById('p1');
      final form = Patient(
          id: 'p1', name: 'N', age: opened.age, gender: opened.gender, phone: opened.phone,
          relation: opened.relation, history: [visit('v1', ['/tmp/elsewhere.jpg']), visit('vX', [])]);
      await provider.updatePatient(form);
      await settle();
      expect(db.rows['p1']!.name, 'N');
      expect([for (final r in db.rows['p1']!.history) (r.id, r.attachmentPaths.length)], [('v1', 0), ('v2', 0)]);
      expect([for (final r in provider.findById('p1').history) r.id], ['v1', 'v2']);
      expect(storage.uploads, isEmpty);
    });

    test('updatePatientDetails: only the given fields change', () async {
      await load();
      final before = db.rows['p1']!;
      await provider.updatePatientDetails('p1', phone: '+91 12345');
      final row = db.rows['p1']!;
      expect((row.name, row.age, row.gender, row.relation), (before.name, before.age, before.gender, before.relation));
      expect(row.phone, '+91 12345');
      expect(provider.findById('p1').phone, '+91 12345');
    });

    test('a failed strict read or a missing row refuses the save: nothing written, memory unchanged', () async {
      await load();
      final shownBefore = provider.findById('p1');
      final versionBefore = db.versions['p1'];
      db.fetchStrictThrows = const DbReadException(DbReadFailure.readFailed);
      await expectLater(provider.updatePatientDetails('p1', name: 'X'),
          throwsA(isA<SaveRefusedException>().having((e) => e.error, 'error', isA<DbReadException>())));
      db.fetchStrictThrows = null;
      db.rows.remove('p1');
      await expectLater(provider.updatePatient(detailsForm(shownBefore, name: 'Y', phone: '1')),
          throwsA(isA<SaveRefusedException>().having((e) => e.error, 'error', isA<StoredPatientMissingException>())));
      expect(db.rows.containsKey('p1'), isFalse, reason: 'a stale details save never re-creates the row');
      expect(db.versions['p1'], versionBefore);
      expect(identical(provider.findById('p1'), shownBefore), isTrue);
    });

    test('source pin: updatePatient takes no history from the caller', () {
      final s = File('lib/providers/patient_provider.dart').readAsStringSync();
      final up = s.substring(s.indexOf('Future<void> updatePatient(Patient patient)'),
          s.indexOf('Future<void> updatePatientDetails('));
      expect(up, isNot(contains('.history')));
      final details = s.substring(s.indexOf('Future<void> updatePatientDetails('), s.indexOf('/// Deletes a patient.'));
      expect(details, contains('await _underPatientLock(patientId, () async {'));
      expect(details, contains('await _db.fetchPatientsStrict()'));
      expect(details, contains('history: stored.history, // never the caller\'s'));
    });
  });

  group('per-patient lock and post-swap reference check (security #16)', () {
    test('a stale whole-row save racing the swap waits for the lock: Storage path kept, local copy deleted', () async {
      await load();
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      final stale = provider.findById('p1'); // pre-swap copy (local path)
      Future<void>? staleSave;
      var staleDone = false;
      bool? staleDoneAtScan;
      List<String>? rowAtScan;
      db.beforeSwap = (_, _) {
        db.beforeSwap = null;
        // Issued while the swap holds p1's lock.
        staleSave = provider.updatePatient(Patient(
            id: stale.id, name: 'Renamed', age: stale.age, gender: stale.gender,
            phone: stale.phone, relation: stale.relation, history: stale.history))
          ..then((_) => staleDone = true);
      };
      db.beforeKeyScan = () {
        db.beforeKeyScan = null;
        staleDoneAtScan = staleDone;
        rowAtScan = rowPaths('p1');
      };
      final logs = <String>[];
      await captureLogs(logs, () async {
        await settle();
        await staleSave;
        await settle();
      });
      final storagePath = storage.uploads.keys.single;
      expect(staleDoneAtScan, isFalse, reason: 'the stale save ran only after swap, refresh and scan');
      expect(rowAtScan, [storagePath]);
      expect(db.rows['p1']!.name, 'Renamed', reason: 'the stale save itself is kept');
      expect(rowPaths('p1'), [storagePath], reason: 'mapped to the Storage path, never the local one');
      expect(provider.findById('p1').history.single.attachmentPaths, [storagePath]);
      expect(File(a).existsSync(), isFalse);
      expect(storage.deleted, isEmpty);
      expect(logs, contains('Photos: removed 1 after an upload'));
    });

    test('a stale save that got past the lock: the local copy is kept and the visit still loads its photo', () async {
      await load();
      final a = pick('a.jpg');
      // A whole-row write from outside this provider's lock lands between
      // the swap and the reference check, putting the local path back.
      db.beforeKeyScan = () {
        db.beforeKeyScan = null;
        db.rows['p1'] = testPatient('p1', history: [visit('v1', [a])]);
      };
      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.addRecord('p1', visit('v1', [a]));
        await settle();
      });
      expect(db.swapCalls, 1);
      expect(db.keyScans, greaterThanOrEqualTo(1));
      expect(rowPaths('p1'), [a]);
      expect(File(a).existsSync(), isTrue, reason: 'its key is still referenced: never deleted');
      expect(logs.where((l) => l.startsWith('Photos: removed')), isEmpty);
      await provider.reload();
      final shown = provider.findById('p1').history.single.attachmentPaths;
      expect(shown, [a]);
      expect(File(shown.single).readAsBytesSync(), hasLength(64), reason: 'the photo still loads');
    });

    test('the refresh after a swap fails: the local copy is kept and the push is retried', () async {
      await load();
      final a = pick('a.jpg');
      // Fails only the strict read after the swap (the save's own strict
      // read, security #16 M-1, still succeeds).
      db.beforeSwap = (_, _) {
        db.beforeSwap = null;
        db.fetchStrictThrows = const DbReadException(DbReadFailure.readFailed);
      };
      final scansBefore = db.keyScans;
      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.addRecord('p1', visit('v1', [a]));
        await settle();
      });
      final storagePath = storage.uploads.keys.single;
      expect(rowPaths('p1'), [storagePath], reason: 'the swap itself succeeded');
      expect(provider.findById('p1').history.single.attachmentPaths, [storagePath]);
      expect(File(a).existsSync(), isTrue, reason: 'no delete without a confirmed refresh');
      expect(db.keyScans, scansBefore, reason: 'no reference check, no delete');
      expect(db.dirty['p1'], isTrue);
      expect(remote.payloads, isEmpty);
      expect(logs.where((l) => l.startsWith('Upload: refresh after swap failed (')), hasLength(1));
      expect(logs.join('\n'), isNot(contains(p.basename(a))));
    });

    test("#10's fake: an unreadable row makes the swap throw DbReadException; nothing written or deleted", () async {
      await load();
      final a = pick('a.jpg');
      final broken = Patient(id: 'p1', name: 'x', age: '1', gender: 'Female', phone: '+91', parseErrors: const ['name']);
      db.beforeSwap = (_, _) {
        db.beforeSwap = null;
        db.rows['p1'] = broken;
      };
      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.addRecord('p1', visit('v1', [a]));
        await settle();
      });
      expect(identical(db.rows['p1'], broken), isTrue, reason: 'the swap wrote nothing');
      expect(File(a).existsSync(), isTrue);
      expect(storage.deleted, isEmpty);
      expect(logs, contains('Upload: swap failed (DbReadException); retried later'));
    });
  });

  test('same owner-folder and regular-file checks: other places stay local and are never deleted', () async {
    await load();
    final outside = photoIn(p.join(root.path, 'cache'), 'image_picker_1.jpg');
    final theirs = pick('x.jpg', owner: 'doctorB');
    final loose = photoIn(p.join(photos.supportPath!, 'attachments'), n('loose.jpg'));
    final target = photoIn(p.join(root.path, 'elsewhere'), 'target.jpg');
    final link = Link(p.join(photos.visitFolderFor(doctorA)!, n('link.jpg')))..createSync(target, recursive: true);
    provider.registerPickedAttachment(patientId: 'p1', localPath: link.path);

    await provider.addRecord('p1', visit('v1', [outside, theirs, loose, link.path]));
    await settle();

    // #10's swap only takes photos in the owner's attachments/ folder, so
    // the others are not uploaded at all (no unreferenced Storage object).
    // Another owner's photo is never accepted into this owner's visit
    // (security #16 L-1): it is left out, and left on disk. A symlink in
    // the owner's own folder is not a regular file (security #16 L-2): even
    // registered, it is left out of the save and never uploaded, so the
    // link target is never sent.
    expect(storage.uploads, isEmpty);
    expect(db.swapCalls, 0);
    final stored = rowPaths('p1');
    expect(stored, [outside, loose]);
    expect(provider.findById('p1').history.single.attachmentPaths, stored);
    expect(File(outside).existsSync(), isTrue);
    expect(File(theirs).existsSync(), isTrue);
    expect(File(loose).existsSync(), isTrue);
    expect(FileSystemEntity.typeSync(link.path, followLinks: false), FileSystemEntityType.link);
    expect(File(target).existsSync(), isTrue);
    expect(storage.deleted, isEmpty);
  });

  test('a local copy another visit still references is kept', () async {
    final a = pick('a.jpg');
    db.rows['p2'] = testPatient('p2').copyWithHistoryForTest([visit('v9', [a])]);
    await load();
    expect(provider.findById('p2').history.single.attachmentPaths, [a]);
    // Picked before any session was loaded: not registered (L-1). Register
    // it again now, as the picker would in this session.
    expect(provider.isRegisteredPickForTesting('p1', a), isFalse);
    provider.registerPickedAttachment(patientId: 'p1', localPath: a);

    await provider.addRecord('p1', visit('v1', [a]));
    await settle();

    expect(rowPaths('p1'), [storage.uploads.keys.single]);
    expect(rowPaths('p2'), [a]);
    expect(File(a).existsSync(), isTrue);
  });

  group("#10's attachment_swaps: the stored row is what is pushed and shown", () {
    /// Waits for the background work, then checks the outcome.
    Future<void> until(bool Function() done) async {
      await settle();
      expect(done(), isTrue, reason: 'state after the background work finished');
    }

    /// Sets up the DB engineer's case: the DB recorded the swap L -> S for
    /// p1's visit v1, while this provider's memory still holds L.
    ({String local, String storage}) memoryHoldsLocal() {
      final local = pick('l.jpg');
      final storagePath = 'clinical_attachments/$doctorA/p1/${n('s.jpg')}';
      final key = AttachmentRefs.attachmentKey(local,
          ownerFolderName: LocalPhotoStore.ownerFolderName(doctorA))!;
      db.swaps['p1'] = {key: storagePath};
      return (local: local, storage: storagePath);
    }

    List<String> sentPaths() =>
        [for (final pl in remote.payloads) for (final r in pl.history) ...r.attachmentPaths];

    test('a stale whole-row save after the swap keeps the Storage path (provider side of SWQ-08)', () async {
      await load();
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      await until(() => db.dirty['p1'] == false);
      final storagePath = storage.uploads.keys.single;
      expect(rowPaths('p1'), [storagePath]);
      // An edit from a pre-swap copy of the visit (local path L).
      await provider.updateRecord('p1', visit('v1', [a], diagnosis: 'edited'));
      await until(() => db.dirty['p1'] == false);
      final v1 = db.rows['p1']!.history.single;
      expect(v1.diagnosis, 'edited');
      expect(v1.attachmentPaths, [storagePath]);
      expect(provider.findById('p1').history.single.attachmentPaths, [storagePath]);
      expect(remote.payloads.last.history.single.attachmentPaths, [storagePath]);
      expect(storage.uploads.length, 1, reason: 'no re-upload of L');
      expect(db.dirty['p1'], isFalse);
    });

    test('a rewritten save: memory holds L, the stored row S; the cloud and the UI get S', () async {
      db.rows['p1'] = testPatient('p1', history: [visit('v1', [])]);
      await load();
      final paths = memoryHoldsLocal();
      db.rows['p1'] = testPatient('p1', history: [visit('v1', [paths.local])]);
      provider.clear();
      await load();
      expect(provider.findById('p1').history.single.attachmentPaths, [paths.local], reason: 'memory: L');
      remote.payloads.clear();

      await provider.addRecord('p1', visit('v2', []));
      await until(() => db.dirty['p1'] == false && !File(paths.local).existsSync());

      final stored = {for (final r in db.rows['p1']!.history) r.id: r.attachmentPaths};
      expect(stored, {'v1': [paths.storage], 'v2': <String>[]}, reason: 'the DB re-applied the swap');
      final shown = {for (final r in provider.findById('p1').history) r.id: r.attachmentPaths};
      expect(shown, stored, reason: 'memory refreshed from the stored row: the UI shows S');
      expect(remote.payloads, isNotEmpty);
      expect({for (final r in remote.payloads.last.history) r.id: r.attachmentPaths}, stored,
          reason: 'the cloud receives S');
      expect(sentPaths(), isNot(contains(paths.local)));
      expect(db.log, contains('markSynced:p1:${db.versions['p1']}'),
          reason: "markSynced gets the pushed row's own version");
      expect(db.dirty['p1'], isFalse);
      expect(storage.uploads, isEmpty);
      expect(File(paths.local).existsSync(), isFalse,
          reason: 'L is no longer referenced (fresh scan) and S is in Storage');
    });

    test("the push sends the stored dirty row, never the provider's list", () async {
      final paths = memoryHoldsLocal();
      db.rows['p1'] = testPatient('p1', history: [visit('v1', [paths.local])]);
      await load();
      expect(provider.findById('p1').history.single.attachmentPaths, [paths.local], reason: 'memory: L');
      // The stored row now holds S and is dirty (a save the DB rewrote).
      db.rows['p1'] = testPatient('p1', history: [visit('v1', [paths.storage])]);
      db.dirty['p1'] = true;
      db.versions['p1'] = 'v-stored';
      remote.payloads.clear();

      await provider.retryDirty();
      await until(() => db.dirty['p1'] == false);

      expect(remote.payloads.single.history.single.attachmentPaths, [paths.storage]);
      expect(sentPaths(), isNot(contains(paths.local)));
      expect(db.log, contains('markSynced:p1:v-stored'));
      expect(db.dirty['p1'], isFalse);
    });

    test('source pin: _syncOne pushes the stored row, not _byId', () {
      final s = File('lib/providers/patient_provider.dart').readAsStringSync();
      final sync = s.substring(s.indexOf('Future<_Push> _syncOne('), s.indexOf('Future<void> _afterLocalWrite('));
      expect(sync, isNot(contains('_byId(patientId)')));
      expect(sync, contains('await _db.dirtyPatientsStrict()'));
      expect(sync, contains('var sentVersion = current.updatedAt ?? savedVersion;'));
    });
  });

  test('source pin: the upload swaps through the DB, never writes the row snapshot back', () {
    final s = File('lib/providers/patient_provider.dart').readAsStringSync();
    final sync = s.substring(s.indexOf('final uploadOwner = _openDbUid;'),
        s.indexOf('final ok = await _firestore.syncPatient('));
    expect(sync, isNot(contains('_db.updatePatient(')));
    expect(sync, isNot(contains('_db.insertPatient(')));
    final swap = sync.indexOf('await _swapUploaded(uploadOwner,');
    final remoteDel = sync.indexOf('await _deleteOwnUploads(uploadOwner,');
    expect([swap, remoteDel], everyElement(greaterThan(0)));
    expect(swap, lessThan(remoteDel));
    expect(sync, isNot(contains('_deleteUnreferencedPhotos(')), reason: 'local delete only inside the lock');
    // Inside the per-patient lock: swap, strict refresh, then the
    // scan-checked local delete.
    final body = s.substring(s.indexOf('_swapUploaded(\n'), s.indexOf('Future<bool> _swapPath('));
    expect(body, contains('return _underPatientLock(patientId, () async {'));
    final sw = body.indexOf('await _swapPath(owner, patientId, local, storagePath)');
    final refresh = body.indexOf('stored = await _refreshFromDb(owner, uid, token, patientId);');
    final del = body.indexOf("await _deleteUnreferencedPhotos(owner, swapped.keys, after: 'an upload');");
    expect([sw, refresh, del], everyElement(greaterThan(0)));
    expect(sw, lessThan(refresh));
    expect(refresh, lessThan(del));
    expect(body.indexOf('if (stored == null) {'), inInclusiveRange(refresh, del), reason: 'no delete without a refresh');
    expect(s, contains('expectedOwner: owner, patientId: patientId, localPath: local, storagePath: storagePath'));
    expect(s, isNot(contains('_confirmedUploads')));
    expect(s, contains('await _photos.deleteOwnedVisitFile(path, owner: owner)'));
  });

  test('markSynced false (row changed after the pushed snapshot) is not an error: '
      'the row stays dirty and a retry is scheduled', () async {
    await load();
    db.markSyncedResult = false;
    final logs = <String>[];
    await captureLogs(logs, () async {
      await provider.updatePatient(testPatient('p1', name: 'Asha New'));
      await settle();
    });
    expect(remote.payloads, isNotEmpty, reason: 'the stored row was pushed');
    expect(db.dirty['p1'], isTrue, reason: 'compare-and-set refused: still dirty');
    expect(provider.retryPendingForTesting, isTrue, reason: 'retried later');
    expect(logs.where((l) => l.contains('markSynced failed')), isEmpty,
        reason: 'false is not an error');
  });

  group('security #16 L-2: only a regular file directly in the owner folder', () {
    test('LocalPhotoStore.isOwnedVisitFile: regular file yes; link, sub-folder, dot-segments, other owner, missing no', () async {
      await load();
      final dir = photos.visitFolderFor(doctorA)!;
      final regular = photoIn(dir, n('a.jpg'));
      expect(await photos.isOwnedVisitFile(regular, owner: doctorA), isTrue);
      final target = photoIn(p.join(root.path, 'elsewhere'), 'target.jpg');
      final link = Link(p.join(dir, n('l.jpg')))..createSync(target);
      expect(await photos.isOwnedVisitFile(link.path, owner: doctorA), isFalse);
      final nested = photoIn(p.join(dir, 'sub'), n('b.jpg'));
      expect(await photos.isOwnedVisitFile(nested, owner: doctorA), isFalse);
      expect(await photos.isOwnedVisitFile(p.join(dir, 'sub', '..', p.basename(regular)), owner: doctorA), isFalse);
      expect(await photos.isOwnedVisitFile(p.join(dir, '.', p.basename(regular)), owner: doctorA), isFalse);
      expect(await photos.isOwnedVisitFile(regular, owner: 'doctorB'), isFalse);
      expect(await photos.isOwnedVisitFile(p.join(dir, n('missing.jpg')), owner: doctorA), isFalse);
      expect(await photos.isOwnedVisitFile(p.relative(regular), owner: doctorA), isFalse);
      Directory(p.join(dir, n('d.jpg'))).createSync();
      expect(await photos.isOwnedVisitFile(p.join(dir, n('d.jpg')), owner: doctorA), isFalse);
    });

    test('a symlinked owner folder makes nothing in it a regular owned file', () async {
      await load();
      final dir = photos.visitFolderFor(doctorA)!;
      final real = Directory(p.join(root.path, 'realdir'))..createSync();
      final victim = photoIn(real.path, n('v.jpg'));
      if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
      Link(dir).createSync(real.path, recursive: true);
      expect(await photos.isOwnedVisitFile(p.join(dir, p.basename(victim)), owner: doctorA), isFalse);
    });

    test('registered symlink and sub-folder picks are left out of the save, nothing uploaded, files untouched', () async {
      await load();
      final dir = photos.visitFolderFor(doctorA)!;
      final target = photoIn(p.join(root.path, 'elsewhere'), 'secret.jpg');
      final link = Link(p.join(dir, n('link.jpg')))..createSync(target, recursive: true);
      final nested = photoIn(p.join(dir, 'sub'), n('nested.jpg'));
      final good = pick('good.jpg');
      provider.registerPickedAttachment(patientId: 'p1', localPath: link.path);
      provider.registerPickedAttachment(patientId: 'p1', localPath: nested);
      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.addRecord('p1', visit('v1', [link.path, nested, good]));
        await settle();
      });
      expect(storage.uploads, hasLength(1), reason: 'only the regular pick');
      final stored = rowPaths('p1');
      expect(stored, hasLength(1));
      expect(stored.single, startsWith('clinical_attachments/$doctorA/p1/'));
      expect(FileSystemEntity.typeSync(link.path, followLinks: false), FileSystemEntityType.link);
      expect(File(target).existsSync(), isTrue);
      expect(File(nested).existsSync(), isTrue);
      expect(logs, contains('Photos: 2 photo(s) not picked this session left out of a save'));
      expect(logs.where((l) => l.contains(root.path) || l.contains('secret')), isEmpty);
    });

    test('a stored photo replaced by a symlink before upload is never uploaded; stays local, not deleted', () async {
      await load();
      storage.failUploads = true;
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      await settle();
      expect(rowPaths('p1'), [a]);
      final target = photoIn(p.join(root.path, 'elsewhere'), 'secret.jpg');
      File(a).deleteSync();
      Link(a).createSync(target);
      storage.failUploads = false;
      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.retryDirty();
        await settle();
      });
      expect(storage.uploads, isEmpty);
      expect(db.swapCalls, 0);
      expect(rowPaths('p1'), [a]);
      expect(FileSystemEntity.typeSync(a, followLinks: false), FileSystemEntityType.link);
      expect(File(target).existsSync(), isTrue);
      expect(storage.deleted, isEmpty);
      expect(logs, contains('Upload: 1 photo(s) outside the owner folder kept local'));
    });
  });
}

extension on Patient {
  Patient copyWithHistoryForTest(List<VisitRecord> history) => Patient(
      id: id, name: name, age: age, gender: gender, phone: phone, relation: relation,
      updatedAt: updatedAt, history: history);

}
