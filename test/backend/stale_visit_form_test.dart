// STALE-05 (QA): the visit edit form saves the photo list it captured when
// it opened. If that visit's upload confirmed meanwhile (#10 swapped L -> S
// and F8-R1 deleted L), updateRecord maps L to S through #10's strict
// swappedPathsFor before the file-exists check, inside the per-patient
// lock. Only genuinely missing, unswapped local paths are refused; a read
// failure refuses the save and writes nothing. Removing a photo in the form
// (stale L or S) leaves no reference to it.
//
// swappedPathsFor is #10's (b217f46); MergeDb only records calls and
// injects failures.
import 'dart:async';
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

class _CountingDb extends MergeDb {
  int rowWrites = 0;

  /// When set, the next updatePatient completes [entered] and waits for
  /// [release] before writing (hook-gated: no timers).
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<String?> updatePatient(Patient patient) async {
    rowWrites++;
    final gate = release;
    if (gate != null) {
      release = null;
      entered?.complete();
      await gate.future;
    }
    return super.updatePatient(patient);
  }
}

/// Runs queued microtasks only (no timers): enough for any purely
/// future-chained step (the patient lock queue) to advance.
Future<void> drainMicrotasks() async {
  for (var i = 0; i < 200; i++) {
    await Future<void>.value();
  }
}

void main() {
  late Directory root;
  late LocalPhotoStore photos;
  late _CountingDb db;
  late CloudFirestoreHelper remote;
  late FakeStorage storage;
  late PatientProvider provider;

  /// A pick as #8 makes it, registered after its copy (security #16 L-1).
  String pick(String name, {String patientId = 'p1'}) {
    final dir = photos.visitFolderFor(doctorA)!;
    Directory(dir).createSync(recursive: true);
    final path = (File(p.join(dir, n(name)))..writeAsBytesSync(List.filled(64, 7))).path;
    provider.registerPickedAttachment(patientId: patientId, localPath: path);
    return path;
  }

  String keyOf(String local) => AttachmentRefs.attachmentKey(local,
      ownerFolderName: LocalPhotoStore.ownerFolderName(doctorA))!;

  /// The Storage path #10 recorded for [local].
  String storageFor(String local) => db.swaps['p1']![keyOf(local)]!;

  VisitRecord storedV1() => db.rows['p1']!.history.singleWhere((v) => v.id == 'v1');

  /// Deterministic: completes when the provider's background work (pushes,
  /// uploads, swaps, deletes) has finished, then checks [done].
  Future<void> until(bool Function() done) async {
    await provider.backgroundIdleForTesting();
    expect(done(), isTrue, reason: 'state after the background work finished');
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
      // Picked this session (so not dropped by L-1), but its file is gone.
      provider.registerPickedAttachment(patientId: 'p1', localPath: ghost);
      final before = storedV1().attachmentPaths;
      final writes = db.rowWrites;

      await expectLater(provider.updateRecord('p1', edited(form, [a, ghost])),
          throwsA(isA<UnsupportedAttachmentException>()
              .having((e) => '$e', 'reason', contains('missing'))));
      await provider.backgroundIdleForTesting();
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
      await provider.backgroundIdleForTesting();

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
      await provider.backgroundIdleForTesting();
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

  group('security L-3: a queued stale save cannot undo a removal', () {
    /// Starts save A held inside its DB write (so it holds the patient lock)
    /// and returns it with its release.
    Future<(Future<void>, Completer<void>)> holdInsideLock(Future<void> Function() save) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      db.entered = entered;
      db.release = release;
      final a = save();
      await entered.future; // A is inside the lock, between read and write
      return (a, release);
    }

    test('photo removed in save A while save B (stale form holding L) is queued: stays removed', () async {
      final a = pick('a.jpg');
      final b = pick('b.jpg');
      final staleForm = await uploadedWhileFormOpen([a, b]); // holds L for both
      final sa = storageFor(a);
      final sb = storageFor(b);

      // A: a fresh form removes photo b (holds S for both).
      final fresh = provider.findById('p1').history.single;
      final (saveA, releaseA) =
          await holdInsideLock(() => provider.updateRecord('p1', edited(fresh, [sa], dx: 'dx-A')));
      // B: queued behind A; its stale form still holds La and Lb.
      final saveB = provider.updateRecord('p1', edited(staleForm, [a, b], dx: 'dx-B'));
      await drainMicrotasks(); // B gets every chance to move; A still holds the lock
      expect(db.rowWrites, 1 + 1, reason: 'B has not reached the DB: it waits for the lock');
      final uploadsBefore = storage.uploads.length;
      releaseA.complete();
      await saveA;
      expect(db.swaps['p1']!.containsKey(keyOf(b)), isFalse, reason: '#10 2414a7a dropped b\'s mapping');

      // B reads the stored row and swaps inside the lock, after A: La maps
      // to Sa; Lb has no mapping, is not in the row and was not picked this
      // session (its pick was consumed by the first save), so L-1 drops it
      // silently. B's edit saves without b.
      await saveB;
      await provider.backgroundIdleForTesting();

      expect(storage.uploads.length, uploadsBefore, reason: 'b is not uploaded again');
      expect(storedV1().attachmentPaths, [sa]);
      expect(storedV1().diagnosis, 'dx-B');
      expect(provider.findById('p1').history.single.attachmentPaths, [sa]);
      expect(storedV1().attachmentPaths, isNot(contains(sb)));
      expect(storedV1().attachmentPaths, isNot(contains(b)));
    });

    test('same race, stale form B holds S of the removed photo: not restored, B\'s edit kept', () async {
      final a = pick('a.jpg');
      final b = pick('b.jpg');
      await uploadedWhileFormOpen([a, b]);
      final sa = storageFor(a);
      final sb = storageFor(b);
      final opened = provider.findById('p1').history.single; // both forms open now: [Sa, Sb]

      final (saveA, releaseA) =
          await holdInsideLock(() => provider.updateRecord('p1', edited(opened, [sa], dx: 'dx-A')));
      final saveB = provider.updateRecord('p1', edited(opened, [sa, sb], dx: 'dx-B'));
      releaseA.complete();
      await saveA;
      final logs = <String>[];
      await captureLogs(logs, () async {
        await saveB;
        await provider.backgroundIdleForTesting();
      });

      expect(storedV1().attachmentPaths, [sa], reason: 'Sb removed by A stays removed');
      expect(storedV1().diagnosis, 'dx-B', reason: 'B\'s other edits are saved');
      expect(provider.findById('p1').history.single.attachmentPaths, [sa]);
      expect(logs, contains('Photos: 1 removed photo(s) not restored by a stale save'));
      expect(logs.join('\n'), isNot(contains(sb)), reason: 'logs carry counts only');
    });

    test('a cloud pull waits for the same lock: it never lands between a save\'s read and write', () async {
      final a = pick('a.jpg');
      await uploadedWhileFormOpen([a]);
      final sa = storageFor(a);
      final opened = provider.findById('p1').history.single;
      // The cloud has an extra visit, so the pull would apply its copy.
      remote.cloud = [testPatient('p1', history: [visit('v1', [sa]), visit('v9', const [])])];
      final fetch = Completer<List<Patient>>();
      remote.fetchGate = fetch;
      db.applyLog.clear();

      final (saveA, releaseA) =
          await holdInsideLock(() => provider.updateRecord('p1', edited(opened, [sa], dx: 'dx-A')));
      final pull = provider.syncNowForTesting();
      await drainMicrotasks();
      fetch.complete(remote.cloud);
      await drainMicrotasks();
      expect(db.applyLog, isEmpty, reason: 'the pull waits while A holds the lock');

      releaseA.complete();
      await saveA;
      await pull;
      await provider.backgroundIdleForTesting();
      // The snapshot predates A's save: the provider keeps local (M-1 save
      // sequence) before asking the DB, which would refuse it too (dirty).
      expect(db.applyLog.where((e) => e == 'apply:p1'), isEmpty,
          reason: 'after A the cloud copy is refused');
      expect(storedV1().diagnosis, 'dx-A');
    });

    test('order reversed (B first, then A removes): ends removed too', () async {
      final a = pick('a.jpg');
      final b = pick('b.jpg');
      final staleForm = await uploadedWhileFormOpen([a, b]);
      final sa = storageFor(a);
      final (saveB, releaseB) =
          await holdInsideLock(() => provider.updateRecord('p1', edited(staleForm, [a, b], dx: 'dx-B')));
      final fresh = provider.findById('p1').history.single;
      final saveA = provider.updateRecord('p1', edited(fresh, [sa], dx: 'dx-A'));
      releaseB.complete();
      await saveB;
      await saveA;
      await provider.backgroundIdleForTesting();
      expect(storedV1().attachmentPaths, [sa]);
      expect(storedV1().diagnosis, 'dx-A');
    });
  });

  test('lock audit (source pin): every local DB write runs under the per-patient lock', () {
    final src = File('lib/providers/patient_provider.dart').readAsStringSync();
    const writes = [
      '_db.insertPatient(', '_db.updatePatient(', '_db.applyCloudPatient(',
      '_db.swapAttachmentPath(', '_db.markPendingDelete(',
      '_db.markSynced(', '_db.clearPendingDelete(',
    ];
    final member = RegExp(r'^  [A-Za-z_][A-Za-z_<>?,() ]*[ ]([_a-zA-Z]+)[<(]', multiLine: true);
    final seen = <String>{};
    for (final w in writes) {
      for (var at = src.indexOf(w); at != -1; at = src.indexOf(w, at + 1)) {
        final m = member.allMatches(src.substring(0, at)).last;
        final name = m.group(1)!;
        seen.add(name);
        if (name == '_swapPath') {
          // Only called from _swapUploaded, inside its lock (pinned in
          // upload_cleanup_test).
          expect('_swapPath('.allMatches(src).length, 2, reason: 'definition + one call');
          continue;
        }
        expect(src.substring(m.start, at), contains('_underPatientLock('),
            reason: '$w in $name must run under the per-patient lock');
      }
    }
    expect(seen, containsAll(['addPatient', 'updatePatientDetails', 'deletePatient',
        '_mutateHistory', '_applyCloud', '_swapPath', '_syncOne', '_confirmCloudDelete']));
    // No whole-row write-back in the sync/upload path: _syncOne and the
    // upload helpers never call updatePatient / insertPatient.
    for (final fn in ['_syncOne', '_uploadPending', '_swapUploaded', '_pushDirty',
        '_pushPendingDeletes', '_confirmCloudDelete', '_afterLocalWriteNow']) {
      final start = src.indexOf(RegExp('^  [^\\n]*[ ]$fn[<(]', multiLine: true));
      expect(start, isNot(-1), reason: fn);
      final next = member.allMatches(src).firstWhere((m) => m.start > start).start;
      final body = src.substring(start, next);
      expect(body, isNot(contains('_db.updatePatient(')), reason: '$fn writes no whole row');
      expect(body, isNot(contains('_db.insertPatient(')), reason: '$fn writes no whole row');
    }
  });
}
