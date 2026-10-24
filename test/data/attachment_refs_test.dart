// Host unit tests for attachment references (photo sweep support):
// AttachmentRefs.attachmentKey / isNonLocalRef / collectReferencedPaths /
// referencedKeys, and DatabaseHelper failing closed without an open DB.
// Real SQLCipher round trips are ATT-* in integration_test/support/db_suite.dart.
import 'dart:convert';
import 'dart:io';

import 'package:docease/providers/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';

// sha256(owner) hex, first 32 chars (python hashlib known answers).
const ownerA = '82c10fd937b1ded72e4f454cb41fcc15'; // 'doctorA'
const ownerB = 'd19d2eb1dc5a8cab475fa8b4ee958454'; // 'doctorB'
const ownerLocal = '25bf8e1a2393f1108d37029b3df55932'; // 'local'

String? key(String path, [String owner = ownerA]) =>
    LocalDatabase.attachmentKey(path, ownerFolderName: owner);

Matcher scanFails(AttachmentScanFailure reason) => throwsA(
    isA<AttachmentScanIncomplete>().having((e) => e.reason, 'reason', reason));

String history(List<Object?> visits) => jsonEncode(visits);
Map<String, Object?> visit(List<Object?>? paths) =>
    {'id': 'v', 'date': '2026-01-01T00:00:00.000', 'attachmentPaths': paths};

void main() {
  group('ownerFolderNameFor', () {
    test('sha256 hex, first 32 chars; same hash as the DB file name', () {
      expect(LocalDatabase.ownerFolderNameFor('doctorA'), ownerA);
      expect(LocalDatabase.ownerFolderNameFor('doctorB'), ownerB);
      expect(LocalDatabase.ownerFolderNameFor('local'), ownerLocal);
      expect(DatabaseHelper.dbFileNameFor('doctorA'), 'docease_$ownerA.db');
    });
  });

  group('attachmentKey', () {
    test('/data/user/0 and /data/data variants give the same key', () {
      const a = '/data/user/0/com.docease.app/files/attachments/$ownerA/3f2c.jpg';
      const b = '/data/data/com.docease.app/files/attachments/$ownerA/3f2c.jpg';
      expect(key(a), 'attachments/3f2c.jpg');
      expect(key(b), key(a));
      // iOS: /private/var vs /var
      expect(key('/private/var/mobile/Containers/Data/Application/X/Library/'
              'Application Support/attachments/$ownerA/3f2c.jpg'),
          key('/var/mobile/Containers/Data/Application/X/Library/'
              'Application Support/attachments/$ownerA/3f2c.jpg'));
    });

    test('relative and absolute stored paths give the same key', () {
      expect(key('attachments/$ownerA/3f2c.jpg'), 'attachments/3f2c.jpg');
      expect(key('/data/user/0/pkg/files/attachments/$ownerA/3f2c.jpg'),
          key('attachments/$ownerA/3f2c.jpg'));
      expect(key('//data//user/0/pkg/files/attachments//$ownerA/3f2c.jpg'),
          'attachments/3f2c.jpg');
    });

    test('profile folder keeps its kind; nested names are kept', () {
      expect(key('/s/profile/$ownerA/avatar_9a1e.png'), 'profile/avatar_9a1e.png');
      expect(key('/s/attachments/$ownerA/sub/x.webp'), 'attachments/sub/x.webp');
      expect(key('/s/attachments/$ownerA/x.jpg'),
          isNot(key('/s/profile/$ownerA/x.jpg')));
    });

    test('file:// URIs are parsed into a path first', () {
      const plain = '/data/user/0/pkg/files/attachments/$ownerA/a b.jpg';
      expect(key('file:///data/user/0/pkg/files/attachments/$ownerA/a%20b.jpg'),
          'attachments/a b.jpg');
      expect(key('file:///data/user/0/pkg/files/attachments/$ownerA/a%20b.jpg'),
          key(plain));
      expect(key('FILE:///data/data/pkg/files/attachments/$ownerA/a%20b.jpg'),
          key(plain));
      expect(key('file://localhost/s/attachments/$ownerA/a.jpg'),
          'attachments/a.jpg');
      expect(key('file://otherhost/s/attachments/$ownerA/a.jpg'), isNull);
      expect(key('file:///s/attachments/$ownerA/a.jpg?x=1'), isNull);
    });

    test('.. segments give null, also percent-encoded', () {
      expect(key('/s/attachments/$ownerA/../$ownerA/a.jpg'), isNull);
      expect(key('/s/../s/attachments/$ownerA/a.jpg'), isNull);
      expect(key('attachments/$ownerA/../../etc/passwd'), isNull);
      expect(key('file:///s/attachments/$ownerA/%2E%2E/a.jpg'), isNull);
      // Uri.parse would normalise these away; they must still be rejected.
      expect(key('file:///s/attachments/$ownerB/../$ownerA/a.jpg'), isNull);
      expect(key('file:///s/attachments/$ownerB/%2e%2E/$ownerA/a.jpg'), isNull);
      expect(key('file:///s/./attachments/$ownerA/a.jpg'), isNull);
      expect(key('/s/attachments/$ownerA/./a.jpg'), isNull);
    });

    test("another owner's folders give null", () {
      expect(key('/s/attachments/$ownerB/a.jpg'), isNull);
      expect(key('/s/profile/$ownerB/avatar_1.png'), isNull);
      expect(key('/s/attachments/$ownerB/a.jpg', ownerB), 'attachments/a.jpg');
      // Mine nested inside another owner's folder (or vice versa) is
      // ambiguous: never guessed.
      expect(key('/s/attachments/$ownerB/attachments/$ownerA/a.jpg'), isNull);
      expect(key('/s/attachments/$ownerA/attachments/$ownerB/a.jpg'), isNull);
    });

    test('anything else outside the owner folders gives null', () {
      for (final path in [
        '',
        '/',
        '/s/attachments/$ownerA',
        '/s/attachments/$ownerA/',
        '/s/attachments/a.jpg', // directly in the root, no owner folder
        '/s/attachments/${ownerA.toUpperCase()}/a.jpg',
        '/s/photos/$ownerA/a.jpg',
        '/data/user/0/pkg/cache/image_picker123.jpg', // legacy picker path
        'a.jpg',
        r'C:\s\attachments\' '$ownerA' r'\a.jpg',
        '/s/attachments/$ownerA/a\u0000.jpg',
        'https://example.com/attachments/$ownerA/a.jpg',
        'content://media/attachments/$ownerA/a.jpg',
        'clinical_attachments/doctorA/p1/a.jpg',
      ]) {
        expect(key(path), isNull, reason: path);
      }
    });

    test('a real symlinked app dir gives the same key as the resolved path',
        () {
      final tmp = Directory.systemTemp.createTempSync('docease_att_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final real = Directory(p.join(tmp.path, 'real', 'files', 'attachments', ownerA))
        ..createSync(recursive: true);
      File(p.join(real.path, 'a.jpg')).writeAsBytesSync([1, 2, 3]);
      Link(p.join(tmp.path, 'link')).createSync(p.join(tmp.path, 'real'));

      final viaLink = p.join(tmp.path, 'link', 'files', 'attachments', ownerA, 'a.jpg');
      final resolved = File(viaLink).resolveSymbolicLinksSync();
      expect(resolved, isNot(viaLink), reason: 'the test needs a real symlink');
      expect(File(resolved).existsSync(), isTrue);
      expect(key(viaLink), 'attachments/a.jpg');
      expect(key(resolved), key(viaLink));
    });

    test('ownerFolderName must be a 32-hex owner folder name', () {
      expect(() => key('/s/attachments/$ownerA/a.jpg', 'doctorA'),
          throwsArgumentError);
      expect(() => key('/s/attachments/$ownerA/a.jpg', ownerA.toUpperCase()),
          throwsArgumentError);
    });
  });

  group('isNonLocalRef', () {
    test('web links, gs:// URIs and Storage paths are non-local', () {
      for (final ref in [
        'https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/'
            'clinical_attachments%2FdoctorA%2Fp1%2Fa.jpg?alt=media&token=t',
        'http://example.com/a.jpg',
        'HTTPS://example.com/a.jpg',
        'gs://x.appspot.com/clinical_attachments/doctorA/p1/a.jpg',
        'clinical_attachments/doctorA/p1/a.jpg',
        'doctor_profiles/doctorA/1700000000.jpg',
      ]) {
        expect(AttachmentRefs.isNonLocalRef(ref), isTrue, reason: ref);
      }
    });

    test('local paths, other schemes and malformed Storage paths are not', () {
      for (final ref in [
        '/data/user/0/pkg/files/attachments/$ownerA/a.jpg',
        'attachments/$ownerA/a.jpg',
        'file:///s/attachments/$ownerA/a.jpg',
        'content://media/external/images/1',
        'ftp://example.com/a.jpg',
        'https:///no-host.jpg',
        'clinical_attachments',
        'clinical_attachments/../attachments/x.jpg',
        'clinical_attachments//x.jpg',
        '/clinical_attachments/doctorA/p1/a.jpg',
        '',
      ]) {
        expect(AttachmentRefs.isNonLocalRef(ref), isFalse, reason: ref);
      }
    });
  });

  group('collectReferencedPaths (fail closed)', () {
    test('mix of patients and visits; exact strings; profile photo included', () {
      final paths = AttachmentRefs.collectReferencedPaths(historyValues: [
        history([]), // patient without visits
        null, // legacy NULL history: no visits
        history([
          visit(['/s/attachments/$ownerA/a.jpg', 'clinical_attachments/u/p/b.jpg']),
          visit(null), // visit without attachments field value
          {'id': 'v3'}, // attachmentPaths absent
          visit([]),
        ]),
        history([
          visit(['/s//attachments/./$ownerA/odd.jpg', '']),
        ]),
      ], doctorProfileValue: jsonEncode({
        'name': 'Dr A',
        'profileImageUrl': '/s/profile/$ownerA/avatar_1.png',
      }));
      expect(paths, {
        '/s/attachments/$ownerA/a.jpg',
        'clinical_attachments/u/p/b.jpg',
        '/s//attachments/./$ownerA/odd.jpg', // as stored, not normalised
        '',
        '/s/profile/$ownerA/avatar_1.png',
      });
    });

    test('empty input gives an empty set', () {
      expect(AttachmentRefs.collectReferencedPaths(historyValues: const []),
          isEmpty);
      expect(
          AttachmentRefs.collectReferencedPaths(
              historyValues: const [], doctorProfileValue: '{"name":"x"}'),
          isEmpty);
    });

    test('one corrupt row throws instead of returning the rest', () {
      final good = history([visit(['/s/attachments/$ownerA/a.jpg'])]);
      for (final bad in <Object?>[
        '{not json',
        '',
        '{"id":"v"}', // object, not a list
        'null',
        '[1]', // entry is not an object
        42, // not TEXT
      ]) {
        expect(
            () => AttachmentRefs.collectReferencedPaths(
                historyValues: [good, bad, good]),
            scanFails(AttachmentScanFailure.unreadableRow),
            reason: '$bad');
      }
    });

    test('a corrupt attachmentPaths list throws, never a partial list', () {
      for (final bad in <Object?>[
        '/s/attachments/$ownerA/a.jpg', // string, not a list
        {'0': 'x'},
        ['/s/attachments/$ownerA/a.jpg', 7],
        [null],
      ]) {
        expect(
            () => AttachmentRefs.collectReferencedPaths(historyValues: [
                  history([visit(['/s/attachments/$ownerA/ok.jpg']), {'id': 'v', 'attachmentPaths': bad}])
                ]),
            scanFails(AttachmentScanFailure.unreadableAttachmentList),
            reason: '$bad');
      }
    });

    test('an unreadable doctor profile throws', () {
      for (final bad in <Object?>['{oops', '[]', '"x"', '{"profileImageUrl":3}', 5]) {
        expect(
            () => AttachmentRefs.collectReferencedPaths(
                historyValues: const [], doctorProfileValue: bad),
            scanFails(AttachmentScanFailure.unreadableDoctorProfile),
            reason: '$bad');
      }
    });
  });

  group('referencedKeys', () {
    test('keys local paths; skips only empty, web links and Storage refs', () {
      final keys = AttachmentRefs.referencedKeys([
        '/data/user/0/pkg/files/attachments/$ownerA/a.jpg',
        '/data/data/pkg/files/attachments/$ownerA/a.jpg', // same key
        'file:///data/user/0/pkg/files/profile/$ownerA/avatar_1.png',
        'attachments/$ownerA/rel.jpg',
        '',
        'https://firebasestorage.googleapis.com/v0/b/b/o/x?alt=media',
        'http://example.com/a.jpg',
        'gs://b/clinical_attachments/u/p/a.jpg',
        'clinical_attachments/u/p/a.jpg',
        'doctor_profiles/u/1.jpg',
      ], ownerFolderName: ownerA);
      expect(keys, {'attachments/a.jpg', 'profile/avatar_1.png', 'attachments/rel.jpg'});
    });

    test('a legacy or unknown local format throws, it is never dropped', () {
      for (final path in [
        '/data/user/0/pkg/cache/image_picker123.jpg',
        'photo.jpg',
        'content://media/external/images/1',
        '/s/attachments/$ownerA/../x.jpg',
        'clinical_attachments/../attachments/x.jpg',
        ' ',
      ]) {
        expect(
            () => AttachmentRefs.referencedKeys(
                ['/s/attachments/$ownerA/ok.jpg', path],
                ownerFolderName: ownerA),
            scanFails(AttachmentScanFailure.unrecognisedPath),
            reason: path);
      }
    });

    test("another owner's path throws", () {
      expect(
          () => AttachmentRefs.referencedKeys(
              ['/s/attachments/$ownerB/b.jpg'], ownerFolderName: ownerA),
          scanFails(AttachmentScanFailure.unrecognisedPath));
    });

    test('the exception names only the reason, never the path', () {
      const marker = 'PATIENT-MARKER-91c2';
      try {
        AttachmentRefs.referencedKeys(['/s/other/$marker.jpg'],
            ownerFolderName: ownerA);
        fail('expected AttachmentScanIncomplete');
      } on AttachmentScanIncomplete catch (e) {
        expect(e.toString(), 'AttachmentScanIncomplete(unrecognisedPath)');
        expect(e.toString(), isNot(contains(marker)));
      }
      try {
        AttachmentRefs.collectReferencedPaths(
            historyValues: ['{"$marker"']);
        fail('expected AttachmentScanIncomplete');
      } on AttachmentScanIncomplete catch (e) {
        expect(e.toString(), isNot(contains(marker)));
      }
    });
  });

  group('DatabaseHelper scan without an open database', () {
    late Directory dir;
    late MemoryKeyStore keys;
    late RecordingOpener opener;
    DatabaseHelper helper() => DatabaseHelper(
        keyStore: keys, opener: opener, databasesPath: () async => dir.path);

    setUp(() {
      dir = Directory.systemTemp.createTempSync('docease_att_db_');
      keys = MemoryKeyStore();
      opener = RecordingOpener();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    test('never opened: both methods throw noDatabase, nothing opened', () async {
      final h = helper();
      await expectLater(h.referencedAttachmentPaths(),
          scanFails(AttachmentScanFailure.noDatabase));
      await expectLater(h.referencedAttachmentKeys(),
          scanFails(AttachmentScanFailure.noDatabase));
      expect(opener.calls, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('open failed: both methods throw openFailed, no open attempted', () async {
      keys.failRead = true;
      final h = helper();
      await expectLater(h.openFor('doctorA'), throwsA(isA<DbOpenException>()));
      expect(h.state, isA<DbFailed>());
      await expectLater(h.referencedAttachmentPaths(),
          scanFails(AttachmentScanFailure.openFailed));
      await expectLater(h.referencedAttachmentKeys(),
          scanFails(AttachmentScanFailure.openFailed));
      expect(opener.calls, isEmpty);
    });
  });

  group('QA: file://localhost and file:/// key like the absolute path', () {
    const uuid = '0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f';
    const supportDirs = [
      '/data/user/0/com.docease.app/files', // Android
      '/var/mobile/Containers/Data/Application/'
          'A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF/Library/Application Support', // iOS
    ];

    test('absolute path, file:/// and file://localhost give the same key', () {
      for (final dir in supportDirs) {
        for (final (folder, name) in [
          ('attachments', '$uuid.jpg'),
          ('profile', 'avatar_$uuid.png'),
        ]) {
          final abs = '$dir/$folder/$ownerA/$name';
          final encoded = Uri.file(abs).path; // percent-encodes the space
          final forms = {
            'absolute': abs,
            'file:///': 'file://$encoded',
            'file://localhost/': 'file://localhost$encoded',
            'file://LOCALHOST/': 'file://LOCALHOST$encoded',
          };
          for (final MapEntry(key: what, value: stored) in forms.entries) {
            expect(key(stored), '$folder/$name', reason: '$what: $stored');
          }
          // Same set of keys, so the sweep sees one referenced file.
          expect(
              AttachmentRefs.referencedKeys(forms.values,
                  ownerFolderName: ownerA),
              {'$folder/$name'});
        }
      }
    });

    test('any other host is unrecognised and makes the scan throw', () {
      final path = '/data/user/0/com.docease.app/files/attachments/$ownerA/$uuid.jpg';
      final hostile = [
        'file://evil$path',
        'file://evil.example.com$path',
        'file://localhost.evil$path',
        'file://127.0.0.1$path',
        'file://[::1]$path',
        'file://localhost:80$path',
        'file://user@localhost$path',
      ];
      for (final stored in hostile) {
        expect(key(stored), isNull, reason: stored);
        expect(AttachmentRefs.isNonLocalRef(stored), isFalse, reason: stored);
        // The same pipeline the DB-side scan runs: never a partial set.
        final paths = AttachmentRefs.collectReferencedPaths(historyValues: [
          history([
            visit([path, 'file://localhost$path', stored]),
          ]),
        ]);
        expect(paths, {path, 'file://localhost$path', stored}); // as stored
        expect(
            () => AttachmentRefs.referencedKeys(paths, ownerFolderName: ownerA),
            scanFails(AttachmentScanFailure.unrecognisedPath),
            reason: stored);
      }
    });
  });
}
