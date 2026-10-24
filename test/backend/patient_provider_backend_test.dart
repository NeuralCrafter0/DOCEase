import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/sync_cancel_token.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Patient dirtyPatient(String id, String version, {List<VisitRecord>? history}) => Patient(
    id: id, name: 'P $id', age: '40', gender: 'Male', phone: '+91999$id',
    history: history ?? [], updatedAt: version);

VisitRecord visit(String id, List<String> attachments) => VisitRecord(
    id: id, date: DateTime(2025, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: 'd', prescription: 'p', attachmentPaths: attachments);

void main() {
  late MergeDb db;
  late CloudFirestoreHelper remote;
  late FakeAuth auth;
  late FakeStorage storage;
  late PatientProvider provider;
  late Directory tmp;
  late LocalPhotoStore photos;

  setUp(() {
    db = MergeDb()..state = const DbReady('doctorA');
    remote = CloudFirestoreHelper();
    auth = FakeAuth('doctorA');
    storage = FakeStorage();
    provider = PatientProvider(
        db: db, firestore: remote, auth: auth, storage: storage,
        retryBaseDelay: const Duration(milliseconds: 20),
        retryMaxDelay: const Duration(milliseconds: 80));
    tmp = Directory.systemTemp.createTempSync('docease_backend_test');
    final support = Directory('${tmp.path}/support')..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    provider.dispose();
    provider = PatientProvider(
        db: db, firestore: remote, auth: auth, storage: storage, photos: photos,
        retryBaseDelay: const Duration(milliseconds: 20),
        retryMaxDelay: const Duration(milliseconds: 80));
  });

  tearDown(() {
    provider.dispose();
    tmp.deleteSync(recursive: true);
  });

  var picks = 0;
  /// A pick as the app makes it (PR #8 / LocalPhotoStore):
  /// <support>/attachments/<ownerFolder>/<uuid>.<ext>. Only these are
  /// uploaded and swapped; anything else stays local (security #16).
  Future<String> pick(String ext) async {
    await photos.init();
    final dir = Directory(photos.visitFolderFor('doctorA')!)..createSync(recursive: true);
    final id = (++picks).toRadixString(16).padLeft(12, '0');
    return (File('${dir.path}/0000aaaa-bbbb-4ccc-addd-$id.$ext')..writeAsBytesSync(List.filled(32, 7))).path;
  }

  String file(String name, {int bytes = 32}) {
    final f = File('${tmp.path}/$name')..writeAsBytesSync(List.filled(bytes, 7));
    return f.path;
  }

  void seedDirty(String id, String version, {List<VisitRecord>? history}) {
    db.rows[id] = dirtyPatient(id, version, history: history);
    db.dirty[id] = true;
    db.versions[id] = version;
  }

  group('session gating', () {
    test('does not read local or cloud data until the DB is ready for this uid', () async {
      db.state = const DbOpening('doctorA');
      db.rows['p1'] = testPatient('p1');
      await provider.loadAndSync('doctorA');
      expect(provider.patients, isEmpty);
      expect(remote.fetches, 0);

      db.state = const DbReady('doctorB'); // another doctor's DB
      await provider.loadAndSync('doctorA');
      expect(provider.patients, isEmpty);
      expect(remote.fetches, 0);

      db.state = const DbReady('doctorA');
      await provider.loadAndSync('doctorA');
      expect(provider.patients.map((p) => p.id), ['p1']);
      expect(remote.fetches, 1);
    });

    test('does nothing when the signed-in user is not the open DB\'s doctor', () async {
      db.rows['p1'] = testPatient('p1');
      seedDirty('p2', '3');
      auth.signIn('doctorB'); // DB is still DbReady('doctorA')
      await provider.loadAndSync('doctorA');
      expect(provider.patients, isEmpty);
      expect(remote.fetches, 0);
      expect(remote.synced, isEmpty);

      auth.currentUser = null; // signed out
      await provider.loadAndSync('doctorA');
      await provider.retryDirty();
      expect(remote.fetches, 0);
      expect(remote.synced, isEmpty);
    });

    test('pushes stop when the user changes mid-session', () async {
      await provider.loadAndSync('doctorA');
      auth.signIn('doctorB');
      seedDirty('p2', '3');
      await provider.retryDirty();
      expect(remote.synced, isEmpty);
      expect(db.dirty['p2'], isTrue);
    });

    test('clear() drops data and results of a pull still in flight', () async {
      remote.fetchGate = Completer<List<Patient>>();
      final run = provider.loadAndSync('doctorA', cancel: SyncCancelToken());
      await flushMicrotasks();
      provider.clear();
      remote.fetchGate!.complete([testPatient('cloud1')]);
      await run;
      expect(provider.patients, isEmpty);
      expect(provider.sessionUid, isNull);
      expect(db.rows.containsKey('cloud1'), isFalse, reason: 'old session must not write');
    });

    test('a cancelled token stops the pull from writing', () async {
      final token = SyncCancelToken();
      remote.fetchGate = Completer<List<Patient>>();
      final run = provider.loadAndSync('doctorA', cancel: token);
      await flushMicrotasks();
      token.cancel();
      remote.fetchGate!.complete([testPatient('cloud1')]);
      await run;
      expect(db.rows.containsKey('cloud1'), isFalse);
    });

    test('pull never overwrites an unconfirmed local edit', () async {
      seedDirty('p1', '5');
      remote.syncResult = false; // offline: stays dirty
      remote.cloud = [
        Patient(id: 'p1', name: 'Cloud', age: '1', gender: 'Male', phone: 'x',
            history: [visit('v1', []), visit('v2', [])]),
      ];
      await provider.loadAndSync('doctorA');
      expect(provider.findById('p1').name, 'P p1');
      expect(db.rows['p1']!.name, 'P p1');
    });
  });

  group('cloud merge never overwrites dirty rows', () {
    Patient cloudCopy(String id) => Patient(
        id: id, name: 'Cloud $id', age: '1', gender: 'Male', phone: 'x',
        history: [visit('c1', []), visit('c2', [])]);

    test('a dirty row is skipped, stays dirty with the local value and is pushed by the retry', () async {
      seedDirty('p1', '5');
      remote.syncResult = false; // first push fails (offline)
      remote.cloud = [cloudCopy('p1')];
      final before = await db.unsyncedCount();
      await provider.loadAndSync('doctorA');

      expect(db.rows['p1']!.name, 'P p1');
      expect(provider.findById('p1').name, 'P p1');
      expect(db.dirty['p1'], isTrue, reason: 'never marked synced by the merge');
      expect(db.log.where((l) => l.startsWith('markSynced')), isEmpty);
      expect(await db.unsyncedCount(), before);
      expect(db.applyLog, ['skip:p1'], reason: "the DB's conditional write refuses the dirty row");

      remote.syncResult = true; // back online: retry pushes the LOCAL edit
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flushMicrotasks();
      expect(remote.payloads.last.name, 'P p1');
      expect(db.dirty['p1'], isFalse);
    });

    test('applyCloudPatient returning false (edit raced the merge) is a skip, not an error', () async {
      db.rows['p1'] = testPatient('p1', name: 'Local');
      db.rows['p2'] = testPatient('p2', name: 'Local2');
      remote.cloud = [cloudCopy('p1'), cloudCopy('p2')];
      db.beforeApply = (id) {
        if (id == 'p1') {
          db.rows['p1'] = testPatient('p1', name: 'Edited meanwhile');
          db.dirty['p1'] = true;
        }
      };
      await provider.loadAndSync('doctorA');
      expect(db.applyLog, ['skip:p1', 'apply:p2']);
      expect(db.rows['p1']!.name, 'Edited meanwhile');
      expect(db.dirty['p1'], isTrue);
      expect(provider.findById('p1').name, 'Local', reason: 'not replaced by the cloud copy');
      expect(provider.findById('p2').name, 'Cloud p2', reason: 'clean rows still merge');
      expect(provider.isSyncing, isFalse);
    });

    test('a row edited in this session but not yet confirmed is skipped', () async {
      db.rows['p1'] = testPatient('p1');
      await provider.loadAndSync('doctorA');
      remote.syncResult = false;
      await provider.updatePatient(testPatient('p1', name: 'Unconfirmed'));
      await flushMicrotasks();
      db.dirty['p1'] = false; // even if the DB flag were wrong
      remote.cloud = [cloudCopy('p1')];
      provider.clear();
      // same session continues: reload
      await provider.loadAndSync('doctorA');
      expect(db.applyLog, ['apply:p1'], reason: 'after clear() the in-memory set is reset');
    });

    test('clean rows with more cloud visits are applied as synced', () async {
      db.rows['p1'] = testPatient('p1');
      remote.cloud = [cloudCopy('p1'), cloudCopy('new')];
      await provider.loadAndSync('doctorA');
      expect(db.applyLog, ['apply:p1', 'apply:new']);
      expect(db.dirty['p1'], isFalse);
      expect(provider.patients.map((p) => p.name).toSet(), {'Cloud p1', 'Cloud new'});
    });

    test('if dirty rows cannot be read, nothing is merged', () async {
      db.rows['p1'] = testPatient('p1');
      remote.cloud = [cloudCopy('p1')];
      db.failDirtyRead = true;
      final logs = <String>[];
      final old = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
      try {
        await provider.loadAndSync('doctorA');
      } finally {
        debugPrint = old;
      }
      expect(db.applyLog, isEmpty);
      expect(db.rows['p1']!.name, 'Asha');
      expect(logs.join('\n'), isNot(contains('secret')), reason: 'only sanitized codes are logged');
      expect(logs.join('\n'), contains('DbReadException'), reason: 'the strict read failed');
    });

    test('without applyCloudPatient (interim) a dirty row is still skipped', () async {
      final plain = FakeLocalDatabase()..state = const DbReady('doctorA');
      final r = CloudFirestoreHelper()..syncResult = false;
      final pp = PatientProvider(db: plain, firestore: r, auth: auth, storage: storage);
      plain.rows['p1'] = testPatient('p1', name: 'Local');
      plain.dirty['p1'] = true;
      r.cloud = [cloudCopy('p1')];
      await pp.loadAndSync('doctorA');
      expect(plain.rows['p1']!.name, 'Local');
      expect(plain.dirty['p1'], isTrue);
      pp.dispose();
    });
  });

  group('dirty retry', () {
    test('load pushes dirty rows oldest first and marks them synced', () async {
      seedDirty('p1', '3');
      seedDirty('p2', '4');
      await provider.loadAndSync('doctorA');
      expect(remote.synced, ['p1', 'p2']);
      expect(db.dirty['p1'], isFalse);
      expect(db.dirty['p2'], isFalse);
    });

    test('failed push stays dirty and is retried by the backoff timer', () async {
      seedDirty('p1', '3');
      remote.syncResult = false;
      await provider.loadAndSync('doctorA');
      expect(db.dirty['p1'], isTrue);
      remote.syncResult = true;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flushMicrotasks();
      expect(db.dirty['p1'], isFalse);
    });

    test('retryDirty() (app resume) pushes waiting rows', () async {
      await provider.loadAndSync('doctorA');
      seedDirty('p9', '11');
      await provider.retryDirty();
      expect(remote.synced, contains('p9'));
      expect(db.dirty['p9'], isFalse);
    });

    test('a successful write flushes other rows that were waiting', () async {
      seedDirty('old', '1');
      remote.syncResult = false;
      await provider.loadAndSync('doctorA');
      expect(db.dirty['old'], isTrue);
      remote.syncResult = true;
      await provider.addPatient(testPatient('new'));
      await flushMicrotasks();
      expect(db.dirty['old'], isFalse);
    });

    test('no retry runs after clear()', () async {
      seedDirty('p1', '3');
      remote.syncResult = false;
      await provider.loadAndSync('doctorA');
      final before = remote.synced.length;
      provider.clear();
      remote.syncResult = true;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(remote.synced.length, before);
    });
  });

  group('attachments', () {
    setUp(() async {
      db.rows['p1'] = testPatient('p1');
      await provider.loadAndSync('doctorA');
      remote.payloads.clear();
    });

    test('an unsupported file is rejected by name before anything is saved or uploaded', () async {
      final good = file('scan.jpg');
      final bad = file('notes.pdf');
      await expectLater(
        provider.addRecord('p1', visit('v1', [good, bad])),
        throwsA(isA<UnsupportedAttachmentException>()
            .having((e) => e.fileName, 'fileName', 'notes.pdf')
            .having((e) => e.reason, 'reason', AttachmentRejection.unsupportedType)),
      );
      await flushMicrotasks();
      expect(provider.findById('p1').history, isEmpty);
      expect(db.log.where((l) => l.startsWith('update')), isEmpty);
      expect(storage.uploads, isEmpty);
      expect(remote.payloads, isEmpty);
    });

    test('missing, empty and oversized files are rejected', () async {
      for (final (path, reason) in [
        ('${tmp.path}/gone.jpg', AttachmentRejection.missing),
        (file('empty.png', bytes: 0), AttachmentRejection.empty),
        (file('huge.webp', bytes: AttachmentPolicy.maxAttachmentBytes + 1), AttachmentRejection.tooLarge),
      ]) {
        await expectLater(provider.addRecord('p1', visit('v', [path])),
            throwsA(isA<UnsupportedAttachmentException>().having((e) => e.reason, 'reason', reason)));
      }
      expect(storage.uploads, isEmpty);
    });

    test('picked images upload to the per-patient folder and the visit stores Storage paths', () async {
      final jpg = await pick('jpg');
      final png = await pick('png');
      await provider.addRecord('p1', visit('v1', [jpg, png]));
      await flushMicrotasks();

      expect(storage.uploads.length, 2);
      final paths = storage.uploads.keys.toList();
      expect(paths, everyElement(matches(RegExp(r'^clinical_attachments/doctorA/p1/[0-9a-f-]{36}\.(jpg|png)$'))));
      expect(storage.uploads.values.toSet(), {'image/jpeg', 'image/png'});

      final sent = remote.payloads.last.history.single.attachmentPaths;
      expect(sent, paths, reason: 'Firestore gets Storage paths, never local paths or URLs');
      expect(provider.findById('p1').history.single.attachmentPaths, paths);
      expect(db.rows['p1']!.history.single.attachmentPaths, paths);
    });

    test('a failed upload never puts the local path in Firestore and is retried', () async {
      storage.failUploads = true;
      final jpg = await pick('jpg');
      await provider.addRecord('p1', visit('v1', [jpg]));
      await flushMicrotasks();
      expect(remote.payloads, isNotEmpty);
      expect(remote.payloads.last.history.single.attachmentPaths, isEmpty);
      expect(provider.findById('p1').history.single.attachmentPaths, [jpg]);

      storage.failUploads = false;
      await provider.retryDirty();
      await flushMicrotasks();
      expect(storage.uploads.length, 1);
      expect(remote.payloads.last.history.single.attachmentPaths, [storage.uploads.keys.single]);
    });

    test('local paths read back from storage are never uploaded and are stripped from the cloud copy', () async {
      final stray = file('from_db.jpg');
      seedDirty('p2', '9', history: [
        visit('v1', [
          stray,
          'clinical_attachments/doctorB/p2/x.jpg', // other doctor
          'https://evil.example/x.jpg', // foreign URL
          'clinical_attachments/doctorA/p2/ok.jpg',
        ])
      ]);
      await provider.retryDirty();
      await flushMicrotasks();
      expect(storage.uploads, isEmpty);
      final sent = remote.payloads.lastWhere((p) => p.id == 'p2');
      expect(sent.history.single.attachmentPaths, ['clinical_attachments/doctorA/p2/ok.jpg']);
    });

    test('editing a visit keeps stored entries and validates only new picks', () async {
      seedDirty('p3', '2', history: [visit('v1', ['clinical_attachments/doctorA/p3/old.jpg'])]);
      await provider.loadAndSync('doctorA');
      provider.clear();
      await provider.loadAndSync('doctorA');
      final added = await pick('webp');
      await provider.updateRecord(
          'p3', visit('v1', ['clinical_attachments/doctorA/p3/old.jpg', added]));
      await flushMicrotasks();
      expect(storage.uploads.values.single, 'image/webp');
      expect(remote.payloads.last.history.single.attachmentPaths,
          ['clinical_attachments/doctorA/p3/old.jpg', storage.uploads.keys.single]);
    });

    test('attachmentKind classifies entries for display', () {
      expect(provider.attachmentKind('clinical_attachments/doctorA/p1/a.jpg', 'p1'),
          AttachmentEntryKind.storagePath);
      expect(provider.attachmentKind('clinical_attachments/doctorB/p1/a.jpg', 'p1'),
          AttachmentEntryKind.invalid);
      expect(provider.attachmentKind('https://evil.example/a.jpg', 'p1'), AttachmentEntryKind.invalid);
      expect(provider.attachmentKind('/data/user/0/x/a.jpg', 'p1'), AttachmentEntryKind.localFile);
    });

    test('loadAttachmentBytes only reads this doctor\'s folder', () async {
      storage.objects['clinical_attachments/doctorA/p1/a.jpg'] = Uint8List.fromList([1, 2]);
      storage.objects['clinical_attachments/doctorB/p1/a.jpg'] = Uint8List.fromList([3]);
      expect(await provider.loadAttachmentBytes('clinical_attachments/doctorA/p1/a.jpg'), [1, 2]);
      expect(await provider.loadAttachmentBytes('clinical_attachments/doctorB/p1/a.jpg'), isNull);
    });
  });

  // QA PP-06/PP-07 (REC-RB): a refused visit save must leave memory as it
  // was, so the next successful save cannot write the refused change in.
  group('visit changes roll back when the local save is refused', () {
    List<String> ids(Patient p) => p.history.map((r) => r.id).toList();
    VisitRecord edited(String id, String diagnosis) => VisitRecord(
        id: id, date: DateTime(2025, 1, 2), visitType: 'Consultation', symptoms: 's',
        diagnosis: diagnosis, prescription: 'p', attachmentPaths: const []);

    Future<void> seedAndLoad(List<VisitRecord> history) async {
      db.rows['p1'] = testPatient('p1', history: history);
      db.dirty['p1'] = false;
      db.versions['p1'] = '1';
      await provider.loadAndSync('doctorA');
    }

    test('addRecord: refused visit is not kept and not written by the next save', () async {
      await seedAndLoad([visit('r1', [])]);
      var notified = 0;
      provider.addListener(() => notified++);
      db.refuseUpdates = true;
      await expectLater(provider.addRecord('p1', visit('refused', [])),
          throwsA(isA<UnsyncedCounterException>()));
      expect(ids(provider.findById('p1')), ['r1']);
      expect(notified, greaterThan(0), reason: 'screen is told to rebuild');

      db.refuseUpdates = false;
      await provider.addRecord('p1', visit('r3', []));
      await flushMicrotasks();
      expect(ids(db.rows['p1']!), ['r3', 'r1']);
      expect(ids(provider.findById('p1')), ['r3', 'r1']);
      expect(ids(remote.payloads.last), ['r3', 'r1']);
    });

    test('addRecord: a refused visit with a picked image uploads nothing', () async {
      await seedAndLoad([]);
      db.refuseUpdates = true;
      await expectLater(provider.addRecord('p1', visit('refused', [file('scan.jpg')])),
          throwsA(isA<UnsyncedCounterException>()));
      await flushMicrotasks();
      expect(storage.uploads, isEmpty);
      expect(provider.findById('p1').history, isEmpty);
    });

    test('updateRecord: refused edit keeps the old visit and the next save stores the old one', () async {
      await seedAndLoad([edited('r1', 'original')]);
      db.refuseUpdates = true;
      await expectLater(provider.updateRecord('p1', edited('r1', 'refused edit')),
          throwsA(isA<UnsyncedCounterException>()));
      expect(provider.findById('p1').history.single.diagnosis, 'original');

      db.refuseUpdates = false;
      await provider.addRecord('p1', visit('r2', []));
      await flushMicrotasks();
      expect(ids(db.rows['p1']!), ['r2', 'r1']);
      expect(db.rows['p1']!.history[1].diagnosis, 'original');
      expect(remote.payloads.last.history[1].diagnosis, 'original');
    });

    test('deleteRecord: refused delete keeps the visit and the next save does not drop it', () async {
      await seedAndLoad([visit('r1', []), visit('r2', [])]);
      db.refuseUpdates = true;
      await expectLater(provider.deleteRecord('p1', 'r1'), throwsA(isA<UnsyncedCounterException>()));
      expect(ids(provider.findById('p1')), ['r1', 'r2']);

      db.refuseUpdates = false;
      await provider.addRecord('p1', visit('r3', []));
      await flushMicrotasks();
      expect(ids(db.rows['p1']!), ['r3', 'r1', 'r2']);
    });

    test('a save that writes nothing (null version) is not kept either', () async {
      await seedAndLoad([visit('r1', [])]);
      db.updatesReturnNull = true;
      await expectLater(provider.addRecord('p1', visit('r2', [])),
          throwsA(isA<LocalSaveFailedException>()));
      await expectLater(provider.deleteRecord('p1', 'r1'), throwsA(isA<LocalSaveFailedException>()));
      expect(ids(provider.findById('p1')), ['r1']);
      expect(remote.payloads, isEmpty);
    });

    test('back-to-back visit saves keep both (writes run one at a time)', () async {
      await seedAndLoad([visit('r1', [])]);
      await Future.wait([
        provider.addRecord('p1', visit('r2', [])),
        provider.addRecord('p1', visit('r3', [])),
      ]);
      await flushMicrotasks();
      expect(ids(db.rows['p1']!), ['r3', 'r2', 'r1']);
      expect(ids(provider.findById('p1')), ['r3', 'r2', 'r1']);
    });

    test('an unconfirmed (offline) push does not block the next visit save', () async {
      await seedAndLoad([visit('r1', []), visit('r2', [])]);
      remote.manual = true; // Firestore never answers until completed
      var deleted = false;
      final del = provider.deleteRecord('p1', 'r1').then((_) => deleted = true);
      await flushMicrotasks();
      await provider.addRecord('p1', visit('r3', []));
      expect(ids(db.rows['p1']!), ['r3', 'r2']);
      expect(deleted, isFalse, reason: 'deleteRecord still waits for its push');
      for (final c in remote.inFlight) {
        c.complete(true);
      }
      await del;
      expect(deleted, isTrue);
    });

    test('a refused save does not block the next one in the queue', () async {
      await seedAndLoad([visit('r1', [])]);
      db.refuseUpdates = true;
      final refused = provider.addRecord('p1', visit('refused', []));
      final next = refused.catchError((_) {}).then((_) {
        db.refuseUpdates = false;
        return provider.addRecord('p1', visit('r2', []));
      });
      await expectLater(refused, throwsA(isA<UnsyncedCounterException>()));
      await next;
      expect(ids(db.rows['p1']!), ['r2', 'r1']);
    });
  });

  group('patient delete tombstones', () {
    Future<void> loadWith(String id) async {
      db.rows[id] = testPatient(id);
      db.dirty[id] = false;
      db.versions[id] = '1';
      await provider.loadAndSync('doctorA');
    }

    test('locally only markPendingDelete; tombstone cleared once Firestore confirms', () async {
      await loadWith('p1');
      await provider.deletePatient('p1');
      expect(db.log, contains('markPendingDelete:p1'));
      expect(db.log, isNot(contains('delete:p1')), reason: 'no separate row delete');
      expect(remote.deletes, ['p1']);
      expect(db.log.indexOf('clearPendingDelete:p1'), greaterThan(db.log.indexOf('markPendingDelete:p1')));
      expect(db.tombstones, isEmpty);
      expect(provider.patients, isEmpty);
    });

    test('failed cloud delete keeps the tombstone, counts as unsynced and never resurrects on merge', () async {
      await loadWith('p1');
      remote.deleteResult = false;
      await provider.deletePatient('p1');
      expect(db.tombstones, {'p1'});
      expect(db.log, isNot(contains('clearPendingDelete:p1')));
      expect(await db.unsyncedCount(), const UnsyncedKnown(1));

      // Next launch: the cloud still has p1.
      provider.clear();
      remote.cloud = [testPatient('p1', name: 'Cloud')];
      final next = PatientProvider(db: db, firestore: remote, auth: auth, storage: storage);
      await next.loadAndSync('doctorA');
      expect(next.patients.map((p) => p.id), isNot(contains('p1')));
      expect(db.rows.containsKey('p1'), isFalse);
      expect(db.applyLog, contains('skip:p1'));
      next.dispose();
    });

    test('retried on startup and cleared after confirmation', () async {
      db.tombstones.add('p7');
      await provider.loadAndSync('doctorA');
      expect(remote.deletes, ['p7']);
      expect(db.tombstones, isEmpty);
    });

    test('retried on reconnect (retryDirty) and by the backoff timer', () async {
      await loadWith('p1');
      remote.deleteResult = false;
      await provider.deletePatient('p1');
      await provider.retryDirty();
      expect(db.tombstones, {'p1'});
      remote.deleteResult = true;
      await provider.retryDirty();
      expect(db.tombstones, isEmpty);

      await loadWith('p2');
      remote.deleteResult = false;
      await provider.deletePatient('p2');
      remote.deleteResult = true;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await flushMicrotasks();
      expect(db.tombstones, isEmpty, reason: 'backoff retry');
    });

    test('refused markPendingDelete changes nothing and is reported', () async {
      await loadWith('p1');
      db.refusePendingDelete = true;
      await expectLater(provider.deletePatient('p1'), throwsA(isA<UnsyncedCounterException>()));
      expect(provider.patients.map((p) => p.id), ['p1']);
      expect(db.rows.containsKey('p1'), isTrue);
      expect(remote.deletes, isEmpty);
    });

    test('a failed clearPendingDelete keeps the tombstone; the repeat delete is harmless', () async {
      await loadWith('p1');
      db.failClearPendingDelete = true;
      await provider.deletePatient('p1');
      expect(db.tombstones, {'p1'});
      db.failClearPendingDelete = false;
      await provider.retryDirty();
      expect(remote.deletes, ['p1', 'p1']);
      expect(db.tombstones, isEmpty);
    });

    test('another doctor\'s tombstones are never pushed', () async {
      await provider.loadAndSync('doctorA');
      db.tombstones.add('p1');
      auth.signIn('doctorB');
      await provider.retryDirty();
      expect(remote.deletes, isEmpty);
      expect(db.tombstones, {'p1'});
    });
  });
}
