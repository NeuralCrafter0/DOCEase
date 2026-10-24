// Security F8-R1: the plain local copy of a picked photo is deleted once its
// Storage upload is confirmed and the visit row has been rewritten to the
// Storage path; never before, and only inside the owner's own folder.
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

/// MergeDb that can refuse (throw) or not confirm (return null) only the
/// rewrite that puts a Storage path into the row.
class _RewriteDb extends MergeDb {
  bool refuseRewrite = false;
  bool rewriteUnconfirmed = false;
  int rewrites = 0;

  static Set<String> _storagePaths(Patient? p) => {
        for (final r in p?.history ?? const <VisitRecord>[])
          for (final e in r.attachmentPaths)
            if (e.startsWith('clinical_attachments/')) e,
      };

  @override
  Future<String?> updatePatient(Patient patient) async {
    if (!_storagePaths(rows[patient.id]).containsAll(_storagePaths(patient))) {
      rewrites++;
      if (refuseRewrite) throw UnsyncedCounterException(doctorA);
      if (rewriteUnconfirmed) return null;
    }
    return super.updatePatient(patient);
  }
}

/// App-generated name (`<uuid v4>.<ext>`) standing for [label].
String n(String label) {
  final h = sha256.convert(utf8.encode(label)).toString();
  final ext = label.substring(label.lastIndexOf('.') + 1);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-4${h.substring(13, 16)}-a${h.substring(17, 20)}-${h.substring(20, 32)}.$ext';
}

VisitRecord visit(String id, List<String> photos) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: 'd', prescription: 'p', attachmentPaths: photos);

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _RewriteDb db;
  late CloudFirestoreHelper remote;
  late FakeStorage storage;
  late PatientProvider provider;

  String photoIn(String dir, String name) {
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, name))..writeAsBytesSync(List.filled(64, 7))).path;
  }

  /// Where PR #8's AttachmentStorage writes a pick: <support>/attachments/<ownerHash>/.
  String pick(String name, {String owner = doctorA}) => photoIn(photos.visitFolderFor(owner)!, n(name));

  List<String> rowPaths(String id) => db.rows[id]!.history.expand((r) => r.attachmentPaths).toList();

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_upload_cleanup');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _RewriteDb()..state = const DbReady(doctorA);
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

  test('confirmed upload + row rewritten to the Storage path: the local copy is deleted', () async {
    await load();
    final a = pick('a.jpg');
    final logs = <String>[];
    await captureLogs(logs, () async {
      await provider.addRecord('p1', visit('v1', [a]));
      await flushMicrotasks();
    });

    final storagePath = storage.uploads.keys.single;
    expect(storagePath, startsWith('clinical_attachments/$doctorA/p1/'));
    expect(rowPaths('p1'), [storagePath], reason: 'row rewritten first');
    expect(remote.payloads.last.history.single.attachmentPaths, [storagePath]);
    expect(File(a).existsSync(), isFalse);
    expect(logs.where((l) => l.startsWith('Photos:')), ['Photos: removed 1 after an upload']);
    expect(logs.join('\n'), isNot(contains(p.basename(a))));
  });

  test('a failed upload keeps the file for the retry; the confirmed retry deletes it', () async {
    await load();
    storage.failUploads = true;
    final a = pick('a.jpg');
    await provider.addRecord('p1', visit('v1', [a]));
    await flushMicrotasks();
    expect(storage.uploads, isEmpty);
    expect(rowPaths('p1'), [a]);
    expect(File(a).existsSync(), isTrue);

    storage.failUploads = false;
    await provider.retryDirty();
    await flushMicrotasks();
    expect(storage.uploads.length, 1);
    expect(rowPaths('p1'), [storage.uploads.keys.single]);
    expect(File(a).existsSync(), isFalse);
  });

  test('upload confirmed but the rewrite refused: the file is kept', () async {
    await load();
    db.refuseRewrite = true;
    final a = pick('a.jpg');
    await provider.addRecord('p1', visit('v1', [a]));
    await flushMicrotasks();
    expect(storage.uploads.length, 1);
    expect(db.rewrites, 1);
    expect(rowPaths('p1'), [a], reason: 'the DB still references the local copy');
    expect(File(a).existsSync(), isTrue);
  });

  test('upload confirmed but the rewrite not confirmed (no version): the file is kept', () async {
    await load();
    db.rewriteUnconfirmed = true;
    final b = pick('b.jpg');
    await provider.addRecord('p1', visit('v2', [b]));
    await flushMicrotasks();
    expect(storage.uploads.length, 1);
    expect(db.rewrites, 1);
    expect(File(b).existsSync(), isTrue);
  });

  test('same owner-folder and regular-file checks: other places are uploaded but never deleted', () async {
    await load();
    final outside = photoIn(p.join(root.path, 'cache'), 'image_picker_1.jpg');
    final theirs = pick('x.jpg', owner: 'doctorB');
    final loose = photoIn(p.join(photos.supportPath!, 'attachments'), n('loose.jpg'));
    final target = photoIn(p.join(root.path, 'elsewhere'), 'target.jpg');
    final link = Link(p.join(photos.visitFolderFor(doctorA)!, n('link.jpg')))..createSync(target, recursive: true);

    await provider.addRecord('p1', visit('v1', [outside, theirs, loose, link.path]));
    await flushMicrotasks();

    expect(storage.uploads.length, 4);
    expect(rowPaths('p1'), everyElement(startsWith('clinical_attachments/$doctorA/p1/')));
    expect(File(outside).existsSync(), isTrue);
    expect(File(theirs).existsSync(), isTrue);
    expect(File(loose).existsSync(), isTrue);
    expect(FileSystemEntity.typeSync(link.path, followLinks: false), FileSystemEntityType.link);
    expect(File(target).existsSync(), isTrue);
  });

  test('a local copy another visit still references is kept', () async {
    final a = pick('a.jpg');
    db.rows['p2'] = testPatient('p2').copyWithHistoryForTest([visit('v9', [a])]);
    await load();
    expect(provider.findById('p2').history.single.attachmentPaths, [a]);

    await provider.addRecord('p1', visit('v1', [a]));
    await flushMicrotasks();

    expect(rowPaths('p1'), [storage.uploads.keys.single]);
    expect(rowPaths('p2'), [a]);
    expect(File(a).existsSync(), isTrue);
  });

  test('source pin: deletion runs only after the rewrite succeeded, through the owner-folder delete', () {
    final s = File('lib/providers/patient_provider.dart').readAsStringSync();
    final put = s.indexOf('.putFile(');
    final rewrite = s.indexOf('sentVersion = await _db.updatePatient(current);');
    final del = s.indexOf("_deleteUnreferencedPhotos(uid, _confirmedUploads(uid, current, replacements), after: 'an upload')");
    expect([put, rewrite, del], everyElement(greaterThan(0)));
    expect(rewrite, lessThan(del));
    expect(s.substring(rewrite, del), contains('if (sentVersion != null && uid != null) {'));
    expect(s, contains('await _photos.deleteOwnedVisitFile(path, owner: owner)'));
  });
}

extension on Patient {
  Patient copyWithHistoryForTest(List<VisitRecord> history) => Patient(
      id: id, name: name, age: age, gender: gender, phone: phone, relation: relation,
      updatedAt: updatedAt, history: history);
}
