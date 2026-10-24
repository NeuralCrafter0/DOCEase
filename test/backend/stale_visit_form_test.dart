// STALE-05 (QA): the visit edit form saves the photo list it captured when
// it opened. If that visit's upload confirmed meanwhile (#10 swapped L -> S
// and F8-R1 deleted L), updateRecord maps L to S through #10's strict
// swappedPathsFor before the file-exists check, inside the per-patient
// lock. Only genuinely missing, unswapped local paths are refused; a read
// failure refuses the save and writes nothing. Removing a photo in the form
// (stale L or S) leaves no reference to it.
//
// swappedPathsFor is coded against MergeDb (test/backend/fakes.dart) until
// #10 posts LocalDatabase.swappedPathsFor.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

const doctorA = 'doctorA';

/// App-generated name (`<uuid v4>.<ext>`) standing for [label].
String n(String label) {
  final h = sha256.convert(utf8.encode(label)).toString();
  final ext = label.substring(label.lastIndexOf('.') + 1);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}.$ext';
}

VisitRecord visit(String id, List<String> photos, {String diagnosis = 'd'}) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: diagnosis, prescription: 'p', attachmentPaths: photos);

class _CountingDb extends MergeDb {
  int rowWrites = 0;
  @override
  Future<String?> updatePatient(Patient patient) {
    rowWrites++;
    return super.updatePatient(patient);
  }
}

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _CountingDb db;
  late CloudFirestoreHelper remote;
  late FakeStorage storage;
  late PatientProvider provider;

  String pick(String name) {
    final dir = photos.visitFolderFor(doctorA)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, n(name)))..writeAsBytesSync(List.filled(64, 7))).path;
  }

  String keyOf(String local) => AttachmentRefs.attachmentKey(local,
      ownerFolderName: LocalPhotoStore.ownerFolderName(doctorA))!;

  /// The Storage path #10 recorded for [local].
  String storageFor(String local) => db.swaps['p1']![keyOf(local)]!;

  VisitRecord storedV1() => db.rows['p1']!.history.singleWhere((v) => v.id == 'v1');

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 1000 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    await flushMicrotasks();
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_stale_form');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _CountingDb()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1');
    remote = CloudFirestoreHelper();
    storage = FakeStorage();
    provider = PatientProvider(
        db: db, firestore: remote, auth: FakeAuth(doctorA), storage: storage, photos: photos,
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(doctorA);
  });

  tearDown(() {
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  /// Saves v1 with [locals], waits for the uploads to confirm, swap and
  /// delete the local copies. Returns the form's (stale) open-time copy.
  Future<VisitRecord> uploadedWhileFormOpen(List<String> locals) async {
    await provider.addRecord('p1', visit('v1', locals, diagnosis: 'dx-old'));
    final formCopy = provider.findById('p1').history.single; // holds the L paths
    await until(() =>
        db.dirty['p1'] == false && locals.every((l) => !File(l).existsSync()));
    expect(storedV1().attachmentPaths.every((e) => e.startsWith('clinical_attachments/')), isTrue,
        reason: 'precondition: swapped');
    expect(locals.any((l) => File(l).existsSync()), isFalse, reason: 'precondition: F8-R1 deleted L');
    return formCopy;
  }

  VisitRecord edited(VisitRecord form, List<String> photos, {String dx = 'dx-new'}) =>
      visit(form.id, photos, diagnosis: dx);

  group('STALE-05: stale local paths of an uploaded visit', () {
    test('the edit saves; the swapped L is written as its Storage path S', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      final s = storageFor(a);
      final uploads = storage.uploads.length;

      await provider.updateRecord('p1', edited(form, form.attachmentPaths));
      await until(() => db.dirty['p1'] == false);

      expect(storedV1().diagnosis, 'dx-new');
      expect(storedV1().attachmentPaths, [s]);
      expect(provider.findById('p1').history.single.attachmentPaths, [s]);
      expect(remote.payloads.last.history.single.attachmentPaths, [s]);
      expect(storage.uploads.length, uploads, reason: 'nothing re-uploaded');
      expect(db.swappedReads, contains((doctorA, 'p1')), reason: 'the current owner is passed');
    });

    test('mapping runs before the exists check: L is gone from disk, yet the save is not refused', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      expect(File(a).existsSync(), isFalse);
      await expectLater(provider.updateRecord('p1', edited(form, [a])), completes);
    });

    test('a stale L next to a new pick: S kept, the new pick saved', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      final s = storageFor(a);
      final b = pick('b.jpg');

      await provider.updateRecord('p1', edited(form, [a, b]));
      await until(() => db.dirty['p1'] == false && !File(b).existsSync());

      final paths = storedV1().attachmentPaths;
      expect(paths.first, s);
      expect(paths, hasLength(2));
      expect(paths, isNot(contains(a)));
      expect(paths[1], storageFor(b), reason: 'the new pick uploaded and swapped');
    });

    test('[L, S] of the same photo collapses to one S reference', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      final s = storageFor(a);
      await provider.updateRecord('p1', edited(form, [a, s]));
      await until(() => db.dirty['p1'] == false);
      expect(storedV1().attachmentPaths, [s]);
    });

    test('a genuinely missing, unswapped local path is still refused; nothing written', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      final ghost = p.join(photos.visitFolderFor(doctorA)!, n('ghost.jpg')); // never existed
      final before = storedV1().attachmentPaths;
      final writes = db.rowWrites;

      await expectLater(provider.updateRecord('p1', edited(form, [a, ghost])),
          throwsA(isA<UnsupportedAttachmentException>()
              .having((e) => '$e', 'reason', contains('missing'))));
      await flushMicrotasks();
      expect(db.rowWrites, writes);
      expect(storedV1().attachmentPaths, before);
      expect(storedV1().diagnosis, 'dx-old');
    });
  });

  group('STALE-05: a read that fails refuses the save (no fallback to the form)', () {
    test('swappedPathsFor throws: SaveRefusedException, nothing written, nothing deleted', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      final s = storageFor(a);
      final other = pick('kept.jpg'); // an app photo on disk must survive
      final version = db.versions['p1'];
      final writes = db.rowWrites;
      db.swappedPathsThrows = const DbReadException(DbReadFailure.readFailed);

      await expectLater(
          provider.updateRecord('p1', edited(form, [a])),
          throwsA(isA<SaveRefusedException>()
              .having((e) => e.operation, 'operation', PatientSaveOperation.updateVisit)));
      await flushMicrotasks();

      expect(db.rowWrites, writes);
      expect(db.versions['p1'], version);
      expect(storedV1().attachmentPaths, [s]);
      expect(storedV1().diagnosis, 'dx-old');
      expect(provider.findById('p1').history.single.attachmentPaths, [s]);
      expect(File(other).existsSync(), isTrue);
    });

    test('the strict stored-row read throws: refused, nothing written', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      final writes = db.rowWrites;
      db.fetchStrictThrows = const DbReadException(DbReadFailure.readFailed);

      await expectLater(provider.updateRecord('p1', edited(form, [a])),
          throwsA(isA<SaveRefusedException>()));
      db.fetchStrictThrows = null;
      await flushMicrotasks();
      expect(db.rowWrites, writes);
      expect(storedV1().diagnosis, 'dx-old');
    });
  });

  group('STALE-05: removing a photo in the form removes its Storage reference', () {
    test('removed as the stale L: S is gone from the row, the other photo kept', () async {
      final a = pick('a.jpg');
      final b = pick('b.jpg');
      final form = await uploadedWhileFormOpen([a, b]);
      final sa = storageFor(a);
      final sb = storageFor(b);
      expect(form.attachmentPaths, [a, b], reason: 'the form holds L for both');

      await provider.updateRecord('p1', edited(form, [a])); // b removed
      await until(() => db.dirty['p1'] == false);

      expect(storedV1().attachmentPaths, [sa]);
      expect(storedV1().attachmentPaths, isNot(contains(sb)));
      expect(storedV1().attachmentPaths, isNot(contains(b)));
      expect(provider.findById('p1').history.single.attachmentPaths, [sa]);
      expect(remote.payloads.last.history.single.attachmentPaths, [sa]);
    });

    test('removed as S (a fresh form): the same result', () async {
      final a = pick('a.jpg');
      final b = pick('b.jpg');
      await uploadedWhileFormOpen([a, b]);
      final sa = storageFor(a);
      final fresh = provider.findById('p1').history.single; // holds S for both

      await provider.updateRecord('p1', edited(fresh, [sa])); // Sb removed
      await until(() => db.dirty['p1'] == false);

      expect(storedV1().attachmentPaths, [sa]);
      expect(provider.findById('p1').history.single.attachmentPaths, [sa]);
    });

    test('all photos removed from a stale form: no reference remains (no L, no S)', () async {
      final a = pick('a.jpg');
      final form = await uploadedWhileFormOpen([a]);
      await provider.updateRecord('p1', edited(form, const []));
      await until(() => db.dirty['p1'] == false);
      expect(storedV1().attachmentPaths, isEmpty);
    });
  });

  group('MergeDb.swappedPathsFor follows the DB engineer\'s final form', () {
    test('a wrong owner throws DbReadException(notOpen)', () async {
      await expectLater(db.swappedPathsFor(expectedOwner: 'doctorB', patientId: 'p1'),
          throwsA(const DbReadException(DbReadFailure.notOpen)));
    });

    test('only entries passing isStoragePathFor(owner, patientId) are returned', () async {
      final good = 'clinical_attachments/$doctorA/p1/${n('g.jpg')}';
      db.swaps['p1'] = {
        'attachments/${n('g.jpg')}': good,
        'attachments/${n('x.jpg')}': 'clinical_attachments/doctorB/p1/${n('x.jpg')}',
        'attachments/${n('y.jpg')}': 'clinical_attachments/$doctorA/p2/${n('y.jpg')}',
      };
      expect(await db.swappedPathsFor(expectedOwner: doctorA, patientId: 'p1'),
          {'attachments/${n('g.jpg')}': good});
    });
  });
}
