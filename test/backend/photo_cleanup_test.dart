// Photo cleanup after deletes, and the startup sweep (security's #8 review).
// Runs in both suite modes: everything here injects cloudSync: false and the
// dev owner explicitly; nothing depends on the define.
import 'dart:io';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/attachment_keys.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/photo_sweep.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';

final hits = <String>[];

class _TripAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('auth.${i.memberName}');
    throw StateError('FirebaseAuth touched');
  }
}

class _TripStorage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('storage.${i.memberName}');
    throw StateError('Storage touched');
  }
}

class _TripHelper extends FakeFirestoreHelper {
  @override
  Future<bool> syncPatient(Patient patient) async {
    hits.add('helper.sync');
    return false;
  }

  @override
  Future<bool> deletePatient(String patientId) async {
    hits.add('helper.delete');
    return false;
  }
}

const doctorB = 'doctorB';

VisitRecord visit(String id, List<String> photos) => VisitRecord(
    id: id,
    date: DateTime(2026, 1, 2),
    visitType: 'Consultation',
    symptoms: 'cough',
    diagnosis: 'cold',
    prescription: 'rest',
    attachmentPaths: photos);

Patient patient(String id, List<VisitRecord> history, {List<String> parseErrors = const []}) => Patient(
    id: id, name: 'Test $id', age: '30', gender: 'Female', phone: '+9100000',
    history: history, parseErrors: parseErrors);

/// "Old enough" clock: one hour ahead, so files created now are past grace.
DateTime later() => DateTime.now().add(const Duration(hours: 1));

void main() {
  late Directory root;
  late Directory support;
  late LocalPhotoStore photos;
  late FakeLocalDatabase db;

  String photoIn(String? dir, String name) {
    Directory(dir!).createSync(recursive: true);
    return (File(p.join(dir, name))..writeAsBytesSync([0xFF, 0xD8, 1, 2, 0xFF, 0xD9])).path;
  }

  String visitPhoto(String owner, String name) => photoIn(photos.visitFolderFor(owner), name);

  PatientProvider devPatients() => PatientProvider(
      db: db, cloudSync: false, photos: photos,
      firestore: _TripHelper(), auth: _TripAuth(), storage: _TripStorage());

  Future<PatientProvider> loaded() async {
    final provider = devPatients();
    await provider.loadAndSync(kLocalOwnerId);
    return provider;
  }

  PhotoSweep sweepFor({
    ReferencedKeysFn? referencedKeys,
    AttachmentKeyFn? attachmentKey,
    DateTime Function()? now,
    Duration grace = PhotoSweep.defaultGrace,
  }) {
    final key = attachmentKey ?? AttachmentKeys.interimAttachmentKey;
    return PhotoSweep(
        db: db,
        photos: photos,
        attachmentKey: key,
        referencedKeys: referencedKeys ?? () => AttachmentKeys.interimReferencedKeys(db, key),
        grace: grace,
        now: now ?? later);
  }

  setUp(() async {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_cleanup');
    support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = FakeLocalDatabase()..state = const DbReady(kLocalOwnerId);
  });

  tearDown(() {
    expect(hits, isEmpty, reason: 'cleanup never touches Firebase');
    root.deleteSync(recursive: true);
  });

  group('attachment keys (interim stand-in for #10)', () {
    final folder = LocalPhotoStore.ownerFolderName(kLocalOwnerId);
    String? key(String s) => AttachmentKeys.interimAttachmentKey(s, ownerFolderName: folder);

    test('built from segments: /data/user/0 and /data/data give the same key', () {
      expect(key('/data/user/0/app/files/attachments/$folder/a.jpg'), 'attachments/a.jpg');
      expect(key('/data/data/app/files/attachments/$folder/a.jpg'), 'attachments/a.jpg');
      expect(key('file:///data/data/app/files/attachments/$folder/a.jpg'), 'attachments/a.jpg');
      expect(key('/x/profile/$folder/avatar_1.jpg'), 'profile/avatar_1.jpg');
    });

    test('null (never delete) for .., other owners, the root and temp files', () {
      final other = LocalPhotoStore.ownerFolderName(doctorB);
      expect(key('/x/attachments/$folder/../$other/a.jpg'), isNull);
      expect(key('/x/attachments/$other/a.jpg'), isNull);
      expect(key('/x/attachments/a.jpg'), isNull);
      expect(key('/x/attachments/$folder/sub/a.jpg'), isNull);
      expect(key('/cache/image_picker123.jpg'), isNull);
      expect(key(''), isNull);
    });

    test('referenced keys fail closed and skip only web links and Storage paths', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a, 'https://example.com/x.jpg', 'clinical_attachments/u/p1/y.jpg', ''])]);
      final ref = AttachmentKeys.interimAttachmentKey;
      expect(await AttachmentKeys.interimReferencedKeys(db, ref), {'attachments/a.jpg'});

      db.rows['p2'] = patient('p2', [visit('v2', ['/cache/image_picker1.jpg'])]);
      await expectLater(AttachmentKeys.interimReferencedKeys(db, ref),
          throwsA(isA<AttachmentReferencesUnavailable>().having((e) => e.code, 'code', 'unkeyable_path')));
      db.rows.remove('p2');

      db.rows['p3'] = patient('p3', [], parseErrors: ['history']);
      await expectLater(AttachmentKeys.interimReferencedKeys(db, ref),
          throwsA(isA<AttachmentReferencesUnavailable>().having((e) => e.code, 'code', 'parse_error')));
      db.rows.remove('p3');

      db.state = const DbClosed();
      await expectLater(AttachmentKeys.interimReferencedKeys(db, ref),
          throwsA(isA<AttachmentReferencesUnavailable>().having((e) => e.code, 'code', 'no_open_db')));
    });
  });

  group('provider deletes photos only after the DB delete succeeds', () {
    test('deleting a patient removes its visit photos (dev owner "local"); others keep theirs', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      final b = visitPhoto(kLocalOwnerId, 'b.jpg');
      final c = visitPhoto(kLocalOwnerId, 'c.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a]), visit('v2', [b])]);
      db.rows['p2'] = patient('p2', [visit('v3', [c])]);
      final provider = await loaded();

      await provider.deletePatient('p1');

      expect(db.tombstones, contains('p1'));
      expect(File(a).existsSync(), isFalse);
      expect(File(b).existsSync(), isFalse);
      expect(File(c).existsSync(), isTrue);
    });

    test('tombstone: after markPendingDelete succeeds, the photos are unreferenced and swept', () async {
      // Crash between the DB delete and the file delete: only the sweep is left.
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      final c = visitPhoto(kLocalOwnerId, 'c.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a])]);
      db.rows['p2'] = patient('p2', [visit('v3', [c])]);

      await db.markPendingDelete('p1');

      expect(db.tombstones, contains('p1'));
      expect(await AttachmentKeys.interimReferencedKeys(db, AttachmentKeys.interimAttachmentKey),
          {'attachments/c.jpg'});
      final r = await sweepFor().sweep(kLocalOwnerId);
      expect(r.removed, 1);
      expect(File(a).existsSync(), isFalse);
      expect(File(c).existsSync(), isTrue);
    });

    test('tombstone: a refused markPendingDelete keeps every photo (provider and sweep)', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      final b = visitPhoto(kLocalOwnerId, 'b.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a]), visit('v2', [b])]);
      final provider = await loaded();
      db.refuseDeletes = true;

      await expectLater(provider.deletePatient('p1'), throwsA(anything));

      expect(provider.patients.map((x) => x.id), contains('p1'));
      expect(File(a).existsSync(), isTrue);
      expect(File(b).existsSync(), isTrue);
      expect(await AttachmentKeys.interimReferencedKeys(db, AttachmentKeys.interimAttachmentKey),
          {'attachments/a.jpg', 'attachments/b.jpg'});
      final r = await sweepFor().sweep(kLocalOwnerId);
      expect(r.removed, 0);
      expect(File(a).existsSync() && File(b).existsSync(), isTrue);
    });

    test('deleting a visit removes only that visit\'s photos; a refused save keeps them', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      final b = visitPhoto(kLocalOwnerId, 'b.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a]), visit('v2', [b])]);
      final provider = await loaded();

      await provider.deleteRecord('p1', 'v1');
      expect(File(a).existsSync(), isFalse);
      expect(File(b).existsSync(), isTrue);

      db.rows.remove('p1'); // the DB now refuses the update
      await expectLater(provider.deleteRecord('p1', 'v2'), throwsA(anything));
      expect(File(b).existsSync(), isTrue, reason: 'refused delete removes nothing');
    });

    test('a photo removed while editing is deleted after the save, kept when refused', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      final b = visitPhoto(kLocalOwnerId, 'b.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a, b])]);
      final provider = await loaded();

      await provider.updateRecord('p1', visit('v1', [b]));
      expect(File(a).existsSync(), isFalse);
      expect(File(b).existsSync(), isTrue);

      db.rows.remove('p1');
      await expectLater(provider.updateRecord('p1', visit('v1', [])), throwsA(anything));
      expect(File(b).existsSync(), isTrue);
    });

    test('deleting the same file twice is harmless (missing files are ignored)', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      final b = visitPhoto(kLocalOwnerId, 'b.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a]), visit('v2', [b])]);
      final provider = await loaded();
      File(a).deleteSync(); // e.g. PR #8's screen hook got there first

      await provider.deleteRecord('p1', 'v1');
      expect(File(b).existsSync(), isTrue);
      expect(await photos.deleteOwnedVisitFile(b, owner: kLocalOwnerId), isTrue);
      expect(await photos.deleteOwnedVisitFile(b, owner: kLocalOwnerId), isFalse);
    });

    test('never deletes another owner\'s photo, the profile photo or anything outside', () async {
      final theirs = visitPhoto(doctorB, 'x.jpg');
      final avatar = photoIn(photos.profileFolderFor(kLocalOwnerId), 'avatar_1.jpg');
      final outside = (File(p.join(root.path, 'outside.jpg'))..writeAsBytesSync([1])).path;
      final escape = p.join(photos.visitFolderFor(kLocalOwnerId)!, '..', LocalPhotoStore.ownerFolderName(doctorB), 'x.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [theirs, avatar, outside, escape])]);
      final provider = await loaded();

      await provider.deleteRecord('p1', 'v1');

      expect(File(theirs).existsSync(), isTrue);
      expect(File(avatar).existsSync(), isTrue);
      expect(File(outside).existsSync(), isTrue);
    });

    test('a photo still referenced by another visit is kept', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [a])]);
      db.rows['p2'] = patient('p2', [visit('v2', [a])]);
      final provider = await loaded();

      await provider.deletePatient('p1');
      expect(File(a).existsSync(), isTrue);
    });

    test('a symlink entry is never followed or deleted', () async {
      final outside = (File(p.join(root.path, 'outside.jpg'))..writeAsBytesSync([1])).path;
      final link = Link(p.join(photos.visitFolderFor(kLocalOwnerId)!, 'link.jpg'));
      Directory(p.dirname(link.path)).createSync(recursive: true);
      link.createSync(outside);
      db.rows['p1'] = patient('p1', [visit('v1', [link.path])]);
      final provider = await loaded();

      await provider.deleteRecord('p1', 'v1');
      expect(File(outside).existsSync(), isTrue);
      expect(FileSystemEntity.typeSync(link.path, followLinks: false), FileSystemEntityType.link);
    });
  });

  group('startup sweep', () {
    test('dev mode ("local"): removes old unreferenced photos, keeps referenced ones', () async {
      final kept = visitPhoto(kLocalOwnerId, 'kept.jpg');
      final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [kept])]);

      final r = await sweepFor().sweep(kLocalOwnerId);

      expect(r.ran, isTrue);
      expect((r.scanned, r.removed, r.referenced), (2, 1, 1));
      expect(File(kept).existsSync(), isTrue);
      expect(File(orphan).existsSync(), isFalse);
    });

    test('runs through StartupHooks for the first open owner only', () async {
      final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
      final theirs = visitPhoto(doctorB, 'orphan.jpg');
      final r = await sweepFor().runWhenOpen();
      expect(r.removed, 1);
      expect(File(orphan).existsSync(), isFalse);
      expect(File(theirs).existsSync(), isTrue);

      final again = visitPhoto(kLocalOwnerId, 'again.jpg');
      db.state = const DbClosed();
      final skipped = await sweepFor().runWhenOpen();
      expect(skipped.ran, isFalse);
      expect(File(again).existsSync(), isTrue);

      final main = File('lib/main.dart').readAsStringSync();
      final reg = main.indexOf('StartupHooks.register(PhotoSweep.hookName, PhotoSweep.startupHook);');
      expect(reg, greaterThan(0));
      expect(reg, lessThan(main.indexOf('if (kDevBuildRefused)')), reason: 'registered for both start modes');
    });

    group('rule 1: skip the whole sweep unless the reference list is complete', () {
      test('no open database', () async {
        final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
        db.state = const DbClosed();
        final r = await sweepFor().sweep(kLocalOwnerId);
        expect((r.ran, r.reason), (false, 'no_open_db'));
        expect(File(orphan).existsSync(), isTrue);
      });

      test('the open database belongs to someone else', () async {
        final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
        db.state = const DbReady(doctorB);
        final r = await sweepFor().sweep(kLocalOwnerId);
        expect(r.ran, isFalse);
        expect(File(orphan).existsSync(), isTrue);
      });

      test('a record fails to parse', () async {
        final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
        db.rows['bad'] = patient('bad', [], parseErrors: ['history']);
        final r = await sweepFor().sweep(kLocalOwnerId);
        expect((r.ran, r.reason), (false, 'references_parse_error'));
        expect(File(orphan).existsSync(), isTrue);
      });

      test('a local path cannot be keyed', () async {
        final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
        db.rows['p1'] = patient('p1', [visit('v1', ['/tmp/image_picker_1.jpg'])]);
        final r = await sweepFor().sweep(kLocalOwnerId);
        expect(r.ran, isFalse);
        expect(File(orphan).existsSync(), isTrue);
      });

      test('the reference source throws anything (until #10 names its exception)', () async {
        final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
        final r = await sweepFor(referencedKeys: () async => throw StateError('db closed')).sweep(kLocalOwnerId);
        expect((r.ran, r.reason), (false, 'references_StateError'));
        expect(File(orphan).existsSync(), isTrue);
      });

      test('a null key from attachmentKey means "not mine": never deleted', () async {
        final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
        final r = await sweepFor(
                referencedKeys: () async => <String>{},
                attachmentKey: (String path, {required String ownerFolderName}) => null)
            .sweep(kLocalOwnerId);
        expect((r.removed, r.other), (0, 1));
        expect(File(orphan).existsSync(), isTrue);
      });
    });

    group('rule 2: regular files in that owner\'s attachments folder only', () {
      test('directories and symlinks are never deleted or followed', () async {
        final dir = photos.visitFolderFor(kLocalOwnerId)!;
        final target = visitPhoto(kLocalOwnerId, 'target.jpg');
        db.rows['p1'] = patient('p1', [visit('v1', [target])]); // referenced
        final outside = (File(p.join(root.path, 'outside.jpg'))..writeAsBytesSync([1])).path;
        final linkOut = Link(p.join(dir, 'out.jpg'))..createSync(outside);
        final linkIn = Link(p.join(dir, 'in.jpg'))..createSync(target);
        final sub = Directory(p.join(dir, 'sub.jpg'))..createSync();
        final nested = photoIn(p.join(dir, 'nested'), 'deep.jpg');

        final r = await sweepFor().sweep(kLocalOwnerId);

        expect(r.removed, 0);
        expect(FileSystemEntity.typeSync(linkOut.path, followLinks: false), FileSystemEntityType.link);
        expect(FileSystemEntity.typeSync(linkIn.path, followLinks: false), FileSystemEntityType.link);
        expect(File(outside).existsSync() && File(target).existsSync(), isTrue);
        expect(sub.existsSync(), isTrue);
        expect(File(nested).existsSync(), isTrue);
      });

      test('a symlinked owner folder is not listed through', () async {
        final elsewhere = Directory(p.join(root.path, 'elsewhere'))..createSync();
        final victim = photoIn(elsewhere.path, 'victim.jpg');
        final dir = photos.visitFolderFor(kLocalOwnerId)!;
        Directory(p.dirname(dir)).createSync(recursive: true);
        Link(dir).createSync(elsewhere.path);

        final r = await sweepFor().sweep(kLocalOwnerId);

        expect(r.ran, isFalse);
        expect(File(victim).existsSync(), isTrue);
        expect(await photos.deleteOwnedVisitFile(p.join(dir, 'victim.jpg'), owner: kLocalOwnerId), isFalse,
            reason: 'resolved path is outside the owner folder');
        expect(File(victim).existsSync(), isTrue);
      });

      test('profile/<owner>/ is never swept', () async {
        final avatar = photoIn(photos.profileFolderFor(kLocalOwnerId), 'avatar_old.jpg');
        visitPhoto(kLocalOwnerId, 'orphan.jpg');
        await sweepFor().sweep(kLocalOwnerId);
        expect(File(avatar).existsSync(), isTrue);
        expect(await photos.deleteOwnedVisitFile(avatar, owner: kLocalOwnerId), isFalse);
        expect(photos.visitPathForKey(kLocalOwnerId, 'profile/avatar_old.jpg'), isNull);
      });

      test('other owners\' folders and the attachments root are untouched', () async {
        final theirs = visitPhoto(doctorB, 'orphan.jpg');
        final loose = photoIn(p.join(photos.supportPath!, 'attachments'), 'loose.jpg');
        final mine = visitPhoto(kLocalOwnerId, 'orphan.jpg');

        await sweepFor().sweep(kLocalOwnerId);

        expect(File(mine).existsSync(), isFalse);
        expect(File(theirs).existsSync(), isTrue);
        expect(File(loose).existsSync(), isTrue);
        expect(await photos.deleteOwnedVisitFile(theirs, owner: kLocalOwnerId), isFalse);
      });
    });

    test('rule 3: photos of unsynced (dirty) rows count as referenced', () async {
      final a = visitPhoto(kLocalOwnerId, 'a.jpg');
      await db.insertPatient(patient('p1', [visit('v1', [a])]));
      expect(db.dirty['p1'], isTrue);

      final r = await sweepFor().sweep(kLocalOwnerId);

      expect((r.removed, r.referenced), (0, 1));
      expect(File(a).existsSync(), isTrue);
    });

    test('rule 4: logs carry counts and codes only, never names or paths', () async {
      final kept = visitPhoto(kLocalOwnerId, 'inuse-3f2a.jpg');
      final orphan = visitPhoto(kLocalOwnerId, 'stray-9c1d.jpg');
      db.rows['p1'] = patient('p1', [visit('v1', [kept])]);
      final logs = <String>[];
      await captureLogs(logs, () async {
        await sweepFor().sweep(kLocalOwnerId);
        db.state = const DbClosed();
        await sweepFor().sweep(kLocalOwnerId);
        db.state = const DbReady(kLocalOwnerId);
        db.rows['bad'] = patient('bad', [], parseErrors: ['name']);
        await sweepFor().sweep(kLocalOwnerId);
        db.rows.remove('bad');
        final provider = await loaded();
        await provider.deleteRecord('p1', 'v1');
      });
      expect(logs, isNotEmpty);
      final folder = LocalPhotoStore.ownerFolderName(kLocalOwnerId);
      for (final line in logs.where((l) => l.startsWith('Photos:'))) {
        for (final leak in [p.basename(kept), p.basename(orphan), 'inuse', 'stray', '3f2a', '9c1d', '.jpg', '/', folder, root.path]) {
          expect(line, isNot(contains(leak)), reason: line);
        }
        expect(line, matches(RegExp(r'^Photos: (sweep removed \d+ of \d+ \(kept \d+ referenced, \d+ recent, \d+ other\)'
            r'|sweep skipped \([A-Za-z_]+\)|removed \d+ after a delete)$')));
      }
      expect(logs.where((l) => l.startsWith('Photos: removed')).length, 1);
    });

    group('grace period', () {
      test('files changed within the grace period are kept', () async {
        final young = visitPhoto(kLocalOwnerId, 'young.jpg');
        final r = await sweepFor(now: DateTime.now).sweep(kLocalOwnerId);
        expect((r.removed, r.recent), (0, 1));
        expect(File(young).existsSync(), isTrue);
      });

      test('an old modified time does not hide a fresh copy (newer of mtime and ctime)', () async {
        final copied = visitPhoto(kLocalOwnerId, 'copied.jpg');
        File(copied).setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
        expect(File(copied).statSync().modified.isBefore(DateTime.now().subtract(const Duration(days: 1))), isTrue);
        final r = await sweepFor(now: DateTime.now).sweep(kLocalOwnerId);
        expect(r.recent, 1);
        expect(File(copied).existsSync(), isTrue);
      });

      test('past the grace period the same file goes', () async {
        final f = visitPhoto(kLocalOwnerId, 'f.jpg');
        final r = await sweepFor(now: () => DateTime.now().add(const Duration(minutes: 11))).sweep(kLocalOwnerId);
        expect(r.removed, 1);
        expect(File(f).existsSync(), isFalse);
        expect(PhotoSweep.defaultGrace, const Duration(minutes: 10));
      });
    });

    test('stored paths through a symlinked app dir (/data/user/0 vs /data/data) keep in-use photos', () async {
      // /data/user/0 -> /data/data, as on Android.
      final realApp = Directory(p.join(root.path, 'data', 'data', 'app'))..createSync(recursive: true);
      final user = Directory(p.join(root.path, 'data', 'user'))..createSync(recursive: true);
      Link(p.join(user.path, '0')).createSync(p.join(root.path, 'data', 'data'));
      final viaLink = p.join(user.path, '0', 'app');
      photos = LocalPhotoStore(supportDir: () async => Directory(viaLink));
      await photos.init();
      expect(photos.supportPath, startsWith(realApp.path), reason: 'store walks the canonical path');

      final folder = LocalPhotoStore.ownerFolderName(kLocalOwnerId);
      final inUse = visitPhoto(kLocalOwnerId, 'in-use.jpg');
      final orphan = visitPhoto(kLocalOwnerId, 'orphan.jpg');
      final storedViaLink = p.join(viaLink, 'attachments', folder, 'in-use.jpg');
      expect(storedViaLink, isNot(inUse), reason: 'raw paths differ');
      db.rows['p1'] = patient('p1', [visit('v1', [storedViaLink]), visit('v2', ['file://$storedViaLink'])]);

      final r = await sweepFor().sweep(kLocalOwnerId);

      expect((r.removed, r.referenced), (1, 1));
      expect(File(inUse).existsSync(), isTrue);
      expect(File(orphan).existsSync(), isFalse);

      // The provider maps the stored path by key, so deleting both visits
      // removes the canonical file.
      final provider = await loaded();
      await provider.deleteRecord('p1', 'v1');
      expect(File(inUse).existsSync(), isTrue, reason: 'v2 still references it');
      await provider.deleteRecord('p1', 'v2');
      expect(File(inUse).existsSync(), isFalse);
    });
  });
}
