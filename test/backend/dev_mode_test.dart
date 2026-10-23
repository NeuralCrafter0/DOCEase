// Dev mode (--dart-define=DOCEASE_DEV_MODE=true): everything works on the
// phone and nothing touches FirebaseAuth, Firestore or Storage. Every test
// sets the mode explicitly (cloudSync: false, DevMode scope, DOCEaseApp
// devMode:), so results are the same with or without the define.
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/config/dev_mode.dart';
import 'package:docease/dev/dev_mode_app.dart';
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/main.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:docease/widgets/avatar_image.dart';
import 'package:docease/widgets/session_status_view.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'fakes.dart';

// ------------------------------------------------------------- tripwires

/// Every Firebase call is recorded and throws, so a call hidden behind a
/// catch block still shows up in [hits].
final hits = <String>[];

class TripAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('auth.${i.memberName}');
    throw StateError('FirebaseAuth touched in dev mode');
  }
}

class TripFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('firestore.${i.memberName}');
    throw StateError('Firestore touched in dev mode');
  }
}

class TripStorage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('storage.${i.memberName}');
    throw StateError('Storage touched in dev mode');
  }
}

class TripHelper extends FakeFirestoreHelper {
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

  @override
  Future<List<Patient>> fetchAllPatients() async {
    hits.add('helper.fetch');
    return [];
  }
}

/// Settings writes can be made to fail.
class SettingsDb extends FakeLocalDatabase {
  SettingsDb() {
    state = const DbReady(kLocalOwnerId);
  }
  bool failPut = false;
  @override
  Future<void> putSetting(String key, String value) async {
    if (failPut) throw StateError('disk full');
    return super.putSetting(key, value);
  }
}

/// Visit writes (updatePatient) can be refused like a full disk.
class VisitDb extends FakeLocalDatabase {
  VisitDb() {
    state = const DbReady(kLocalOwnerId);
  }
  bool failUpdate = false;
  @override
  Future<String?> updatePatient(Patient patient) async {
    if (failUpdate) throw StateError('disk full');
    return super.updatePatient(patient);
  }
}

class LocalSessionDb extends SessionDb {
  @override
  Future<void> putSetting(String key, String value) async => settings[key] = value;
  @override
  Future<String?> getSetting(String key) async => settings[key];
}

PatientProvider localPatients(LocalDatabase db, LocalPhotoStore photos) => PatientProvider(
    db: db,
    cloudSync: false,
    photos: photos,
    firestore: TripHelper(),
    auth: TripAuth(),
    storage: TripStorage(),
    retryBaseDelay: const Duration(milliseconds: 5),
    retryMaxDelay: const Duration(milliseconds: 10));

DoctorProvider localDoctor(LocalDatabase db, LocalPhotoStore photos) => DoctorProvider(
    cloudSync: false, localDb: db, photos: photos,
    auth: TripAuth(), firestore: TripFirestore(), storage: TripStorage());

MedicineProvider localMedicines(LocalDatabase db) =>
    MedicineProvider(cloudSync: false, localDb: db, auth: TripAuth(), firestore: TripFirestore());

Patient newPatient(String id) => Patient(
    id: id, name: 'Test $id', age: '30', gender: 'Female', phone: '+9100000', history: []);

VisitRecord visit(String id, List<String> photos) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 'cough',
    diagnosis: 'cold', prescription: 'rest', attachmentPaths: photos);

/// A minimal valid JPEG (magic bytes are what the validator checks).
List<int> jpeg() => [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 1), 0xFF, 0xD9];

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  late Directory root; // stands in for the phone's storage
  late Directory support; // the app support directory
  late Directory pickerCache; // where image_picker leaves picks
  late LocalPhotoStore photos;

  setUp(() async {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_devmode');
    support = Directory(p.join(root.path, 'support'))..createSync();
    pickerCache = Directory(p.join(root.path, 'cache'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
  });
  tearDown(() => root.deleteSync(recursive: true));

  String pick(String name) {
    final f = File(p.join(pickerCache.path, name))..writeAsBytesSync(jpeg());
    return f.path;
  }

  List<String> attachmentsOnDisk() {
    final d = Directory(photos.visitFolderFor(kLocalOwnerId)!);
    return d.existsSync() ? d.listSync().map((e) => e.path).toList() : [];
  }

  test('the switch defaults to OFF in source and dev data has its own DB owner', () {
    final src = File('lib/config/dev_mode.dart').readAsStringSync();
    expect(src, contains("bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false)"));
    expect(src, contains('kDevModeRequested && !kReleaseMode'));
    expect(kLocalOwnerId, 'local');
  });

  group('session', () {
    late LocalSessionDb db;
    late SessionController session;

    setUp(() {
      db = LocalSessionDb();
      session = SessionController.localOnly(
          db: db,
          patients: localPatients(db, photos),
          doctor: localDoctor(db, photos),
          medicines: localMedicines(db),
          observeAppLifecycle: false);
    });
    tearDown(() => session.dispose());

    test('opens the encrypted DB for "local" straight away; no login, approval or Firebase', () async {
      await session.idle;
      await settle();
      expect(db.events, ['open:local']);
      expect(session.phase, SessionPhase.ready);
      expect(session.uid, kLocalOwnerId);
      expect(session.isLocalOnly, isTrue);
      expect(hits, isEmpty);
    });

    test('sign-out does nothing (there is no account)', () async {
      await session.idle;
      await session.signOut();
      await settle();
      expect(session.phase, SessionPhase.ready);
      expect(db.events, ['open:local']);
      expect(hits, isEmpty);
    });

    test('leaves a legacy plain database alone (it belongs to the real account)', () async {
      session.dispose();
      final legacyDb = LocalSessionDb()..legacy = true;
      session = SessionController.localOnly(
          db: legacyDb,
          patients: localPatients(legacyDb, photos),
          doctor: localDoctor(legacyDb, photos),
          medicines: localMedicines(legacyDb),
          observeAppLifecycle: false);
      await session.idle;
      expect(legacyDb.events, ['open:local']);
      expect(legacyDb.legacy, isTrue);
    });

    test('a failed open can be retried', () async {
      session.dispose();
      final failing = LocalSessionDb()..openError = DbOpenException(DbOpenError.keyUnavailable, uid: 'local');
      session = SessionController.localOnly(
          db: failing,
          patients: localPatients(failing, photos),
          doctor: localDoctor(failing, photos),
          medicines: localMedicines(failing),
          observeAppLifecycle: false);
      await session.idle;
      expect(session.phase, SessionPhase.failed);
      failing.openError = null;
      session.retry();
      await session.idle;
      expect(session.phase, SessionPhase.ready);
    });
  });

  group('patients and visits', () {
    late VisitDb db;
    late PatientProvider patients;

    setUp(() async {
      db = VisitDb();
      patients = localPatients(db, photos);
      await patients.loadAndSync(kLocalOwnerId);
    });
    tearDown(() => patients.dispose());

    test('add patient and visit with a photo: saved locally, photo kept in the app folder, no Firebase', () async {
      await patients.addPatient(newPatient('p1'));
      final picked = pick('IMG_1.jpg');
      await patients.addRecord('p1', visit('v1', [picked]));
      await settle();

      final saved = db.rows['p1']!;
      expect(saved.history.single.diagnosis, 'cold');
      final stored = saved.history.single.attachmentPaths.single;
      expect(stored, isNot(picked));
      expect(photos.isAppPhoto(stored), isTrue);
      expect(File(stored).existsSync(), isTrue);
      expect(patients.isPickedThisSession(stored), isTrue, reason: 'shown from disk');
      expect(db.dirty['p1'], isTrue, reason: 'sync is skipped, not lost');
      expect(await patients.loadAttachmentBytes('patients/local/p1/x.jpg'), isNull);
      final restarted = localPatients(db, photos);
      expect(restarted.isPickedThisSession(stored), isTrue, reason: 'still shown after a restart');
      restarted.dispose();
      expect(hits, isEmpty);
    });

    test('a photo already in the app folder (PR #8 layout) is not copied again', () async {
      await patients.addPatient(newPatient('p1'));
      final inFolder = await photos.keepVisitPhoto(kLocalOwnerId, pick('IMG_2.jpg'), UploadImageType.jpeg);
      await patients.addRecord('p1', visit('v1', [inFolder]));
      expect(db.rows['p1']!.history.single.attachmentPaths, [inFolder]);
      expect(attachmentsOnDisk(), [inFolder]);
    });

    test('edit visit adds a photo and keeps the earlier one', () async {
      await patients.addPatient(newPatient('p1'));
      await patients.addRecord('p1', visit('v1', [pick('a.jpg')]));
      final first = db.rows['p1']!.history.single.attachmentPaths.single;
      await patients.updateRecord('p1', visit('v1', [first, pick('b.jpg')]));
      final paths = db.rows['p1']!.history.single.attachmentPaths;
      expect(paths.first, first);
      expect(photos.isAppPhoto(paths.last), isTrue);
      expect(attachmentsOnDisk().toSet(), paths.toSet());
    });

    test('a refused save deletes only its own new copy; saved photos stay', () async {
      await patients.addPatient(newPatient('p1'));
      await patients.addRecord('p1', visit('v1', [pick('a.jpg')]));
      final savedPhoto = db.rows['p1']!.history.single.attachmentPaths.single;

      db.failUpdate = true;
      await expectLater(patients.addRecord('p1', visit('v2', [pick('b.jpg')])), throwsA(anything));
      await settle();
      expect(attachmentsOnDisk(), [savedPhoto], reason: 'only the unsaved copy is gone');
      expect(File(savedPhoto).existsSync(), isTrue);
    });

    test('deleting a visit or patient never deletes photos here (PR #8 owns that) and calls no cloud', () async {
      await patients.addPatient(newPatient('p1'));
      await patients.addRecord('p1', visit('v1', [pick('a.jpg')]));
      final photo = db.rows['p1']!.history.single.attachmentPaths.single;
      await patients.deleteRecord('p1', 'v1');
      await patients.deletePatient('p1');
      await settle();
      expect(File(photo).existsSync(), isTrue);
      expect(db.tombstones, contains('p1'));
      expect(hits, isEmpty);
    });

    test('reload, retry and search work from the phone only', () async {
      await patients.addPatient(newPatient('p1'));
      await patients.addPatient(newPatient('p2'));
      await patients.retryDirty();
      final again = localPatients(db, photos);
      await again.loadAndSync(kLocalOwnerId);
      expect(again.patients.map((e) => e.id).toSet(), {'p1', 'p2'});
      again.dispose();
      expect(hits, isEmpty);
    });
  });

  group('doctor profile', () {
    late SettingsDb db;
    Doctor profile({String? photo}) => Doctor(
        id: 'ignored', title: 'DR', name: 'Asha', email: 'a@example.com', age: '40',
        mobileNumber: '+911234', specialty: 'GP', clinicName: 'Clinic', practiceMode: 'Solo Practice',
        profileImageUrl: photo);

    setUp(() => db = SettingsDb());

    test('saves to the phone and loads again after a restart', () async {
      final doctor = localDoctor(db, photos);
      await doctor.load(kLocalOwnerId);
      expect(doctor.ownerUid, kLocalOwnerId);
      expect(doctor.accountEmail, isNull);
      expect(await doctor.saveDoctorProfile(profile()), isTrue);
      final stored = jsonDecode(db.settings[DoctorProvider.profileSettingKey]!) as Map;
      expect(stored['id'], kLocalOwnerId);

      final restarted = localDoctor(db, photos);
      await restarted.load(kLocalOwnerId);
      expect(restarted.currentDoctor?.name, 'Asha');
      expect(restarted.currentDoctor?.clinicName, 'Clinic');
      expect(hits, isEmpty);
    });

    test('photo is kept locally; replacing it deletes only the old file', () async {
      final doctor = localDoctor(db, photos);
      await doctor.load(kLocalOwnerId);
      final first = await doctor.uploadProfileImage(File(pick('me.jpg')));
      expect(first, isNotNull);
      expect(photos.isAppPhoto(first!), isTrue);
      await doctor.saveDoctorProfile(profile(photo: first));
      expect(avatarImageFor(first, photos: photos), isA<FileImage>());

      final second = await doctor.uploadProfileImage(File(pick('me2.jpg')));
      await doctor.saveDoctorProfile(profile(photo: second));
      expect(File(first).existsSync(), isFalse);
      expect(File(second!).existsSync(), isTrue);
      expect(doctor.currentDoctor?.profileImageUrl, second);
      expect(hits, isEmpty);
    });

    test('a failed save deletes the new photo copy and keeps the saved one', () async {
      final doctor = localDoctor(db, photos);
      await doctor.load(kLocalOwnerId);
      final first = await doctor.uploadProfileImage(File(pick('me.jpg')));
      await doctor.saveDoctorProfile(profile(photo: first));
      final second = await doctor.uploadProfileImage(File(pick('me2.jpg')));
      db.failPut = true;
      expect(await doctor.saveDoctorProfile(profile(photo: second)), isFalse);
      expect(File(second!).existsSync(), isFalse);
      expect(File(first!).existsSync(), isTrue);
      expect(doctor.currentDoctor?.profileImageUrl, first);
    });
  });

  group('medicines', () {
    test('suggestions are saved on the phone and survive a restart', () async {
      final db = SettingsDb();
      final meds = localMedicines(db);
      await meds.load(kLocalOwnerId);
      await meds.addMedicineIfNew('Paracetamol 500');
      await meds.addMedicineIfNew('Paracetamol 500');
      expect(jsonDecode(db.settings[MedicineProvider.localSettingKey]!), ['Paracetamol 500']);

      final restarted = localMedicines(db);
      await restarted.load(kLocalOwnerId);
      expect(restarted.frequentMedicines, ['Paracetamol 500']);
      expect(hits, isEmpty);
    });
  });

  group('photo folder guard', () {
    test('only files inside the app photo folders count as app photos', () {
      final inside = p.join(photos.visitFolderFor(kLocalOwnerId)!, 'a.jpg');
      expect(photos.isAppPhoto(inside), isTrue);
      expect(photos.isAppPhoto(p.join(photos.supportPath!, 'attachments', '..', '..', 'cache', 'a.jpg')), isFalse);
      expect(photos.isAppPhoto(p.join(photos.supportPath!, 'docease.db')), isFalse);
      expect(photos.isAppPhoto(p.join(pickerCache.path, 'a.jpg')), isFalse);
      expect(photos.isAppPhoto('attachments/a.jpg'), isFalse);
      expect(photos.isAppPhoto('/etc/passwd'), isFalse);
    });

    test('never deletes outside the folders, also through a symlink', () async {
      final outside = File(pick('keep.jpg'));
      expect(await photos.deleteAppPhoto(outside.path, owner: kLocalOwnerId), isFalse);
      final dir = Directory(photos.visitFolderFor(kLocalOwnerId)!)..createSync(recursive: true);
      final link = Link(p.join(dir.path, 'link.jpg'))..createSync(outside.path);
      expect(await photos.deleteAppPhoto(link.path, owner: kLocalOwnerId), isFalse);
      expect(outside.existsSync(), isTrue);
      final db = File(p.join(photos.supportPath!, 'docease.db'))..writeAsStringSync('x');
      expect(await photos.deleteAppPhoto(db.path, owner: kLocalOwnerId), isFalse);
      expect(db.existsSync(), isTrue);
    });

    test('avatar helper: https -> network, app photo -> file, anything else -> none', () {
      expect(avatarImageFor('https://example.com/a.jpg', photos: photos), isA<NetworkImage>());
      expect(avatarImageFor(pick('x.jpg'), photos: photos), isNull, reason: 'outside the app folders');
      expect(avatarImageFor(null, photos: photos), isNull);
    });
  });

  group('ui', () {
    testWidgets('DevMode scope is explicit; without one the compile-time switch applies', (tester) async {
      bool? seen;
      Widget probe() => Builder(builder: (c) {
            seen = DevMode.of(c);
            return const SizedBox();
          });
      await tester.pumpWidget(DevMode(enabled: true, child: probe()));
      expect(seen, isTrue);
      await tester.pumpWidget(DevMode(enabled: false, child: probe()));
      expect(seen, isFalse);
      await tester.pumpWidget(probe());
      expect(seen, kDevMode);
    });

    testWidgets('DOCEaseApp(devMode: true) skips lock and login, shows the banner', (tester) async {
      final db = LocalSessionDb()..openError = DbOpenException(DbOpenError.keyUnavailable, uid: 'local');
      final session = SessionController.localOnly(
          db: db,
          patients: localPatients(db, photos),
          doctor: localDoctor(db, photos),
          medicines: localMedicines(db),
          observeAppLifecycle: false);
      await tester.runAsync(() => session.idle);
      await tester.pumpWidget(ChangeNotifierProvider<SessionController>.value(
          value: session, child: const DOCEaseApp(ready: true, devMode: true)));
      expect(find.byType(DevModeHome), findsOneWidget);
      expect(find.byType(SecurityWrapper), findsNothing);
      expect(find.text('DOCEase Secured'), findsNothing);
      expect(find.text(kDevModeBannerText), findsOneWidget);
      session.dispose();
    });

    testWidgets('DOCEaseApp(devMode: false) keeps the normal path and no banner', (tester) async {
      await tester.pumpWidget(const DOCEaseApp(ready: false, devMode: false));
      expect(find.text('Clinical Cloud Connection Error'), findsOneWidget);
      expect(find.byType(DevModeHome), findsNothing);
      expect(find.text(kDevModeBannerText), findsNothing);
    });

    testWidgets('the banner is shown above the app', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          builder: devModeBannerBuilder, home: Scaffold(body: Text('home'))));
      expect(find.text(kDevModeBannerText), findsOneWidget);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('session screens offer no Sign out in dev mode', (tester) async {
      final db = LocalSessionDb()..openError = DbOpenException(DbOpenError.keyUnavailable, uid: 'local');
      final session = SessionController.localOnly(
          db: db,
          patients: localPatients(db, photos),
          doctor: localDoctor(db, photos),
          medicines: localMedicines(db),
          observeAppLifecycle: false);
      await tester.runAsync(() => session.idle);
      await tester.pumpWidget(MaterialApp(home: SessionStatusView(session: session)));
      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Sign out'), findsNothing);
      session.dispose();
    });
  });

  group('wiring (source checks)', () {
    test('main() returns into dev mode before any Firebase or Google Sign-In call', () {
      final main = File('lib/main.dart').readAsStringSync();
      final dev = main.indexOf('case StartMode.dev:');
      expect(dev, greaterThan(0));
      expect(dev, lessThan(main.indexOf('Firebase.initializeApp')));
      expect(dev, lessThan(main.indexOf('GoogleSignIn.instance')));
      expect(main, contains('devMode\n          ? const DevModeHome()'));
      expect(main, contains('DOCEaseApp(ready: true, devMode: true)'));
      expect(main, contains('const SecurityWrapper()'), reason: 'the lock is kept, only bypassed');
    });

    test('the dev-mode files import no Firebase or Google Sign-In package', () {
      for (final f in ['lib/dev/dev_mode_app.dart', 'lib/dev/dev_build_refused.dart', 'lib/config/dev_mode.dart', 'lib/services/local_photo_store.dart']) {
        final src = File(f).readAsStringSync();
        expect(src, isNot(contains('package:firebase')), reason: f);
        expect(src, isNot(contains('package:cloud_firestore')), reason: f);
        expect(src, isNot(contains('package:google_sign_in')), reason: f);
      }
    });

    test('home screen sign-out (FirebaseAuth) is behind !DevMode.of(context)', () {
      final home = File('lib/screens/home_screen.dart').readAsStringSync();
      final i = home.indexOf('FirebaseAuth.instance.signOut()');
      final line = home.substring(home.lastIndexOf('\n', i) + 1, i);
      expect(line, contains('if (!DevMode.of(context))'));
    });
  });
}
