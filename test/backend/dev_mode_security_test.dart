// PR #13 security review fixes:
//  H1  a release build can never run in dev mode (kReleaseMode gate, refusal
//      screen, Android `dev` flavor with its own app id and label);
//  M2  dev ("local") and real-account photos live in separate owner folders,
//      and every cloud path refuses the "local" owner explicitly;
//  L   PDFs made in dev mode carry a TEST DATA marker.
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/config/dev_mode.dart';
import 'package:docease/dev/dev_build_refused.dart';
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/firestore_helper.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:docease/services/session_platform.dart';
import 'package:docease/utils/pdf_export.dart';
import 'package:docease/widgets/avatar_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fakes.dart';

/// Every call is recorded and throws, so a call hidden behind a catch block
/// still shows up in [hits].
final hits = <String>[];

class TripAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('auth.${i.memberName}');
    throw StateError('FirebaseAuth touched for the local owner');
  }
}

class TripFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('firestore.${i.memberName}');
    throw StateError('Firestore touched for the local owner');
  }
}

class TripStorage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('storage.${i.memberName}');
    throw StateError('Storage touched for the local owner');
  }
}

class TripSecure implements FlutterSecureStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('secure.${i.memberName}');
    throw StateError('secure storage touched');
  }
}

class TripHelper extends FakeFirestoreHelper {
  @override
  Future<bool> syncPatient(Patient patient) async {
    hits.add('helper.sync');
    return true;
  }

  @override
  Future<bool> deletePatient(String patientId) async {
    hits.add('helper.delete');
    return true;
  }

  @override
  Future<List<Patient>> fetchAllPatients() async {
    hits.add('helper.fetch');
    return [];
  }
}

/// A user whose every member except uid trips (approval must not reload it).
class TripUser implements User {
  TripUser(this.uid);
  @override
  final String uid;
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('user.${i.memberName}');
    throw StateError('user touched');
  }
}

List<int> jpeg() => [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 1), 0xFF, 0xD9];

Doctor sampleDoctor(String? photo) => Doctor(
    id: 'x', title: 'DR', name: 'Test', email: 't@example.com', age: '40',
    mobileNumber: '1', specialty: 'GP', clinicName: 'Clinic', practiceMode: 'Solo Practice',
    profileImageUrl: photo);

Patient newPatient(String id) => Patient(
    id: id, name: 'Test $id', age: '30', gender: 'Female', phone: '+9100000', history: []);

VisitRecord visit(String id, List<String> photos) => VisitRecord(
    id: id,
    date: DateTime(2026, 1, 2),
    visitType: 'Consultation',
    symptoms: 'cough',
    diagnosis: 'cold',
    prescription: 'rest',
    attachmentPaths: photos);

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late Directory root;
  late Directory support;
  late Directory pickerCache;
  late LocalPhotoStore photos;

  setUp(() async {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_devsec');
    support = Directory(p.join(root.path, 'support'))..createSync();
    pickerCache = Directory(p.join(root.path, 'cache'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
  });
  tearDown(() => root.deleteSync(recursive: true));

  String pick(String name) =>
      (File(p.join(pickerCache.path, name))..writeAsBytesSync(jpeg())).path;

  // ------------------------------------------------------------------ H1
  group('H1: dev mode never runs in a release build', () {
    test('start decision: release + define is refused, never dev or normal', () {
      expect(decideStartMode(requested: false, release: false), StartMode.normal);
      expect(decideStartMode(requested: false, release: true), StartMode.normal);
      expect(decideStartMode(requested: true, release: false), StartMode.dev);
      expect(decideStartMode(requested: true, release: true), StartMode.refused);
    });

    test('kDevMode is the define AND not kReleaseMode; the define defaults off', () {
      final src = File('lib/config/dev_mode.dart').readAsStringSync();
      expect(src, contains("bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false)"));
      expect(src, contains('const bool kDevMode = kDevModeRequested && !kReleaseMode;'));
    });

    test('the start constants make the same decision as decideStartMode', () {
      final mode = decideStartMode(requested: kDevModeRequested, release: kReleaseMode);
      expect(kDevMode, mode == StartMode.dev);
      expect(kDevBuildRefused, mode == StartMode.refused);
      final src = File('lib/config/dev_mode.dart').readAsStringSync();
      expect(src, contains('const bool kDevBuildRefused = kDevModeRequested && kReleaseMode;'));
    });

    test('main() decides with the constants, before any Firebase or Google Sign-In call, and refuses in release', () {
      final main = File('lib/main.dart').readAsStringSync();
      final refused = main.indexOf('if (kDevBuildRefused) {');
      final dev = main.indexOf('if (kDevMode) {');
      expect(refused, greaterThan(0));
      expect(dev, greaterThan(refused));
      expect(dev, lessThan(main.indexOf('Firebase.initializeApp')));
      expect(dev, lessThan(main.indexOf('GoogleSignIn.instance')));
      expect(main.substring(refused, dev), contains('runApp(const DevBuildRefusedApp());\n    return;'));
      expect(main, isNot(contains('switch (decideStartMode')),
          reason: 'a runtime switch keeps the dev branch in release builds');
    });

    test('dev-only code is only reached directly under a const kDevMode check (tree-shaken without the define)', () {
      // Outside lib/dev/dev_mode_app.dart, each use of a dev-only symbol must
      // sit inside an open `if (kDevMode) {` block (or after `kDevMode &&`).
      final symbols = RegExp(r'buildDevModeApp\(|DevModeHome\(|devModeBannerBuilder|SessionController\.localOnly\(|LocalOnlySessionPlatform\(\)|_testDataBand\(\)|_reconcileLocal\(|kTestDataMarker\*|kTestDataFilePrefix\$');
      final allowedDefs = {
        'lib/dev/dev_mode_app.dart', // the dev wiring itself
        'lib/services/session_platform.dart', // class definition (constructor gated)
      };
      final uses = <String>[];
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final path = f.path.replaceAll(r'\', '/');
        if (allowedDefs.contains(path)) continue;
        final src = String.fromCharCodes(f.readAsBytesSync());
        for (final m in symbols.allMatches(src)) {
          final lineStart = src.lastIndexOf('\n', m.start) + 1;
          final line = src.substring(lineStart, src.indexOf('\n', m.start));
          if (line.trimLeft().startsWith('//')) continue;
          if (path == 'lib/services/session_controller.dart' && line.contains('SessionController.localOnly({')) continue;
          if (path == 'lib/services/session_controller.dart' && line.contains('Future<void> _reconcileLocal(')) continue;
          // Inside SessionController.localOnly, itself only called from the dev wiring.
          if (path == 'lib/services/session_controller.dart' && line.contains('_platform = LocalOnlySessionPlatform(),')) continue;
          if (path == 'lib/utils/pdf_export.dart' && line.contains('static pw.Widget _testDataBand()')) continue;
          uses.add('$path: ${line.trim()}');
          final before = src.substring(0, m.start);
          final ifBlock = before.lastIndexOf('if (kDevMode) {');
          final inBlock = ifBlock >= 0 &&
              '{'.allMatches(before.substring(ifBlock)).length > '}'.allMatches(before.substring(ifBlock)).length;
          expect(inBlock || line.contains('kDevMode && '), isTrue, reason: '$path: ${line.trim()}');
        }
      }
      expect(uses.where((u) => u.contains('buildDevModeApp(')), hasLength(1));
      expect(uses.where((u) => u.contains('DevModeHome(')), hasLength(1));
      expect(uses.where((u) => u.contains('devModeBannerBuilder')), hasLength(1));
    });

    test('every dev-mode entry point is gated on kDevMode (define AND not release; defence in depth)', () {
      expect(File('lib/dev/dev_mode_app.dart').readAsStringSync(),
          contains('if (!kDevMode) return const DevBuildRefusedApp();'));
      final session = File('lib/services/session_controller.dart').readAsStringSync();
      final local = session.indexOf('SessionController.localOnly({');
      expect(session.indexOf('if (!kDevMode) {', local), greaterThan(local));
      expect(session.indexOf('if (!kDevMode) {', local), lessThan(session.indexOf('_dbSub = _db.states.listen', local)),
          reason: 'refuse before anything starts');
      final platform = File('lib/services/session_platform.dart').readAsStringSync();
      expect(platform, contains('LocalOnlySessionPlatform() {\n    if (!kDevMode) {'));
      expect(File('lib/main.dart').readAsStringSync(), contains('bool get isDevMode => kDevMode && devMode;'));
      expect(File('lib/config/dev_mode.dart').readAsStringSync(),
          contains('kDevMode && (context.dependOnInheritedWidgetOfExactType<DevMode>()?.enabled ?? true)'));
    });

    testWidgets('refusal screen blocks: no home, no dev banner, back does nothing', (tester) async {
      await tester.pumpWidget(const DevBuildRefusedApp());
      expect(find.byKey(const Key('devBuildRefused')), findsOneWidget);
      expect(find.text(DevBuildRefusedApp.title), findsOneWidget);
      expect(find.byKey(const Key('devModeBanner')), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      final scope = tester.widget<PopScope>(find.byType(PopScope));
      expect(scope.canPop, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byKey(const Key('devBuildRefused')), findsOneWidget);
    });

    test('Android: `dev` flavor has its own id suffix and label; prod is unchanged', () {
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('applicationId = "com.medhistory.app.medhistory"'));
      final prod = gradle.substring(gradle.indexOf('create("prod")'), gradle.indexOf('create("dev")'));
      expect(prod, isNot(contains('applicationIdSuffix')));
      expect(prod, isNot(contains('versionNameSuffix')));
      final dev = gradle.substring(gradle.indexOf('create("dev")'));
      expect(dev, contains('applicationIdSuffix = ".dev"'));
      expect(gradle, contains('Refused: the dev flavor never builds in release mode'));
      expect(gradle, contains('Refused: DOCEASE_DEV_MODE=true needs --flavor dev'));
      final manifest = File('android/app/src/dev/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:label="DOCEase DEV"'));
      final main = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(main, isNot(contains('DOCEase DEV')));
    });

    test('docs and launch configs never build dev mode in release', () {
      for (final f in ['docs/DEV_MODE.md', '.vscode/launch.json']) {
        final lines = File(f).readAsLinesSync().where((l) => l.contains('DOCEASE_DEV_MODE=true'));
        expect(lines, isNotEmpty, reason: f);
        for (final l in lines) {
          expect(l, isNot(contains('--release')), reason: '$f: $l');
          if (l.contains('flutter build')) {
            expect(l, anyOf(contains('--profile'), contains('--debug')), reason: '$f: $l');
          }
          if (l.contains('flutter ') && !l.contains('flutter test')) {
            expect(l, contains('--flavor dev'), reason: '$f: $l');
          }
        }
      }
      final launch = File('.vscode/launch.json').readAsStringSync();
      expect(launch, isNot(contains('"release"')));
      expect(RegExp(r'"--flavor",\s*"dev"|--flavor dev|"--flavor=dev"').hasMatch(launch), isTrue);
    });
  });

  // ------------------------------------------------------------------ M2
  group('M2: owner folders', () {
    test('dev and real-account photos never share a folder', () async {
      final dev = await photos.keepVisitPhoto(kLocalOwnerId, pick('a.jpg'), UploadImageType.jpeg);
      final real = await photos.keepVisitPhoto('doctorA', pick('b.jpg'), UploadImageType.jpeg);
      final devAvatar = await photos.keepAvatar(kLocalOwnerId, pick('c.jpg'), UploadImageType.jpeg);
      final realAvatar = await photos.keepAvatar('doctorA', pick('d.jpg'), UploadImageType.jpeg);
      expect(p.dirname(dev), photos.visitFolderFor(kLocalOwnerId));
      expect(p.dirname(real), photos.visitFolderFor('doctorA'));
      expect(p.dirname(devAvatar), photos.profileFolderFor(kLocalOwnerId));
      expect(p.dirname(realAvatar), photos.profileFolderFor('doctorA'));
      expect(photos.visitFolderFor(kLocalOwnerId), isNot(photos.visitFolderFor('doctorA')));
      expect(p.split(dev), containsAllInOrder(['attachments', LocalPhotoStore.ownerFolderName(kLocalOwnerId)]));
      expect(p.split(devAvatar), containsAllInOrder(['profile', LocalPhotoStore.ownerFolderName(kLocalOwnerId)]));
      expect(dev, isNot(contains('doctorA')));
      expect(real, isNot(contains('doctorA')), reason: 'hashed: the uid is not on disk');
    });

    test('owner folder hash is the same as the owner DB file name hash', () {
      for (final o in [kLocalOwnerId, 'doctorA']) {
        expect(DatabaseHelper.dbFileNameFor(o), 'docease_${LocalPhotoStore.ownerFolderName(o)}.db');
      }
    });

    test('a photo is only an owner\'s photo in that owner\'s folders', () async {
      final dev = await photos.keepVisitPhoto(kLocalOwnerId, pick('a.jpg'), UploadImageType.jpeg);
      final real = await photos.keepVisitPhoto('doctorA', pick('b.jpg'), UploadImageType.jpeg);
      expect(photos.isAppPhoto(dev, owner: kLocalOwnerId), isTrue);
      expect(photos.isAppPhoto(dev, owner: 'doctorA'), isFalse);
      expect(photos.isAppPhoto(real, owner: kLocalOwnerId), isFalse);
      expect(photos.isAppPhoto(dev), isTrue, reason: 'display check: some owner folder');
      // The old flat layout (attachments/x.jpg) is no longer an app photo.
      expect(photos.isAppPhoto(p.join(photos.supportPath!, 'attachments', 'x.jpg')), isFalse);
      expect(photos.isAppPhoto(p.join(photos.supportPath!, 'profile', 'avatar_x.jpg')), isFalse);
      expect(
          photos.isAppPhoto(p.join(photos.visitFolderFor(kLocalOwnerId)!, '..',
              LocalPhotoStore.ownerFolderName('doctorA'), 'x.jpg'), owner: kLocalOwnerId),
          isFalse);
    });

    test('deleting for one owner never deletes another owner\'s photo', () async {
      final dev = await photos.keepVisitPhoto(kLocalOwnerId, pick('a.jpg'), UploadImageType.jpeg);
      final real = await photos.keepAvatar('doctorA', pick('b.jpg'), UploadImageType.jpeg);
      expect(await photos.deleteAppPhoto(real, owner: kLocalOwnerId), isFalse);
      expect(await photos.deleteAppPhoto(dev, owner: 'doctorA'), isFalse);
      expect(File(real).existsSync(), isTrue);
      expect(File(dev).existsSync(), isTrue);
      // A symlink in the dev folder pointing at a real photo is not followed.
      final link = Link(p.join(photos.visitFolderFor(kLocalOwnerId)!, 'link.jpg'))..createSync(real);
      expect(await photos.deleteAppPhoto(link.path, owner: kLocalOwnerId), isFalse);
      expect(File(real).existsSync(), isTrue);
      expect(await photos.deleteAppPhoto(dev, owner: kLocalOwnerId), isTrue);
      expect(File(dev).existsSync(), isFalse);
    });

    test('an empty owner is refused', () async {
      expect(() => photos.keepVisitPhoto('', pick('a.jpg'), UploadImageType.jpeg), throwsArgumentError);
      expect(photos.visitFolderFor(''), isNull);
    });

    test('avatar helper: only https URLs go to the network', () async {
      expect(avatarImageFor('https://example.com/a.jpg', photos: photos), isA<NetworkImage>());
      expect(avatarImageFor('http://example.com/a.jpg', photos: photos), isNull);
      final kept = await photos.keepAvatar(kLocalOwnerId, pick('c.jpg'), UploadImageType.jpeg);
      expect(avatarImageFor(kept, photos: photos), isA<FileImage>());
      expect(avatarImageFor(pick('x.jpg'), photos: photos), isNull);
    });
  });

  group('M2: every cloud path refuses the "local" owner, even with cloudSync on', () {
    PatientProvider cloudPatients(LocalDatabase db) => PatientProvider(
        db: db,
        cloudSync: true, // deliberately ON: the owner guard alone must stop it
        photos: photos,
        firestore: TripHelper(),
        auth: TripAuth(),
        storage: TripStorage(),
        retryBaseDelay: const Duration(milliseconds: 5),
        retryMaxDelay: const Duration(milliseconds: 10));

    test('patients: load, add, visit with photo, edit, delete, retry, fetch: no Firebase', () async {
      final db = FakeLocalDatabase()..state = const DbReady(kLocalOwnerId);
      final patients = cloudPatients(db);
      addTearDown(patients.dispose);
      await patients.loadAndSync(kLocalOwnerId);
      await patients.addPatient(newPatient('p1'));
      await patients.addRecord('p1', visit('v1', [pick('a.jpg')]));
      await settle();
      final stored = patients.findById('p1').history.single.attachmentPaths.single;
      expect(p.dirname(stored), photos.visitFolderFor(kLocalOwnerId), reason: 'kept on the phone, not uploaded');
      expect(patients.isPickedThisSession(stored), isTrue);
      await patients.updateRecord('p1', visit('v1', [stored, pick('b.jpg')]));
      await patients.retryDirty();
      await patients.syncNowForTesting();
      expect(await patients.loadAttachmentBytes('clinical_attachments/local/p1/x.jpg'), isNull);
      await patients.deleteRecord('p1', 'v1');
      await patients.deletePatient('p1');
      await settle();
      expect(hits, isEmpty);
    });

    test('FirestoreHelper refuses expected uid "local" before touching Auth', () async {
      final helper = FirestoreHelper(firestore: TripFirestore(), auth: TripAuth(), expectedUid: () => kLocalOwnerId);
      expect(await helper.syncPatient(newPatient('p1')), isFalse);
      expect(await helper.deletePatient('p1'), isFalse);
      expect(await helper.fetchAllPatients(), isEmpty);
      expect(hits, isEmpty);
    });

    test('FirestoreHelper refuses a signed-in account whose uid is "local"', () async {
      final helper = FirestoreHelper(firestore: TripFirestore(), auth: FakeAuth(kLocalOwnerId));
      expect(await helper.syncPatient(newPatient('p1')), isFalse);
      expect(await helper.fetchAllPatients(), isEmpty);
      expect(hits, isEmpty, reason: 'Firestore never reached');
    });

    test('doctor profile and photo for "local": no Firestore or Storage', () async {
      final db = FakeLocalDatabase()..state = const DbReady(kLocalOwnerId);
      final doctor = DoctorProvider(
          cloudSync: true, localDb: db, photos: photos,
          auth: TripAuth(), firestore: TripFirestore(), storage: TripStorage());
      await doctor.load(kLocalOwnerId);
      expect(doctor.ownerUid, kLocalOwnerId);
      final url = await doctor.uploadProfileImage(File(pick('me.jpg')));
      expect(p.dirname(url!), photos.profileFolderFor(kLocalOwnerId));
      expect(await doctor.saveDoctorProfile(doctor.currentDoctor ?? sampleDoctor(url)), isTrue);
      expect(hits, isEmpty);
    });

    test('doctor provider in cloud mode refuses a signed-in "local" account', () async {
      final doctor = DoctorProvider(auth: FakeAuth(kLocalOwnerId), firestore: TripFirestore(), storage: TripStorage());
      expect(doctor.ownerUid, isNull);
      expect(await doctor.saveDoctorProfile(sampleDoctor(null)), isFalse);
      expect(await doctor.uploadProfileImage(File(pick('me.jpg'))), isNull);
      expect(hits, isEmpty);
    });

    test('medicines for "local": no Firestore', () async {
      final db = FakeLocalDatabase()..state = const DbReady(kLocalOwnerId);
      final meds = MedicineProvider(cloudSync: true, localDb: db, auth: TripAuth(), firestore: TripFirestore());
      await meds.load(kLocalOwnerId);
      await meds.addMedicineIfNew('Paracetamol 500');
      expect(meds.frequentMedicines, contains('Paracetamol 500'));
      final signedInLocal = MedicineProvider(auth: FakeAuth(kLocalOwnerId), firestore: TripFirestore());
      await signedInLocal.fetchMedicines();
      expect(hits, isEmpty);
    });

    test('session approval: a Firebase account with uid "local" ends in failed; nothing opens', () async {
      final log = <String>[];
      final auth = StreamController<User?>.broadcast();
      final db = SessionDb();
      final platform = FakeSessionPlatform(log);
      final c = SessionController(
        authStateChanges: auth.stream,
        db: db,
        patients: SpyPatients(log),
        doctor: SpyDoctor(log),
        medicines: SpyMedicines(log),
        platform: platform,
        observeAppLifecycle: false,
      );
      addTearDown(() async {
        c.dispose();
        await auth.close();
      });
      auth.add(FakeUser(kLocalOwnerId));
      for (var i = 0; i < 5; i++) {
        await settle();
        await c.idle;
      }
      expect(c.phase, SessionPhase.failed);
      expect(c.refusedReservedAccount, isTrue);
      expect(c.isReady, isFalse);
      expect(log.where((l) => l.startsWith('approval:')), isEmpty, reason: 'no approval check');
      expect(log.where((l) => l.contains('.load:')), isEmpty, reason: 'no provider loads');
      expect(db.events.where((e) => e.startsWith('open:')), isEmpty, reason: 'the dev DB is never opened');
      // A normal account afterwards still works.
      auth.add(FakeUser('doctorA'));
      for (var i = 0; i < 5; i++) {
        await settle();
        await c.idle;
      }
      expect(c.refusedReservedAccount, isFalse);
      expect(db.events, contains('open:doctorA'));
    });

    test('Firebase platform: approval and cloud ids refuse "local" before any network', () async {
      final platform = FirebaseSessionPlatform(auth: TripAuth(), firestore: TripFirestore(), secureStorage: TripSecure());
      expect(await platform.checkApproval(TripUser(kLocalOwnerId)), ApprovalStatus.notApproved);
      expect(await platform.cloudPatientIds(kLocalOwnerId), isNull);
      expect(hits, isEmpty);
    });
  });

  // ------------------------------------------------------------------ Low
  group('PDF TEST DATA marker', () {
    Future<String> pdfText(bool testData) async {
      final doc = PdfExport.buildPatientReport(
          Patient(id: 'p1', name: 'Asha', age: '30', gender: 'Female', phone: '1',
              history: [visit('v1', [])]),
          testData: testData,
          compress: false);
      return String.fromCharCodes(await doc.save());
    }

    test('dev mode PDFs say TEST DATA; real ones do not', () async {
      // The PDF writes each word as its own text token: (TEST) (DATA) ...
      final dev = await pdfText(true);
      for (final w in PdfExport.testDataMarker.split(' ')) {
        expect(dev, contains('($w)'));
      }
      expect(RegExp(r'\(TEST\)').allMatches(dev).length, greaterThanOrEqualTo(2), reason: 'header and footer');
      expect(await pdfText(false), isNot(contains('(TEST)')));
    }, skip: !kDevMode);

    test('without the define testData: true is ignored (marker compiled out)', () async {
      expect(await pdfText(true), isNot(contains('(TEST)')));
    }, skip: kDevMode);

    test('the PDF button passes DevMode.of(context)', () {
      final src = String.fromCharCodes(File('lib/screens/patient_detail_screen.dart').readAsBytesSync());
      expect(src, contains('generateAndPrintPatientReport(patient, doctor: doctor, testData: DevMode.of(context))'));
    });
  });
}
