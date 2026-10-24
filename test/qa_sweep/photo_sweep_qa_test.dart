// QA photo-sweep regression suite, part 2: PhotoSweep (#16) and the
// provider's delete-time cleanup. Needs #16 merged (lib/services/
// photo_sweep.dart). Part 1 (key contract, runs without #16) is
// test/qa_sweep/attachment_keys_contract_qa_test.dart.
//
// Every scenario runs through the app's own wiring (support/
// app_sweep_wiring.dart mirrors PhotoSweep.forApp(); since a8eaf9e the
// sweep takes keys and references from the DB: #10's
// referencedAttachmentKeys + AttachmentRefs.attachmentKey). SWP-00 pins
// forApp() and the absence of the old stand-ins. Scan failures are injected
// into the fake DB (refsOverride / readsFail), never around it.
//
// IDs: SWP-xx. No Firebase. Runs in both suite modes.
import 'dart:io';
import 'dart:isolate';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/patient_load_status.dart';
import 'package:docease/services/photo_sweep.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';
import 'support/app_sweep_wiring.dart';

const ownerA = 'doctorA';
const ownerB = 'doctorB';
const secretName = 'Priya_Sharma';

final firebaseHits = <String>[];

class _TripAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation i) {
    firebaseHits.add('auth.${i.memberName}');
    throw StateError('FirebaseAuth touched');
  }
}

class _TripStorage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    firebaseHits.add('storage.${i.memberName}');
    throw StateError('Storage touched');
  }
}

class _TripHelper extends FakeFirestoreHelper {
  @override
  Future<bool> syncPatient(Patient patient) async {
    firebaseHits.add('helper.sync');
    return false;
  }

  @override
  Future<bool> deletePatient(String patientId) async {
    firebaseHits.add('helper.delete');
    return false;
  }
}

VisitRecord _visit(String id, List<String> photos) => VisitRecord(
    id: id,
    date: DateTime(2026, 1, 2),
    visitType: 'Consultation',
    symptoms: 'cough',
    diagnosis: 'cold',
    prescription: 'rest',
    attachmentPaths: photos);

Patient _patient(String id, List<VisitRecord> history) => Patient(
    id: id,
    name: 'Test $id',
    age: '30',
    gender: 'Female',
    phone: '+9100000',
    history: history);

DateTime _later() => DateTime.now().add(const Duration(hours: 1));

enum Wiring { app }

/// The shared fake has no refusal knob for updatePatient; this one throws
/// the way a failed counter increment does (DB refused the save).
class _Db extends FakeLocalDatabase {
  bool refuseUpdates = false;

  /// Reads fail while the DB still reports DbReady, as on the real stack
  /// (security's P1/P2): the lenient fetchPatients() returns [] (its
  /// catch-all), the key scan throws readFailed.
  bool readsFail = false;

  /// Replaces the reference scan (failure / owner-change injection).
  Future<Set<String>> Function()? refsOverride;

  @override
  Future<String?> updatePatient(Patient patient) async {
    if (refuseUpdates) throw UnsyncedCounterException(ownerA);
    return super.updatePatient(patient);
  }

  @override
  Future<List<Patient>> fetchPatients() async =>
      readsFail ? <Patient>[] : super.fetchPatients();

  @override
  Future<Set<String>> referencedAttachmentPaths() async {
    if (readsFail) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.readFailed);
    }
    return super.referencedAttachmentPaths();
  }

  @override
  Future<Set<String>> referencedAttachmentKeys() async {
    final o = refsOverride;
    if (o != null) return o();
    if (readsFail) {
      throw const AttachmentScanIncomplete(AttachmentScanFailure.readFailed);
    }
    return super.referencedAttachmentKeys();
  }
}

/// App-written visit photo names are `<uuid>.<ext>` (security Low-3), so
/// every "should be deleted" fixture uses one; [tag] keeps tests readable.
final _uuidNames = <String, String>{};
String uuidName(String tag) {
  final ext = p.extension(tag).isEmpty ? '.jpg' : p.extension(tag);
  return _uuidNames.putIfAbsent(
      tag,
      () => '${(_uuidNames.length + 1).toRadixString(16).padLeft(8, '0')}'
          '-0000-4000-8000-000000000000$ext');
}

/// Background isolate for the Low-1 race: keeps swapping [entry] between a
/// regular file and a symlink to [victim] until [ms] elapse.
void _swapper(List<Object> a) {
  final entry = a[0] as String, victim = a[1] as String, ms = a[2] as int;
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    try {
      File(entry).writeAsBytesSync([1]);
      File(entry).deleteSync();
      Link(entry).createSync(victim);
      Link(entry).deleteSync();
    } catch (_) {}
  }
}

void main() {
  late Directory root;
  late Directory support;
  late LocalPhotoStore photos;
  late _Db db;
  late List<String> logs;
  DebugPrintCallback? savedPrint;

  final fa = AttachmentRefs.ownerFolderNameFor(ownerA);
  final fb = AttachmentRefs.ownerFolderNameFor(ownerB);

  String visitDir(String owner) => photos.visitFolderFor(owner)!;
  String profileDir(String owner) =>
      p.join(support.path, LocalPhotoStore.profileFolder,
          LocalPhotoStore.ownerFolderName(owner));

  String photoIn(String dir, String tag, {bool raw = false}) {
    Directory(dir).createSync(recursive: true);
    final name = raw ? tag : uuidName(tag);
    return (File(p.join(dir, name))..writeAsBytesSync([0xFF, 0xD8, 1, 0xFF, 0xD9]))
        .path;
  }

  PhotoSweep sweepFor(Wiring w,
      {DateTime Function()? now, Future<Set<String>> Function()? refs}) {
    if (refs != null) db.refsOverride = refs;
    return appSweep(db, photos, now ?? _later);
  }

  PatientProvider provider() => PatientProvider(
      db: db,
      cloudSync: false,
      photos: photos, // app default attachmentKey: what the app ships
      firestore: _TripHelper(),
      auth: _TripAuth(),
      storage: _TripStorage());

  setUp(() async {
    firebaseHits.clear();
    logs = [];
    savedPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
    root = Directory.systemTemp.createTempSync('qa_sweep');
    support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _Db()..state = const DbReady(ownerA);
  });

  tearDown(() {
    debugPrint = savedPrint!;
    expect(firebaseHits, isEmpty, reason: 'sweep never touches Firebase');
    for (final l in logs) {
      expect(l, isNot(contains(root.path)), reason: 'no paths in logs: $l');
      expect(l, isNot(contains('.jpg')), reason: 'no file names: $l');
      expect(l, isNot(contains(fa)), reason: 'no owner hash: $l');
      expect(l, isNot(contains(secretName)), reason: 'no patient data: $l');
    }
    root.deleteSync(recursive: true);
  });

  test('SWP-00 forApp() uses only the DB own scan; stand-ins gone', () {
    final sweep = File('lib/services/photo_sweep.dart').readAsStringSync();
    final prov = File('lib/providers/patient_provider.dart').readAsStringSync();
    expect(File('lib/services/attachment_keys.dart').existsSync(), isFalse,
        reason: 'the interim stand-in file must be gone');
    // 3a695b0: forApp() => PhotoSweep(db: DatabaseHelper.instance,
    //   loadStatus: PatientLoadStatus.instance) - match the prefix only.
    final flat = sweep.replaceAll(RegExp(r'\s+'), ' ');
    expect(flat, contains('PhotoSweep.forApp() => PhotoSweep(db: DatabaseHelper.instance'),
        reason: 'forApp changed: update support/app_sweep_wiring.dart');
    expect(flat, contains('loadStatus: PatientLoadStatus.instance'),
        reason: '3a695b0 forApp passes the app load-failure guard');
    expect(sweep, contains('_db.referencedAttachmentKeys()'));
    expect(sweep, contains('AttachmentRefs.attachmentKey'));
    expect(sweep, isNot(contains('fetchPatients')),
        reason: 'the lenient read returns [] on error: never in the sweep');
    expect(sweep, contains('on AttachmentScanIncomplete catch'));
    for (final src in [sweep, prov]) {
      expect(src, isNot(contains('interimAttachmentKey')));
      expect(src, isNot(contains('interimReferencedKeys')));
    }
  });

  group('SWP-30 load-failure guard (3a695b0 PatientLoadStatus)', () {
    Future<PhotoSweepResult> run(PatientLoadStatus st) =>
        appSweep(db, photos, _later, loadStatus: st).sweep(ownerA);
    test('SWP-30a status failed for the owner -> skipped(loadFailed), nothing deleted', () async {
      final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
      final r = await run(PatientLoadStatus()..failed(ownerA));
      expect((r.ran, r.reason), (false, 'loadFailed'));
      expect(File(orphan).existsSync(), isTrue);
    });
    test('SWP-30b control: status loaded for the owner -> old orphan removed', () async {
      final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
      final r = await run(PatientLoadStatus()..loaded(ownerA));
      expect(r.ran, isTrue);
      expect(File(orphan).existsSync(), isFalse);
    });
    test('SWP-30c a failure recorded for ANOTHER owner does not block this owner', () async {
      final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
      final r = await run(PatientLoadStatus()..failed(ownerB));
      expect(r.ran, isTrue);
      expect(File(orphan).existsSync(), isFalse);
    });
    test('SWP-30d the real provider publishes a strict-load failure; the sweep then skips', () async {
      final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
      final st = PatientLoadStatus();
      db.strictReadFailure = DbReadFailure.readFailed;
      final pp = PatientProvider(db: db, cloudSync: false, photos: photos,
          firestore: _TripHelper(), loadStatus: st);
      await pp.loadAndSync(ownerA);
      expect(st.isFailed(ownerA), isTrue, reason: 'provider must publish the failed load');
      final r = await run(st);
      expect((r.ran, r.reason), (false, 'loadFailed'));
      expect(File(orphan).existsSync(), isTrue);
      db.strictReadFailure = null;
      await pp.reload();
      expect(st.isLoaded(ownerA), isTrue, reason: 'a later good load clears it');
    });
  });

  test('SWP-29 skip log is "Photos: sweep skipped (<reason name>)"',
      () async {
    final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
    for (final reason in AttachmentScanFailure.values) {
      logs.clear();
      final r = await sweepFor(Wiring.app,
              refs: () async => throw AttachmentScanIncomplete(reason))
          .sweep(ownerA);
      expect(r.reason, reason.name);
      expect(logs, contains('Photos: sweep skipped (${reason.name})'),
          reason: '$logs');
    }
    expect(File(orphan).existsSync(), isTrue);
  });

  for (final w in Wiring.values) {
    group('[${w.name}]', () {
      test('SWP-01 unreferenced old deleted; referenced kept; dirty counts',
          () async {
        final keep = photoIn(visitDir(ownerA), 'keep.jpg');
        final gone = photoIn(visitDir(ownerA), 'gone.jpg');
        await db.insertPatient(_patient('p1', [_visit('v1', [keep])]));
        expect(db.dirty['p1'], isTrue);
        final r = await sweepFor(w).sweep(ownerA);
        expect(r.ran, isTrue);
        expect(File(keep).existsSync(), isTrue);
        expect(File(gone).existsSync(), isFalse);
        expect((r.removed, r.referenced), (1, 1));
      });

      // Each stored format the DB can hold for the same, referenced file.
      // Data loss = the referenced file is deleted.
      final formats = <String, String Function(String abs)>{
        'absolute': (a) => a,
        'file://': (a) => Uri.file(a).toString(),
        'file://localhost': (a) => 'file://localhost$a',
        '/data/data alias':
            (a) => '/data/data/com.x/files/attachments/$fa/${p.basename(a)}',
        '/data/user/0 alias':
            (a) => '/data/user/0/com.x/files/attachments/$fa/${p.basename(a)}',
        'relative': (a) => 'attachments/$fa/${p.basename(a)}',
        'double slash': (a) => a.replaceFirst('/$fa/', '/$fa//'),
      };
      formats.forEach((name, fmt) {
        test('SWP-02 referenced file stored as "$name" is never deleted',
            () async {
          final abs = photoIn(visitDir(ownerA), 'ref.jpg');
          final decoy = photoIn(visitDir(ownerA), 'decoy.jpg');
          await db.insertPatient(_patient('p1', [_visit('v1', [fmt(abs)])]));
          final r = await sweepFor(w).sweep(ownerA);
          expect(File(abs).existsSync(), isTrue,
              reason: 'DATA LOSS: referenced "$name" photo deleted '
                  '(ran=${r.ran} removed=${r.removed})');
          expect(r.ran, isTrue, reason: 'valid "$name" path must not stall cleanup');
          expect(File(decoy).existsSync(), isFalse);
        });
      });

      test('SWP-03 profile/ is never swept, referenced or not', () async {
        final prof = photoIn(profileDir(ownerA), 'avatar_1.jpg');
        final old = photoIn(profileDir(ownerA), 'avatar_0.jpg');
        await db.putSetting(AttachmentRefs.doctorProfileSettingKey,
            '{"profileImageUrl":"$prof"}');
        final r = await sweepFor(w).sweep(ownerA);
        expect(r.ran, isTrue);
        expect(File(prof).existsSync(), isTrue);
        expect(File(old).existsSync(), isTrue);
      });

      for (final bad in [
        '/data/user/0/com.x/cache/image_picker_${secretName}_1.jpg',
        'file:///x/attachments/$fa/%2e%2e/$fb/a.jpg',
        '/x/attachments/$fb/a.jpg',
        'content://media/external/images/1',
      ]) {
        test('SWP-04 unkeyable stored path skips the whole sweep: $bad',
            () async {
          final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
          await db.insertPatient(_patient('p1', [_visit('v1', [bad])]));
          final r = await sweepFor(w).sweep(ownerA);
          expect(File(orphan).existsSync(), isTrue,
              reason: 'partial reference list used (ran=${r.ran})');
          expect(r.ran, isFalse);
        });
      }

      test('SWP-05 every scan failure reason skips, nothing deleted', () async {
        final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
        for (final reason in AttachmentScanFailure.values) {
          final r = await sweepFor(w,
                  refs: () async => throw AttachmentScanIncomplete(reason))
              .sweep(ownerA);
          expect(r.ran, isFalse, reason: reason.name);
          expect(File(orphan).existsSync(), isTrue, reason: reason.name);
        }
        // An unexpected bug in the scan also skips (safe), never "empty set".
        final r = await sweepFor(w, refs: () async => throw TypeError())
            .sweep(ownerA);
        expect(r.ran, isFalse);
        expect(File(orphan).existsSync(), isTrue);
      });

      test('SWP-06 closed or failed DB, or another owner open: skipped',
          () async {
        final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
        for (final st in <DbOpenState>[
          const DbClosed(),
          const DbFailed(ownerA, DbOpenError.migrationFailed),
          const DbReady(ownerB),
        ]) {
          db.state = st;
          final r = await sweepFor(w).sweep(ownerA);
          expect(r.ran, isFalse, reason: '$st');
          expect(File(orphan).existsSync(), isTrue, reason: '$st');
        }
      });

      test('SWP-07 another owner\'s folder is never touched', () async {
        final mine = photoIn(visitDir(ownerA), 'a.jpg');
        final theirs = photoIn(visitDir(ownerB), 'b.jpg');
        await sweepFor(w).sweep(ownerA);
        expect(File(mine).existsSync(), isFalse);
        expect(File(theirs).existsSync(), isTrue);
      });

      test('SWP-08 nested sub-folders and their files are never deleted',
          () async {
        final nested = photoIn(p.join(visitDir(ownerA), 'sub'), 'n.jpg');
        final deep = photoIn(p.join(visitDir(ownerA), 'sub', 'x'), 'd.jpg');
        final r = await sweepFor(w).sweep(ownerA);
        expect(r.ran, isTrue);
        expect(File(nested).existsSync(), isTrue);
        expect(File(deep).existsSync(), isTrue);
        expect(Directory(p.join(visitDir(ownerA), 'sub')).existsSync(), isTrue);
      });

      test('SWP-09 symlinks: never followed, never deleted', () async {
        final outside = photoIn(p.join(root.path, 'outside'), 'victim.jpg');
        Directory(visitDir(ownerA)).createSync(recursive: true);
        final link = Link(p.join(visitDir(ownerA), uuidName('link.jpg')))
          ..createSync(outside);
        final dirLink = Link(p.join(visitDir(ownerA), 'dirlink'))
          ..createSync(p.dirname(outside));
        await sweepFor(w).sweep(ownerA);
        expect(File(outside).existsSync(), isTrue);
        expect(link.existsSync(), isTrue);
        expect(dirLink.existsSync(), isTrue);
      });

      test('SWP-10 symlinked owner folder: skipped, target untouched',
          () async {
        final elsewhere = p.join(root.path, 'elsewhere');
        final victim = photoIn(elsewhere, 'victim.jpg');
        Directory(p.dirname(visitDir(ownerA))).createSync(recursive: true);
        Link(visitDir(ownerA)).createSync(elsewhere);
        final r = await sweepFor(w).sweep(ownerA);
        expect(File(victim).existsSync(), isTrue);
        expect(r.removed, 0);
      });

      test('SWP-11 symlinked attachments/ root: delete re-check refuses',
          () async {
        final elsewhere = p.join(root.path, 'elsewhere_root');
        final victim = photoIn(p.join(elsewhere, fa), 'victim.jpg');
        Link(p.join(support.path, LocalPhotoStore.attachmentsFolder))
            .createSync(elsewhere);
        final r = await sweepFor(w).sweep(ownerA);
        expect(File(victim).existsSync(), isTrue,
            reason: 'removed=${r.removed} other=${r.other}');
      });

      test('SWP-12 grace: copied file with old mtime but fresh ctime is kept',
          () async {
        final f = photoIn(visitDir(ownerA), 'copied.jpg');
        File(f).setLastModifiedSync(
            DateTime.now().subtract(const Duration(days: 30)));
        final r = await sweepFor(w, now: DateTime.now).sweep(ownerA);
        expect(File(f).existsSync(), isTrue);
        expect(r.recent, 1);
      });

      test('SWP-13 grace boundary: 1 ms inside kept, exactly at cutoff deleted',
          () async {
        final f = photoIn(visitDir(ownerA), 'edge.jpg');
        final st = FileStat.statSync(f);
        final changed =
            st.modified.isAfter(st.changed) ? st.modified : st.changed;
        const g = PhotoSweep.defaultGrace;
        var r = await sweepFor(w,
                now: () => changed.add(g).subtract(const Duration(milliseconds: 1)))
            .sweep(ownerA);
        expect(File(f).existsSync(), isTrue, reason: 'inside grace');
        expect(r.recent, 1);
        r = await sweepFor(w, now: () => changed.add(g)).sweep(ownerA);
        expect(File(f).existsSync(), isFalse,
            reason: 'boundary is inclusive (age == grace is swept)');
      });

      test('SWP-14 future mtime keeps the file (safe; never swept early)',
          () async {
        final f = photoIn(visitDir(ownerA), 'future.jpg');
        File(f).setLastModifiedSync(
            DateTime.now().add(const Duration(days: 365)));
        final r = await sweepFor(w).sweep(ownerA);
        expect(File(f).existsSync(), isTrue);
        expect(r.recent, 1);
      });

      test('SWP-15 owner changes during the scan: nothing deleted', () async {
        final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
        final r = await sweepFor(w, refs: () async {
          db.state = const DbReady(ownerB);
          return <String>{};
        }).sweep(ownerA);
        expect(r.ran, isFalse);
        expect(File(orphan).existsSync(), isTrue);
      });

      test('SWP-16 sweeping twice is harmless; empty/missing folder is fine',
          () async {
        photoIn(visitDir(ownerA), 'gone.jpg');
        final s = sweepFor(w);
        expect((await s.sweep(ownerA)).removed, 1);
        final again = await s.sweep(ownerA);
        expect((again.ran, again.removed), (true, 0));
        Directory(visitDir(ownerA)).deleteSync(recursive: true);
        final none = await s.sweep(ownerA);
        expect((none.ran, none.scanned), (true, 0));
      });

      test('SWP-17 tombstone (a): crash after markPendingDelete, sweep cleans',
          () async {
        final gone = photoIn(visitDir(ownerA), 'tomb.jpg');
        final kept = photoIn(visitDir(ownerA), 'live.jpg');
        await db.insertPatient(_patient('p1', [_visit('v1', [gone])]));
        await db.insertPatient(_patient('p2', [_visit('v2', [kept])]));
        await db.markPendingDelete('p1'); // provider cleanup "crashed"
        await sweepFor(w).sweep(ownerA);
        expect(File(gone).existsSync(), isFalse);
        expect(File(kept).existsSync(), isTrue);
      });

      test('SWP-18 tombstone (b): refused markPendingDelete keeps photos',
          () async {
        final f = photoIn(visitDir(ownerA), 'p1.jpg');
        await db.insertPatient(_patient('p1', [_visit('v1', [f])]));
        db.refuseDeletes = true;
        await expectLater(db.markPendingDelete('p1'), throwsA(anything));
        await sweepFor(w).sweep(ownerA);
        expect(File(f).existsSync(), isTrue);
      });

      test('SWP-23 a read fails while the DB still reports open: no deletes',
          () async {
        final used = photoIn(visitDir(ownerA), 'used.jpg');
        final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
        await db.insertPatient(_patient('p1', [_visit('v1', [used])]));
        db.readsFail = true;
        // Preconditions = security's P1: open, lenient read empty, scan throws.
        expect(db.openUid, ownerA);
        expect(await db.fetchPatients(), isEmpty);
        await expectLater(db.referencedAttachmentKeys(),
            throwsA(isA<AttachmentScanIncomplete>()));
        final r = await sweepFor(w).sweep(ownerA);
        expect(File(used).existsSync(), isTrue,
            reason: 'DATA LOSS: in-use photo deleted after a failed read '
                '(ran=${r.ran} removed=${r.removed} reason=${r.reason})');
        expect(File(orphan).existsSync(), isTrue,
            reason: 'nothing may be deleted on a partial reference list');
        expect(r.ran, isFalse);
      });

      test('SWP-28 Low-3: only <uuid>.<ext> names are ever deleted', () async {
        const u = '0b5e6c1e-1111-4222-8333-944455556666';
        final keep = [
          'notes.txt', 'IMG_0001.jpg', '${u.toUpperCase()}.jpg', '$u.JPG',
          '$u.jpg.bak', '.hidden', 'caf\u00e9.jpg', '$u.gif', u,
          '$u .jpg', 'x$u.jpg',
          // the app never writes these (UploadImageType = jpg|png|webp)
          '${u.substring(0, 35)}1.jpeg', '${u.substring(0, 35)}2.heic',
        ].map((n) => photoIn(visitDir(ownerA), n, raw: true)).toList();
        final gone = [
          for (final e in ['jpg', 'png', 'webp'])
            photoIn(visitDir(ownerA), '${u.substring(0, 34)}9${e.length}.$e',
                raw: true)
        ];
        final r = await sweepFor(w).sweep(ownerA);
        expect(r.ran, isTrue);
        for (final f in keep) {
          expect(File(f).existsSync(), isTrue,
              reason: 'non-app name deleted: ${p.basename(f)}');
        }
        for (final f in gone) {
          expect(File(f).existsSync(), isFalse, reason: p.basename(f));
        }
      });

      test('SWP-19 runWhenOpen waits for DbReady and sweeps that owner only',
          () async {
        final orphan = photoIn(visitDir(ownerA), 'orphan.jpg');
        db.state = const DbClosed();
        final r = await sweepFor(w).runWhenOpen();
        expect(r.ran, isFalse);
        expect(File(orphan).existsSync(), isTrue);
        db.state = const DbReady(ownerA);
        expect((await sweepFor(w).runWhenOpen()).removed, 1);
      });
    });
  }

  group('provider delete-time cleanup (#16)', () {
    Future<PatientProvider> loaded() async {
      final pp = provider();
      await pp.loadAndSync(ownerA);
      return pp;
    }

    test('SWP-20 refused patient delete removes no photo', () async {
      final f = photoIn(visitDir(ownerA), 'p1.jpg');
      await db.insertPatient(_patient('p1', [_visit('v1', [f])]));
      final pp = await loaded();
      db.refuseDeletes = true;
      await expectLater(pp.deletePatient('p1'), throwsA(anything));
      expect(File(f).existsSync(), isTrue);
    });

    test('SWP-21 successful delete removes only that patient\'s photos, '
        'never one another visit still uses, never profile/', () async {
      final own = photoIn(visitDir(ownerA), 'own.jpg');
      final shared = photoIn(visitDir(ownerA), 'shared.jpg');
      final prof = photoIn(profileDir(ownerA), 'avatar.jpg');
      await db.insertPatient(_patient('p1', [_visit('v1', [own, shared, prof])]));
      await db.insertPatient(_patient('p2', [_visit('v2', [shared])]));
      final pp = await loaded();
      await pp.deletePatient('p1');
      expect(File(own).existsSync(), isFalse);
      expect(File(shared).existsSync(), isTrue);
      expect(File(prof).existsSync(), isTrue);
    });

    test('SWP-22 photo removed while editing: deleted only after the save',
        () async {
      final a = photoIn(visitDir(ownerA), 'a.jpg');
      final b = photoIn(visitDir(ownerA), 'b.jpg');
      await db.insertPatient(_patient('p1', [_visit('v1', [a, b])]));
      final pp = await loaded();
      db.refuseUpdates = true;
      await expectLater(
          pp.updateRecord('p1', _visit('v1', [a])), throwsA(anything));
      expect(File(b).existsSync(), isTrue, reason: 'refused save');
      db.refuseUpdates = false;
      await pp.updateRecord('p1', _visit('v1', [a]));
      expect(File(a).existsSync(), isTrue);
      expect(File(b).existsSync(), isFalse);
    });
  });

  group('Low-1: delete the walked entry, never its resolved target', () {
    test('SWP-24 a path through a symlinked sub-folder never deletes the '
        'photo it resolves to', () async {
      final victim = photoIn(visitDir(ownerA), 'victim.jpg');
      Link(p.join(visitDir(ownerA), 'sub')).createSync(visitDir(ownerA));
      final viaLink = p.join(visitDir(ownerA), 'sub', p.basename(victim));
      final ok = await photos.deleteOwnedVisitFile(viaLink, owner: ownerA);
      expect(File(victim).existsSync(), isTrue,
          reason: 'resolved target deleted (returned $ok)');
      expect(ok, isFalse, reason: 'only direct children of the owner folder');
    });

    test('SWP-24b a symlink entry is refused and its target survives',
        () async {
      final victim = photoIn(visitDir(ownerA), 'victim.jpg');
      final entry = p.join(visitDir(ownerA), uuidName('entry.jpg'));
      Link(entry).createSync(victim);
      expect(await photos.deleteOwnedVisitFile(entry, owner: ownerA), isFalse);
      expect(File(victim).existsSync(), isTrue);
    });

    test('SWP-25 race: entry swapped to a symlink mid-delete never takes out '
        'the target (2 s stress)', () async {
      final victim = photoIn(visitDir(ownerA), 'victim.jpg');
      final entry = p.join(visitDir(ownerA), uuidName('swapped.jpg'));
      final done = Isolate.run(() => _swapper([entry, victim, 2000]));
      var lost = 0, calls = 0;
      final end = DateTime.now().add(const Duration(milliseconds: 1900));
      while (DateTime.now().isBefore(end)) {
        calls++;
        await photos.deleteOwnedVisitFile(entry, owner: ownerA);
        if (!File(victim).existsSync()) {
          lost++;
          photoIn(visitDir(ownerA), 'victim.jpg');
        }
      }
      await done;
      // ignore: avoid_print
      print('SWP-25 calls=$calls victimLost=$lost');
      expect(lost, 0, reason: 'target deleted $lost times in $calls calls');
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('Low-2: provider cleanup stops on a still-used entry it cannot key',
      () {
    Future<PatientProvider> loaded() async {
      final pp = provider();
      await pp.loadAndSync(ownerA);
      return pp;
    }

    test('SWP-26 an unkeyable still-used local entry skips the cleanup',
        () async {
      final a = photoIn(visitDir(ownerA), 'a.jpg');
      final b = photoIn(visitDir(ownerA), 'b.jpg');
      await db.insertPatient(_patient('p1', [_visit('v1', [a, b])]));
      await db.insertPatient(_patient('p2', [
        _visit('v2', ['/data/user/0/com.x/cache/image_picker_1.jpg'])
      ]));
      final pp = await loaded();
      await pp.updateRecord('p1', _visit('v1', [a]));
      expect(File(b).existsSync(), isTrue,
          reason: 'references incomplete: cleanup must be left to the sweep');
    });

    test('SWP-27 a file://localhost alias still in use is never deleted',
        () async {
      final a = photoIn(visitDir(ownerA), 'a.jpg');
      final b = photoIn(visitDir(ownerA), 'b.jpg');
      await db.insertPatient(_patient('p1', [_visit('v1', [a, b])]));
      await db.insertPatient(
          _patient('p2', [_visit('v2', ['file://localhost$b'])]));
      final pp = await loaded();
      await pp.updateRecord('p1', _visit('v1', [a]));
      expect(File(b).existsSync(), isTrue,
          reason: 'DATA LOSS: photo still used by p2 deleted');
    });
  });
}
