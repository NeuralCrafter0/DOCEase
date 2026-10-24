// QA photo-sweep regression suite, part 1: the key contract the sweep
// relies on, against #10's real API (lib/providers/attachment_refs.dart and
// LocalDatabase.referencedAttachmentKeys via the shared fake). Runs on
// qa-merged3 without #16. Part 2 (the sweep itself) is
// test/qa_sweep/photo_sweep_qa_test.dart, which needs #16 merged.
//
// IDs: KEY-xx. No Firebase. Runs in both suite modes.
import 'dart:convert';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/db_fakes.dart';

const ownerA = 'doctorA';
const ownerB = 'doctorB';

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

void main() {
  final fa = AttachmentRefs.ownerFolderNameFor(ownerA);
  final fb = AttachmentRefs.ownerFolderNameFor(ownerB);
  String? key(String s) => AttachmentRefs.attachmentKey(s, ownerFolderName: fa);

  group('KEY-01 one owner hash everywhere', () {
    test('AttachmentRefs, LocalPhotoStore and the DB file name agree', () {
      for (final owner in [
        ownerA,
        'local',
        'uid_with.dots-and_UPPER',
        'डॉक्टर',
        'x' * 300,
      ]) {
        final h = AttachmentRefs.ownerFolderNameFor(owner);
        expect(h, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(LocalPhotoStore.ownerFolderName(owner), h, reason: owner);
        expect(DatabaseHelper.dbFileNameFor(owner), 'docease_$h.db',
            reason: owner);
      }
      expect(fa, isNot(fb));
    });

    test('a non-hash owner folder name is refused, not guessed', () {
      expect(
          () => AttachmentRefs.attachmentKey('/a/attachments/x/y.jpg',
              ownerFolderName: ownerA),
          throwsArgumentError);
      expect(
          () => AttachmentRefs.attachmentKey('/a/b.jpg',
              ownerFolderName: fa.toUpperCase()),
          throwsArgumentError);
    });
  });

  group('KEY-02 same file, same key', () {
    test('/data/user/0, /data/data, file://, relative and symlinked dirs', () {
      for (final s in [
        '/data/user/0/com.x/files/attachments/$fa/a.jpg',
        '/data/data/com.x/files/attachments/$fa/a.jpg',
        'file:///data/data/com.x/files/attachments/$fa/a.jpg',
        'file://localhost/data/data/com.x/files/attachments/$fa/a.jpg',
        'attachments/$fa/a.jpg',
        '/private/var/mobile/Containers/Data/Application/U/Library/'
            'Application Support/attachments/$fa/a.jpg',
        '/var/mobile/Containers/Data/Application/U/Library/'
            'Application Support/attachments/$fa/a.jpg',
        '/data/data/com.x/files/attachments/$fa//a.jpg',
      ]) {
        expect(key(s), 'attachments/a.jpg', reason: s);
      }
      expect(key('/x/profile/$fa/avatar_1.png'), 'profile/avatar_1.png');
    });

    test('a nested file keeps its sub-folder in the key', () {
      // The sweep only lists direct children, so this file is never a sweep
      // candidate; the key just must not collapse onto a top-level name.
      expect(key('/x/attachments/$fa/sub/a.jpg'), 'attachments/sub/a.jpg');
      expect(key('/x/attachments/$fa/sub/a.jpg'),
          isNot(key('/x/attachments/$fa/a.jpg')));
    });
  });

  group('KEY-03 never a key for anything not plainly mine', () {
    final cases = <String, String>{
      'raw ..': '/x/attachments/$fa/../$fb/a.jpg',
      'raw .': '/x/attachments/$fa/./a.jpg',
      '.. before folder': '/x/../attachments/$fa/a.jpg',
      'file:// ..': 'file:///x/attachments/$fa/../a.jpg',
      'file:// %2e%2e': 'file:///x/attachments/$fa/%2e%2e/a.jpg',
      'file:// %2E%2E': 'file:///x/attachments/$fa/%2E%2E/a.jpg',
      'file:// .%2e': 'file:///x/attachments/$fa/.%2e/a.jpg',
      'file:// %2e': 'file:///x/attachments/$fa/%2e/a.jpg',
      'file:// remote host': 'file://evil/x/attachments/$fa/a.jpg',
      'file:// query': 'file:///x/attachments/$fa/a.jpg?x=1',
      'file:// fragment': 'file:///x/attachments/$fa/a.jpg#f',
      'content://': 'content://media/x/attachments/$fa/a.jpg',
      'https': 'https://h/attachments/$fa/a.jpg',
      'NUL': '/x/attachments/$fa/a\u0000.jpg',
      'backslash': r'C:\x\attachments\' '$fa' r'\a.jpg',
      'other owner': '/x/attachments/$fb/a.jpg',
      'two owner pairs': '/x/attachments/$fb/attachments/$fa/a.jpg',
      'nothing below owner': '/x/attachments/$fa',
      'nothing below owner, slash': '/x/attachments/$fa/',
      'legacy image_picker cache':
          '/data/user/0/com.x/cache/image_picker123.jpg',
      'Android picker uuid cache':
          '/data/user/0/com.x/cache/7f0c-uuid/IMG_1.jpg',
      'iOS tmp': '/private/var/mobile/.../tmp/image_picker_ABC.jpg',
      'unknown folder kind': '/x/photos/$fa/a.jpg',
      'empty': '',
    };
    cases.forEach((name, s) {
      test(name, () => expect(key(s), isNull, reason: s));
    });
  });

  group('KEY-04 null keys fail closed on the DB side', () {
    Set<String> keys(List<String> paths) =>
        AttachmentRefs.referencedKeys(paths, ownerFolderName: fa);

    test('web links, gs:// and Storage paths are skipped, not refused', () {
      expect(
          keys([
            '',
            'https://firebasestorage.googleapis.com/v0/b/x/o/a?alt=media',
            'http://h/a.jpg',
            'gs://bucket/clinical_attachments/u/p/a.jpg',
            'clinical_attachments/$ownerA/p1/a.jpg',
            'doctor_profiles/$ownerA/a.jpg',
            '/x/attachments/$fa/kept.jpg',
          ]),
          {'attachments/kept.jpg'});
    });

    for (final s in [
      '/data/user/0/com.x/cache/image_picker123.jpg',
      '/x/attachments/$fb/a.jpg',
      'file:///x/attachments/$fa/%2e%2e/a.jpg',
      '/x/attachments/$fa/../a.jpg',
      'content://media/1',
      'https:/no-host.jpg',
      'gs:///no-bucket',
      'clinical_attachments/../a.jpg',
      'clinical_attachments',
      '/clinical_attachments/u/p/a.jpg',
      'relative/elsewhere.jpg',
    ]) {
      test('unkeyable -> unrecognisedPath: $s', () {
        expect(
            () => keys(['/x/attachments/$fa/ok.jpg', s]),
            throwsA(isA<AttachmentScanIncomplete>().having((e) => e.reason,
                'reason', AttachmentScanFailure.unrecognisedPath)));
      });
    }

    test('the exception text names the reason only, never the path', () {
      const secret = 'Priya_Sharma_9876543210';
      try {
        keys(['/data/user/0/com.x/cache/$secret.jpg']);
        fail('should throw');
      } on AttachmentScanIncomplete catch (e) {
        expect(e.toString(), 'AttachmentScanIncomplete(unrecognisedPath)');
        expect(e.toString(), isNot(contains(secret)));
      }
      for (final r in AttachmentScanFailure.values) {
        final t = AttachmentScanIncomplete(r).toString();
        expect(t, 'AttachmentScanIncomplete(${r.name})');
        expect(t, isNot(contains('/')));
      }
    });
  });

  group('KEY-05 collectReferencedPaths: every unreadable row fails closed', () {
    Set<String> collect(List<Object?> h, [Object? profile]) =>
        AttachmentRefs.collectReferencedPaths(
            historyValues: h, doctorProfileValue: profile);
    Matcher reason(AttachmentScanFailure r) => throwsA(
        isA<AttachmentScanIncomplete>().having((e) => e.reason, 'reason', r));

    test('null history = no visits; absent attachmentPaths = none', () {
      expect(collect([null, '[]', '[{}]', '[{"attachmentPaths":null}]']),
          isEmpty);
    });
    test('rows', () {
      for (final bad in <Object?>[
        'not json',
        '{}',
        '"x"',
        '[1]',
        '[null]',
        42,
        <int>[1],
      ]) {
        expect(() => collect(['[]', bad]),
            reason(AttachmentScanFailure.unreadableRow),
            reason: '$bad');
      }
    });
    test('attachment lists', () {
      for (final bad in [
        '[{"attachmentPaths":"a.jpg"}]',
        '[{"attachmentPaths":[1]}]',
        '[{"attachmentPaths":[null]}]',
        '[{"attachmentPaths":{"a":1}}]',
      ]) {
        expect(() => collect([bad]),
            reason(AttachmentScanFailure.unreadableAttachmentList),
            reason: bad);
      }
    });
    test('doctor profile setting', () {
      expect(collect([], '{}'), isEmpty);
      expect(collect([], '{"profileImageUrl":null}'), isEmpty);
      expect(collect([], '{"profileImageUrl":"/x/profile/$fa/p.jpg"}'),
          {'/x/profile/$fa/p.jpg'});
      for (final bad in <Object?>['nope', '[]', '{"profileImageUrl":5}', 7]) {
        expect(() => collect([], bad),
            reason(AttachmentScanFailure.unreadableDoctorProfile),
            reason: '$bad');
      }
    });
  });

  group('KEY-06 LocalDatabase.referencedAttachmentKeys (fake on #10 API)', () {
    late FakeLocalDatabase db;
    setUp(() => db = FakeLocalDatabase()..state = const DbReady(ownerA));

    test('dirty (unsynced) rows count as referenced', () async {
      await db.insertPatient(_patient('p1', [
        _visit('v1', ['/data/user/0/x/files/attachments/$fa/a.jpg'])
      ]));
      expect(db.dirty['p1'], isTrue, reason: 'precondition: row unsynced');
      expect(await db.referencedAttachmentKeys(), {'attachments/a.jpg'});
    });

    test('profile photo is referenced only through the doctor setting',
        () async {
      expect(await db.referencedAttachmentKeys(), isEmpty);
      await db.putSetting(AttachmentRefs.doctorProfileSettingKey,
          jsonEncode({'name': 'Dr A', 'profileImageUrl': '/x/profile/$fa/p.jpg'}));
      expect(await db.referencedAttachmentKeys(), {'profile/p.jpg'});
    });

    test('closed / opening / failed DB -> typed exception, never empty set',
        () async {
      for (final (st, r) in [
        (const DbClosed() as DbOpenState, AttachmentScanFailure.noDatabase),
        (const DbFailed(ownerA, DbOpenError.migrationFailed) as DbOpenState,
            AttachmentScanFailure.openFailed),
      ]) {
        db.state = st;
        await expectLater(
            db.referencedAttachmentKeys(),
            throwsA(isA<AttachmentScanIncomplete>()
                .having((e) => e.reason, 'reason', r)));
      }
    });

    test('tombstone (a): after markPendingDelete the photos are unreferenced',
        () async {
      await db.insertPatient(_patient('p1', [
        _visit('v1', ['/x/attachments/$fa/gone.jpg'])
      ]));
      await db.insertPatient(_patient('p2', [
        _visit('v2', ['/x/attachments/$fa/kept.jpg'])
      ]));
      await db.markPendingDelete('p1');
      expect(await db.pendingDeletes(), ['p1']);
      expect(await db.referencedAttachmentKeys(), {'attachments/kept.jpg'});
    });

    test('tombstone (b): a refused markPendingDelete keeps them referenced',
        () async {
      await db.insertPatient(_patient('p1', [
        _visit('v1', ['/x/attachments/$fa/a.jpg'])
      ]));
      db.refuseDeletes = true;
      await expectLater(db.markPendingDelete('p1'), throwsA(anything));
      expect(await db.referencedAttachmentKeys(), {'attachments/a.jpg'});
    });

    test('a legacy picker path in any row skips everything (unrecognised)',
        () async {
      await db.insertPatient(_patient('p1', [
        _visit('v1', ['/x/attachments/$fa/a.jpg'])
      ]));
      await db.insertPatient(_patient('p2', [
        _visit('v2', ['/data/user/0/com.x/cache/image_picker99.jpg'])
      ]));
      await expectLater(
          db.referencedAttachmentKeys(),
          throwsA(isA<AttachmentScanIncomplete>().having((e) => e.reason,
              'reason', AttachmentScanFailure.unrecognisedPath)));
    });

    test('keys are per open owner: B never sees A\'s photo as its own',
        () async {
      await db.insertPatient(_patient('p1', [
        _visit('v1', ['/x/attachments/$fa/a.jpg'])
      ]));
      db.state = const DbReady(ownerB);
      // A's path is not B's: refused, so B's sweep can't count it as "free".
      await expectLater(
          db.referencedAttachmentKeys(),
          throwsA(isA<AttachmentScanIncomplete>().having((e) => e.reason,
              'reason', AttachmentScanFailure.unrecognisedPath)));
    });
  });
}
