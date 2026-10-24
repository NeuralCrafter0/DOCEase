import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_attachment_files.dart';
import 'package:docease/services/session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// A fake device layout under one temp folder:
///   docs/attachments  picked-photo directory (PR #8 writes `<uuid>.jpg` here)
///   docs              rest of app documents (NOT allowed)
///   cache, support    app temp/cache and support directories (allowed)
///   outside           anything else on the phone (never touched)
class Layout {
  Layout() : root = Directory.systemTemp.createTempSync('docease_files_test') {
    for (final d in [picked, cache, support, outside]) {
      d.createSync(recursive: true);
    }
  }

  final Directory root;
  Directory get docs => Directory(p.join(root.path, 'docs'));
  Directory get picked => Directory(p.join(docs.path, LocalAttachmentFiles.pickedPhotoSubdir));
  Directory get cache => Directory(p.join(root.path, 'cache'));
  Directory get support => Directory(p.join(root.path, 'support'));
  Directory get outside => Directory(p.join(root.path, 'outside'));

  LocalAttachmentFiles files() => LocalAttachmentFiles(
        appRoots: () async => [cache, support],
        pickedPhotoDirectory: () async => picked,
      );

  String write(Directory dir, String name, {int bytes = 32}) {
    final f = File(p.join(dir.path, name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 7));
    return f.path;
  }

  void dispose() => root.deleteSync(recursive: true);
}

bool exists(String path) => File(path).existsSync();

/// File checks and deletes are real async I/O, which flushMicrotasks does not
/// wait for. Poll until [done] holds (fails after 5 s).
Future<void> until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not reached in 5 s');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Lets pending real I/O and microtasks finish before asserting that
/// something did NOT happen.
Future<void> settleIo() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await flushMicrotasks();
  }
}

VisitRecord visit(String id, List<String> attachments) => VisitRecord(
    id: id, date: DateTime(2025, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: 'd', prescription: 'p', attachmentPaths: attachments);

void main() {
  late Layout fs;
  setUp(() => fs = Layout());
  tearDown(() => fs.dispose());

  group('LocalAttachmentFiles: only app-owned files are ever deleted', () {
    test('deletes files inside the picked-photo, cache and support directories', () async {
      final files = fs.files();
      for (final dir in [fs.picked, fs.cache, fs.support]) {
        final f = fs.write(dir, 'a.jpg');
        expect(await files.deleteIfAppOwned(f), isTrue, reason: dir.path);
        expect(exists(f), isFalse);
      }
    });

    test('never deletes anything outside those directories', () async {
      final files = fs.files();
      final outside = fs.write(fs.outside, 'gallery.jpg');
      final docsRoot = fs.write(fs.docs, 'other_app_data.jpg'); // documents, not attachments/
      final traversal = p.join(fs.picked.path, '..', '..', 'outside', 'gallery.jpg');
      final nested = fs.write(fs.cache, 'sub/deeper.jpg'); // allowed: still inside cache
      for (final path in [
        outside,
        docsRoot,
        traversal,
        'outside/gallery.jpg', // relative
        'https://firebasestorage.googleapis.com/v0/b/x/o/a.jpg',
        'clinical_attachments/doctorA/p1/a.jpg',
        '',
        fs.picked.path, // a directory
        fs.root.path,
      ]) {
        expect(await files.deleteIfAppOwned(path), isFalse, reason: path);
      }
      expect(exists(outside), isTrue);
      expect(exists(docsRoot), isTrue);
      expect(fs.picked.existsSync(), isTrue);
      expect(await files.deleteIfAppOwned(nested), isTrue);
    });

    test('never follows a symlink out of an app directory', () async {
      final files = fs.files();
      final target = fs.write(fs.outside, 'gallery.jpg');
      final fileLink = Link(p.join(fs.picked.path, 'link.jpg'))..createSync(target);
      final dirLink = Link(p.join(fs.cache.path, 'linked'))..createSync(fs.outside.path);
      final viaDirLink = p.join(dirLink.path, 'gallery.jpg');

      expect(await files.deleteIfAppOwned(fileLink.path), isFalse);
      expect(await files.deleteIfAppOwned(viaDirLink), isFalse);
      expect(await files.purgePickedPhotos(), 0);
      expect(exists(target), isTrue);
      expect(fileLink.existsSync(), isTrue);
    });

    test('with no app directories known (e.g. no path_provider), nothing is deleted', () async {
      final files = LocalAttachmentFiles(
          appRoots: () async => [], pickedPhotoDirectory: () async => null);
      final f = fs.write(fs.picked, 'a.jpg');
      expect(await files.deleteIfAppOwned(f), isFalse);
      expect(await files.purgePickedPhotos(), 0);
      expect(exists(f), isTrue);
    });

    test('purgePickedPhotos deletes only .jpg/.jpeg files directly in the picked-photo directory', () async {
      final a = fs.write(fs.picked, '0b0e6a1c-1f0e-4a4b-9a57-2f1f3c1d2e3f.jpg');
      final b = fs.write(fs.picked, 'B.JPEG');
      final other = fs.write(fs.picked, 'notes.txt');
      final sub = fs.write(fs.picked, 'sub/c.jpg');
      final cached = fs.write(fs.cache, 'c.jpg');
      final outside = fs.write(fs.outside, 'd.jpg');

      expect(await fs.files().purgePickedPhotos(), 2);
      expect([a, b].map(exists), [false, false]);
      expect([other, sub, cached, outside].map(exists), everyElement(isTrue));
    });

    test('purgePickedPhotos copes with a missing directory', () async {
      fs.picked.deleteSync(recursive: true);
      expect(await fs.files().purgePickedPhotos(), 0);
    });
  });

  group('PatientProvider deletes the local copy after a confirmed upload', () {
    late MergeDb db;
    late CloudFirestoreHelper remote;
    late FakeStorage storage;
    late PatientProvider provider;

    setUp(() async {
      db = MergeDb()..state = const DbReady('doctorA');
      remote = CloudFirestoreHelper();
      storage = FakeStorage();
      provider = PatientProvider(
          db: db, firestore: remote, auth: FakeAuth('doctorA'), storage: storage,
          localFiles: fs.files(),
          retryBaseDelay: const Duration(hours: 1), // retries only when the test asks
          retryMaxDelay: const Duration(hours: 1));
      db.rows['p1'] = testPatient('p1');
      await provider.loadAndSync('doctorA');
    });
    tearDown(() => provider.dispose());

    test('deleted once uploaded and the visit is saved with the Storage path', () async {
      final photo = fs.write(fs.picked, 'photo.jpg');
      await provider.addRecord('p1', visit('v1', [photo]));
      await settleIo();

      final storagePath = storage.uploads.keys.single;
      expect(db.rows['p1']!.history.single.attachmentPaths, [storagePath]);
      await until(() => !exists(photo));
    });

    test('also deleted when only the Firestore push fails (the Storage path is saved locally)', () async {
      remote.syncResult = false; // Firestore push fails
      final photo = fs.write(fs.picked, 'photo.jpg');
      await provider.addRecord('p1', visit('v1', [photo]));
      await settleIo();
      expect(db.rows['p1']!.history.single.attachmentPaths, [storage.uploads.keys.single]);
      await until(() => !exists(photo));
    });

    test('kept when the upload fails, so the in-session retry can upload it', () async {
      storage.failUploads = true;
      final photo = fs.write(fs.picked, 'photo.jpg');
      await provider.addRecord('p1', visit('v1', [photo]));
      await settleIo();
      expect(storage.uploads, isEmpty);
      expect(exists(photo), isTrue);
      expect(db.rows['p1']!.history.single.attachmentPaths, [photo]);

      storage.failUploads = false;
      await provider.retryDirty();
      await settleIo();
      expect(storage.uploads.length, 1);
      await until(() => !exists(photo)); // deleted after the retry succeeded
    });

    test('kept when uploaded but the Storage path could not be saved locally', () async {
      storage.failUploads = true;
      final photo = fs.write(fs.picked, 'photo.jpg');
      await provider.addRecord('p1', visit('v1', [photo]));
      await settleIo();

      storage.failUploads = false;
      db.updatesReturnNull = true; // the local save of the Storage path is refused
      await provider.retryDirty();
      await settleIo();
      expect(storage.uploads.length, 1);
      expect(exists(photo), isTrue);
    });

    test('an uploaded file outside the app directories is never deleted', () async {
      final elsewhere = fs.write(fs.outside, 'photo.jpg');
      final docsRoot = fs.write(fs.docs, 'photo2.jpg');
      await provider.addRecord('p1', visit('v1', [elsewhere, docsRoot]));
      await settleIo();
      expect(storage.uploads.length, 2);
      expect(db.rows['p1']!.history.single.attachmentPaths, storage.uploads.keys.toList());
      expect(exists(elsewhere), isTrue);
      expect(exists(docsRoot), isTrue);
    });
  });

  group('SessionController removes leftover picked photos', () {
    late StreamController<User?> auth;
    late List<String> log;
    late SessionController c;

    setUp(() {
      log = [];
      auth = StreamController<User?>.broadcast();
      c = SessionController(
        authStateChanges: auth.stream,
        db: SessionDb(),
        patients: SpyPatients(log),
        doctor: SpyDoctor(log),
        medicines: SpyMedicines(log),
        platform: FakeSessionPlatform(log),
        localFiles: fs.files(),
        observeAppLifecycle: false,
      );
    });
    tearDown(() async {
      c.dispose();
      await auth.close();
    });

    Future<void> emit(User? u) async {
      auth.add(u);
      for (var i = 0; i < 5; i++) {
        await flushMicrotasks();
        await c.idle;
      }
    }

    test('on sign-out, and only in the picked-photo directory', () async {
      await emit(FakeUser('a'));
      expect(c.phase, SessionPhase.ready);
      final leftover = fs.write(fs.picked, 'left.jpg');
      final cached = fs.write(fs.cache, 'keep.jpg');
      final outside = fs.write(fs.outside, 'keep.jpg');

      await emit(null);
      expect(c.phase, SessionPhase.signedOut);
      expect(exists(leftover), isFalse);
      expect(exists(cached), isTrue);
      expect(exists(outside), isTrue);
    });

    test('on account switch, before the next doctor is loaded', () async {
      await emit(FakeUser('a'));
      final leftover = fs.write(fs.picked, 'left.jpg');
      await emit(FakeUser('b'));
      expect(c.phase, SessionPhase.ready);
      expect(c.uid, 'b');
      expect(exists(leftover), isFalse);
    });

    test('not on a token refresh for the same doctor', () async {
      await emit(FakeUser('a'));
      final inUse = fs.write(fs.picked, 'in_use.jpg');
      await emit(FakeUser('a'));
      expect(exists(inUse), isTrue);
    });

    test('on a cold start that is already signed out', () async {
      final leftover = fs.write(fs.picked, 'left.jpg');
      await emit(null);
      expect(c.phase, SessionPhase.signedOut);
      expect(exists(leftover), isFalse);
    });
  });
}
