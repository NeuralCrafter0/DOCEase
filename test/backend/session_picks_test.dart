// Security #16 L-1: a visit form opened before a photo was removed must not
// bring it back. A save only accepts a local app photo that is already in
// the stored row (or mapped by #10's swappedPathsFor) or was registered
// this session for that patient through
// PatientProvider.registerPickedAttachment (PR #8's copy step calls it).
// Anything else is dropped silently (count-only log) and left on disk for
// the sweep.
//
// Registry guards (security): scoped by owner and patient; an entry goes
// as soon as a save stores it, a swap replaces it, or its patient is
// deleted; cleared on session end.
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

/// App-generated name (`<uuid v4>.<ext>`) standing for [label].
String n(String label) {
  final h = sha256.convert(utf8.encode(label)).toString();
  final ext = label.substring(label.lastIndexOf('.') + 1);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}.$ext';
}

VisitRecord visit(String id, List<String> photos, {String diagnosis = 'd'}) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: diagnosis, prescription: 'p', attachmentPaths: photos);

class _Db extends MergeDb {
  /// When set, the next updatePatient throws it (nothing written).
  Object? updateThrowsOnce;

  @override
  Future<String?> updatePatient(Patient patient) async {
    final e = updateThrowsOnce;
    if (e != null) {
      updateThrowsOnce = null;
      throw e;
    }
    return super.updatePatient(patient);
  }
}

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _Db db;
  late CloudFirestoreHelper remote;
  late FakeStorage storage;
  late PatientProvider provider;

  /// A photo file in [owner]'s visit folder, as #8's copy step writes it.
  /// Not registered: tests register explicitly.
  String photoFile(String name, {String owner = doctorA}) {
    final dir = photos.visitFolderFor(owner)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, n(name)))..writeAsBytesSync(List.filled(64, 7))).path;
  }

  /// #8's flow: copy into attachments/<owner>/, then register.
  String pick(String name, {String patientId = 'p1'}) {
    final path = photoFile(name);
    provider.registerPickedAttachment(patientId: patientId, localPath: path);
    return path;
  }

  List<String> rowPaths(String id) => db.rows[id]!.history.expand((r) => r.attachmentPaths).toList();
  bool registered(String patientId, String path) => provider.isRegisteredPickForTesting(patientId, path);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_session_picks');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _Db()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1');
    db.rows['p2'] = testPatient('p2');
    remote = CloudFirestoreHelper();
    storage = FakeStorage();
    provider = PatientProvider(
        db: db, firestore: remote, auth: FakeAuth(doctorA), storage: storage, photos: photos,
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(doctorA);
    await provider.backgroundIdleForTesting();
  });

  tearDown(() {
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  group('L-1: a photo removed while its file is still on the device stays removed', () {
    test('uploaded photo: saving the old form makes no new Storage object', () async {
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a], diagnosis: 'dx-old'));
      final oldForm = provider.findById('p1').history.single; // holds L
      await provider.backgroundIdleForTesting();
      final s = rowPaths('p1').single;
      expect(s, startsWith('clinical_attachments/$doctorA/p1/'), reason: 'precondition: uploaded');

      // A newer form removes the photo.
      await provider.updateRecord('p1', visit('v1', const [], diagnosis: 'dx-removed'));
      await provider.backgroundIdleForTesting();
      expect(rowPaths('p1'), isEmpty);
      // The file is still on the device (e.g. a delete that did not happen).
      File(a).writeAsBytesSync(List.filled(64, 7));
      final uploads = storage.uploads.length;
      final puts = storage.puts;

      final logs = <String>[];
      await captureLogs(logs, () async {
        await provider.updateRecord('p1', visit('v1', oldForm.attachmentPaths, diagnosis: 'dx-stale'));
        await provider.backgroundIdleForTesting();
        await provider.syncNowForTesting();
        await provider.backgroundIdleForTesting();
      });

      expect(storage.uploads.length, uploads, reason: 'no new Storage object');
      expect(storage.puts, puts);
      expect(rowPaths('p1'), isEmpty, reason: 'the photo stays removed');
      expect(db.rows['p1']!.history.single.diagnosis, 'dx-stale', reason: 'the rest of the edit is saved');
      expect(provider.findById('p1').history.single.attachmentPaths, isEmpty);
      expect(remote.payloads.last.history.single.attachmentPaths, isEmpty);
      expect(File(a).existsSync(), isTrue, reason: 'left for the sweep');
      expect(logs, contains('Photos: 1 photo(s) not picked this session left out of a save'));
      expect(logs.join('\n'), isNot(contains(p.basename(a))));
    });

    test('photo not uploaded yet (upload failing): the old form does not bring it back', () async {
      storage.failUploads = true;
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      await provider.backgroundIdleForTesting();
      final oldForm = provider.findById('p1').history.single;
      expect(rowPaths('p1'), [a], reason: 'precondition: still local');

      await provider.updateRecord('p1', visit('v1', const []));
      await provider.backgroundIdleForTesting();
      File(a).writeAsBytesSync(List.filled(64, 7)); // still on the device
      storage.failUploads = false;

      await provider.updateRecord('p1', visit('v1', oldForm.attachmentPaths));
      await provider.syncNowForTesting();
      await provider.backgroundIdleForTesting();
      expect(rowPaths('p1'), isEmpty);
      expect(storage.uploads, isEmpty, reason: 'never uploaded');
    });

    test('an addRecord naming an unregistered app photo leaves it out', () async {
      final stray = photoFile('stray.jpg');
      storage.failUploads = true;
      await provider.addRecord('p1', visit('v1', [stray]));
      await provider.backgroundIdleForTesting();
      expect(rowPaths('p1'), isEmpty);
      expect(File(stray).existsSync(), isTrue);
    });

    test("another owner's photo is never accepted, even if registered", () async {
      final theirs = photoFile('theirs.jpg', owner: 'doctorB');
      provider.registerPickedAttachment(patientId: 'p1', localPath: theirs);
      expect(registered('p1', theirs), isFalse);
      await provider.addRecord('p1', visit('v1', [theirs]));
      await provider.backgroundIdleForTesting();
      expect(rowPaths('p1'), isEmpty);
      expect(File(theirs).existsSync(), isTrue);
    });

    test('pre-#8 picker output outside the app folders is still accepted (existing screens)', () async {
      storage.failUploads = true;
      final cache = Directory(p.join(root.path, 'cache'))..createSync();
      final raw = (File(p.join(cache.path, 'image_picker_1.jpg'))..writeAsBytesSync(List.filled(64, 7))).path;
      await provider.addRecord('p1', visit('v1', [raw]));
      await provider.backgroundIdleForTesting();
      expect(rowPaths('p1'), [raw]);
    });
  });

  group('registry guard 1: scoped by owner and patient', () {
    test("a pick registered for p1 does not count for p2's saves", () async {
      storage.failUploads = true; // keep paths local, so the rows show them
      final a = pick('a.jpg', patientId: 'p1');
      await provider.addRecord('p2', visit('v2', [a]));
      expect(rowPaths('p2'), isEmpty, reason: "not p2's pick");
      expect(registered('p1', a), isTrue, reason: "p2's save does not consume p1's entry");
      await provider.addRecord('p1', visit('v1', [a]));
      expect(rowPaths('p1'), [a]);
    });

    test('cleared on session end: a pick from the old session is not accepted', () async {
      storage.failUploads = true;
      final a = pick('a.jpg');
      expect(registered('p1', a), isTrue);
      provider.clear(); // sign-out / account switch
      await provider.loadAndSync(doctorA);
      await provider.backgroundIdleForTesting();
      expect(registered('p1', a), isFalse);
      await provider.addRecord('p1', visit('v1', [a]));
      expect(rowPaths('p1'), isEmpty);
    });

    test('nothing is registered without an open owner', () async {
      final a = photoFile('a.jpg');
      provider.clear();
      provider.registerPickedAttachment(patientId: 'p1', localPath: a);
      await provider.loadAndSync(doctorA);
      expect(registered('p1', a), isFalse);
    });
  });

  group('registry guard 2: an entry goes once consumed or the photo goes', () {
    test('once a save stores the path, the stored row is the source of truth', () async {
      storage.failUploads = true;
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      expect(registered('p1', a), isFalse);
      expect(rowPaths('p1'), [a]);
      // A form opened before a removal cannot find it "picked this session".
      final oldForm = provider.findById('p1').history.single;
      await provider.updateRecord('p1', visit('v1', const []));
      await provider.backgroundIdleForTesting();
      File(a).writeAsBytesSync(List.filled(64, 7));
      await provider.updateRecord('p1', visit('v1', oldForm.attachmentPaths));
      expect(rowPaths('p1'), isEmpty);
    });

    test('after the upload swap the local entry is gone', () async {
      final a = pick('a.jpg');
      await provider.addRecord('p1', visit('v1', [a]));
      await provider.backgroundIdleForTesting();
      expect(rowPaths('p1').single, startsWith('clinical_attachments/'));
      expect(registered('p1', a), isFalse);
    });

    test('a pick still open in a form is kept across another save, then goes with its patient', () async {
      storage.failUploads = true;
      final a = pick('a.jpg');
      final b = pick('b.jpg'); // picked in a form that is still open
      await provider.addRecord('p1', visit('v1', [a]));
      expect(registered('p1', a), isFalse);
      expect(registered('p1', b), isTrue, reason: 'not stored yet');
      await provider.deleteRecord('p1', 'v1');
      expect(registered('p1', b), isTrue);
      await provider.deletePatient('p1');
      expect(registered('p1', b), isFalse, reason: 'its patient is deleted');
    });

    test('a refused save keeps the entry, so the retry still works', () async {
      storage.failUploads = true;
      final a = pick('a.jpg');
      db.updateThrowsOnce = StateError('disk full');
      await expectLater(provider.addRecord('p1', visit('v1', [a])), throwsA(anything));
      expect(registered('p1', a), isTrue);
      expect(rowPaths('p1'), isEmpty);
      await provider.addRecord('p1', visit('v1', [a]));
      expect(rowPaths('p1'), [a]);
      expect(registered('p1', a), isFalse);
    });
  });
}
