import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/models/doctor.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/log_codes.dart';
import 'package:docease/providers/local_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Doctor doc({String id = 'x', String? image}) => Doctor(
    id: id, title: 'DR', name: 'Asha', email: 'a@x.in', age: '40', mobileNumber: '999',
    specialty: 'GP', clinicName: 'C', practiceMode: 'Solo Practice', profileImageUrl: image);

void main() {
  late FakeFirestore fs;
  late FakeAuth auth;
  late FakeStorage storage;
  late Directory tmp;

  setUp(() {
    fs = FakeFirestore();
    auth = FakeAuth('a');
    storage = FakeStorage();
    tmp = Directory.systemTemp.createTempSync('docease_prov');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  String file(String name, int bytes) =>
      (File('${tmp.path}/$name')..writeAsBytesSync(List.filled(bytes, 1))).path;

  group('DoctorProvider', () {
    test('save merges, forces id to the signed-in uid and keeps other fields', () async {
      fs.docs['doctors/a'] = {'frequentMedicines': ['Paracetamol'], 'profileImageUrl': 'u1'};
      final p = DoctorProvider(auth: auth, firestore: fs, storage: storage);
      expect(await p.saveDoctorProfile(doc(id: 'someone-else')), isTrue);
      expect(fs.log.last, 'set:doctors/a:merge');
      expect(fs.docs['doctors/a']!['id'], 'a');
      expect(fs.docs['doctors/a']!['frequentMedicines'], ['Paracetamol']);
      expect(fs.docs['doctors/a']!['profileImageUrl'], 'u1', reason: 'null image never erases the photo');
      expect(p.currentDoctor!.id, 'a');
    });

    test('save refused when signed out or after a session switch', () async {
      final p = DoctorProvider(auth: auth, firestore: fs, storage: storage);
      await p.load('a');
      auth.signIn('b');
      expect(await p.saveDoctorProfile(doc()), isFalse);
      auth.currentUser = null;
      expect(await p.saveDoctorProfile(doc()), isFalse);
      expect(fs.log.where((l) => l.startsWith('set:')), isEmpty);
    });

    test('avatar goes to doctor_profiles/{uid}/{timestamp}.{ext} with its content type', () async {
      final p = DoctorProvider(auth: auth, firestore: fs, storage: storage);
      final url = await p.uploadProfileImage(File(file('me.png', 10)));
      expect(url, isNotNull);
      final path = storage.uploads.keys.single;
      expect(path, matches(RegExp(r'^doctor_profiles/a/\d+\.png$')));
      expect(storage.uploads[path], 'image/png');
    });

    test('avatar over 5 MiB or of another type is rejected before upload', () async {
      final p = DoctorProvider(auth: auth, firestore: fs, storage: storage);
      await expectLater(p.uploadProfileImage(File(file('big.jpg', AttachmentPolicy.maxAvatarBytes + 1))),
          throwsA(isA<UnsupportedAttachmentException>().having((e) => e.reason, 'r', AttachmentRejection.tooLarge)));
      await expectLater(p.uploadProfileImage(File(file('me.gif', 10))),
          throwsA(isA<UnsupportedAttachmentException>().having((e) => e.fileName, 'f', 'me.gif')));
      expect(storage.uploads, isEmpty);
    });

    test('clear() drops the profile and a late load result', () async {
      fs.docs['doctors/a'] = doc(id: 'a').toJson();
      final p = DoctorProvider(auth: auth, firestore: fs, storage: storage);
      final f = p.load('a');
      p.clear();
      await f;
      expect(p.currentDoctor, isNull);
    });
  });

  group('MedicineProvider', () {
    test('reads doctors/{uid}/settings/medicines.items', () async {
      fs.docs['doctors/a/settings/medicines'] = {'items': ['A', 'B']};
      final m = MedicineProvider(auth: auth, firestore: fs);
      await m.load('a');
      expect(m.frequentMedicines, ['A', 'B']);
      expect(fs.log, isNot(contains('get:doctors/a')), reason: 'no legacy read once migrated');
    });

    test('one-time copy of the legacy field, sanitized', () async {
      fs.docs['doctors/a'] = {
        'frequentMedicines': [' Para ', 'Para', '', 'x' * 201, 'line\nbreak', 7, 'Amox']
      };
      final m = MedicineProvider(auth: auth, firestore: fs);
      await m.load('a');
      expect(m.frequentMedicines, ['Para', 'Amox']);
      expect(fs.docs['doctors/a/settings/medicines'], {'items': ['Para', 'Amox']});
      expect(fs.docs['doctors/a']!['frequentMedicines'], isNotNull, reason: 'legacy field left alone');

      // Next session reads the settings doc only.
      fs.log.clear();
      final m2 = MedicineProvider(auth: auth, firestore: fs);
      await m2.load('a');
      expect(fs.log, ['get:doctors/a/settings/medicines']);
    });

    test('failed migration write keeps the list and retries on next load', () async {
      fs.docs['doctors/a'] = {'frequentMedicines': ['Para']};
      fs.failWrites = FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      final m = MedicineProvider(auth: auth, firestore: fs);
      await m.load('a');
      expect(m.frequentMedicines, ['Para']);
      fs.failWrites = null;
      await m.load('a');
      expect(fs.docs['doctors/a/settings/medicines'], {'items': ['Para']});
    });

    test('addMedicineIfNew writes the whole list with merge; a profile save no longer wipes it', () async {
      fs.docs['doctors/a/settings/medicines'] = {'items': ['A']};
      final m = MedicineProvider(auth: auth, firestore: fs);
      await m.load('a');
      await m.addMedicineIfNew(' B ');
      await m.addMedicineIfNew('A');
      expect(fs.docs['doctors/a/settings/medicines'], {'items': ['A', 'B']});
      expect(fs.log.last, 'set:doctors/a/settings/medicines:merge');

      await DoctorProvider(auth: auth, firestore: fs, storage: storage).saveDoctorProfile(doc());
      expect(fs.docs['doctors/a/settings/medicines'], {'items': ['A', 'B']});
    });

    test('no write after the user changed', () async {
      final m = MedicineProvider(auth: auth, firestore: fs);
      await m.load('a');
      fs.log.clear();
      auth.signIn('b');
      await m.addMedicineIfNew('C');
      expect(fs.log.where((l) => l.startsWith('set:')), isEmpty);
    });

    test('sanitize caps at 2000 items', () {
      final out = MedicineProvider.sanitize(List.generate(2500, (i) => 'm$i'));
      expect(out.length, MedicineProvider.maxItems);
    });
  });

  group('FirestoreHelper', () {
    test('writes only to the signed-in doctor\'s folder', () async {
      final h = helperOn(fs, auth);
      expect(await h.syncPatient(testPatient('p1')), isTrue);
      expect(fs.docs.keys, ['doctors/a/patients/p1']);
    });

    test('refuses everything once the session uid is no longer signed in', () async {
      var session = 'a';
      final h = helperOn(fs, auth, expectedUid: () => session);
      auth.signIn('b');
      expect(await h.syncPatient(testPatient('p1')), isFalse);
      expect(await h.deletePatient('p1'), isFalse);
      expect(await h.fetchAllPatients(), isEmpty);
      expect(fs.docs, isEmpty);
      expect(fs.log, isEmpty, reason: 'B\'s folder is never touched');
      session = 'b';
      expect(await h.syncPatient(testPatient('p1')), isTrue);
      expect(fs.docs.keys, ['doctors/b/patients/p1']);
    });

    test('signed out: nothing is read or written', () async {
      auth.currentUser = null;
      final h = helperOn(fs, auth);
      expect(await h.syncPatient(testPatient('p1')), isFalse);
      expect(await h.fetchAllPatients(), isEmpty);
      expect(fs.log, isEmpty);
    });

    test('fetch returns this doctor\'s patients with their doc ids', () async {
      fs.docs['doctors/a/patients/p1'] = testPatient('p1').toJson();
      fs.docs['doctors/b/patients/p2'] = testPatient('p2').toJson();
      final got = await helperOn(fs, auth).fetchAllPatients();
      expect(got.map((p) => p.id), ['p1']);
    });
  });

  group('AttachmentPolicy', () {
    const sp = 'clinical_attachments/a/p1/0f1e2d3c-aaaa-bbbb-cccc-123456789abc.jpg';
    test('classify', () {
      expect(AttachmentPolicy.classify(sp, 'a', 'p1'), AttachmentEntryKind.storagePath);
      expect(AttachmentPolicy.classify('clinical_attachments/a/p2/x.jpg', 'a', 'p1'), AttachmentEntryKind.invalid);
      expect(AttachmentPolicy.classify('clinical_attachments/a/p1/../b/x.jpg', 'a', 'p1'), AttachmentEntryKind.invalid);
      expect(AttachmentPolicy.classify('clinical_attachments/a/p1/x.pdf', 'a', 'p1'), AttachmentEntryKind.invalid);
      final url = 'https://firebasestorage.googleapis.com/v0/b/demo-docease.appspot.com/o/'
          '${Uri.encodeComponent(sp)}?alt=media&token=t';
      expect(AttachmentPolicy.classify(url, 'a', 'p1', bucket: 'demo-docease.appspot.com'),
          AttachmentEntryKind.legacyDownloadUrl);
      expect(AttachmentPolicy.classify(url, 'a', 'p1', bucket: 'other'), AttachmentEntryKind.invalid);
      expect(AttachmentPolicy.classify(url.replaceFirst('https', 'http'), 'a', 'p1'), AttachmentEntryKind.invalid);
      expect(AttachmentPolicy.classify(url.replaceFirst('firebasestorage.googleapis.com', 'evil.com'), 'a', 'p1'),
          AttachmentEntryKind.invalid);
      expect(AttachmentPolicy.classify('/data/user/0/app/cache/x.jpg', 'a', 'p1'), AttachmentEntryKind.localFile);
      expect(AttachmentPolicy.classify('/data/../etc/passwd', 'a', 'p1'), AttachmentEntryKind.invalid);
      expect(AttachmentPolicy.classify('content://media/1', 'a', 'p1'), AttachmentEntryKind.invalid);
    });

    test('content type by extension', () {
      expect(UploadImageType.forPath('/x/a.JPEG')!.contentType, 'image/jpeg');
      expect(UploadImageType.forPath('/x/a.jpg')!.fileExtension, 'jpg');
      expect(UploadImageType.forPath('/x/a.png')!.contentType, 'image/png');
      expect(UploadImageType.forPath('/x/a.webp')!.contentType, 'image/webp');
      expect(UploadImageType.forPath('/x/a.heic'), isNull);
      expect(UploadImageType.forPath('/x/noext'), isNull);
    });
  });

  group('errorCode (sanitized logs)', () {
    test('never includes exception messages', () {
      expect(errorCode(StateError('PRAGMA key = "deadbeef"')), 'StateError');
      expect(errorCode(FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied',
          message: 'doctors/a/patients/p1 Asha')), 'cloud_firestore/permission-denied');
      expect(errorCode(DbOpenException(DbOpenError.keyMismatch, cause: 'key=deadbeef')),
          'DbOpenException(keyMismatch)');
      expect(errorCode(UnsupportedAttachmentException('Asha_scan.pdf', AttachmentRejection.unsupportedType)),
          'UnsupportedAttachment(unsupportedType)');
    });
  });
}
