// DRAFT v9: test/dev_mode/dev_mode_test.dart   (v8 kept in drafts/_superseded/)
//
// v9 rewrites v8 against the real PR #13 API (443a56d) and adds the changes
// backend agreed after security's #13 review (H1, M2, L2):
//   * kDevMode = kDevModeRequested && !kReleaseMode
//   * a release build made with the flag shows a "refused" screen
//   * docs build testers' APKs with --profile
//   * a "dev" flavor with applicationIdSuffix ".dev"
//   * per-owner photo/profile folders ("local" never shares with a real owner)
//   * every cloud path refuses the "local" owner
//   * the Firebase rules commits leave #13 (they stay parked in #2)
//
// Status tags in each test name:
//   [R]  runs and passes on 443a56d today
//   [P]  pending: needs the new backend commits; skipped until they land, then
//        un-skip and re-run (see "When the new commits land" at the bottom)
//   [D]  device/APK only: listed for traceability, run by
//        ci/verify_release_build.sh or by hand (MAN-DEV-*)
//
// Real #13 API used (read from 443a56d):
//   lib/config/dev_mode.dart   kDevMode, kLocalOwnerId = 'local',
//                              kDevModeBannerText = 'DEV MODE: test data only',
//                              DevMode.of(context)
//   lib/dev/dev_mode_app.dart  DevModeHome, devModeBannerBuilder, buildDevModeApp
//   lib/main.dart              DOCEaseApp({ready, devMode})
//   SessionController.localOnly({db, patients, doctor, medicines, observeAppLifecycle})
//   PatientProvider({db, cloudSync, photos, firestore, auth, storage, ...})
//   DoctorProvider({cloudSync, localDb, photos, auth, firestore, storage})
//   MedicineProvider({cloudSync, localDb, auth, firestore})
//   LocalPhotoStore({supportDir}), attachmentsFolder / profileFolder
//   DatabaseHelper.dbFileNameFor(uid) = docease_<sha256(uid)[:32]>.db
//
// v8 cases DEV-02..DEV-10 (banner on every screen, no Firebase, DB opened for
// 'local', no sync, profile and medicines survive restart, settings writes
// leave the counter alone, PDF letterhead from the local profile, Sign Out
// hidden) moved to the functional pass suite
// test/qa_functional/functional_pass_test.dart (F-xx ids), which drives the
// real #13 wiring. v8's assumed bootstrap() seam is dropped.
//
// ASSUMED for the pending commits (rename to match when they land):
//   A1 lib/config/dev_mode.dart exposes `kDevModeRequested` (the raw define)
//      and `kDevMode = kDevModeRequested && !kReleaseMode`.
//   A2 kReleaseMode is const and always false under `flutter test`, so the
//      refusal branch needs a pure seam to be host-testable:
//        enum StartMode { normal, dev, refused }
//        StartMode resolveStartMode({required bool requested, required bool release})
//      plus a widget `DevModeRefusedApp`. If backend keeps the refusal inline
//      in main(), DEV-12/13 become [D] (MAN-DEV-01, REL-08).
//   A3 LocalPhotoStore takes the owner (`LocalPhotoStore(owner: uid, ...)` or
//      `forOwner(uid)`) and stores under
//        <support>/attachments/<sha256(owner)[:32]>/<uuid>.<ext>
//        <support>/profile/<sha256(owner)[:32]>/<uuid>.<ext>
//      (same hashing as dbFileNameFor).
//   A4 Cloud refusal of "local": FirestoreHelper / PatientProvider /
//      DoctorProvider / MedicineProvider return without any Auth, Firestore or
//      Storage call (or throw) when the owner uid is kLocalOwnerId, and
//      SessionController._startSession ends in `failed` for a signed-in user
//      whose uid is 'local'.
//
// Runs in both legs of the CI test matrix (DOCEASE_DEV_MODE=false and =true):
// the dev UI is injected through DOCEaseApp(devMode: true), so only DEV-11b
// depends on the define.

@Tags(['dev-mode'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:docease/config/dev_mode.dart';
import 'package:docease/dev/dev_mode_app.dart';
import 'package:docease/main.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

// Tripwire fakes (TripAuth / TripFirestore / TripStorage / TripHelper record
// every touch in `hits` and throw), LocalSessionDb, localPatients/localDoctor/
// localMedicines come from #13's test/backend/dev_mode_test.dart; move them to
// test/support/dev_tripwires.dart when this lands.
import '../support/dev_tripwires.dart';

String ownerHash(String uid) =>
    sha256.convert(utf8.encode(uid)).toString().substring(0, 32);

void main() {
  late Directory root;
  late Directory support;

  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_dev_v9');
    support = Directory(p.join(root.path, 'support'))..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  // ------------------------------------------------------------ switch (H1)
  group('DEV switch: compile-time, never in release', () {
    String src() => File('lib/config/dev_mode.dart').readAsStringSync();

    test('DEV-11 [P] kDevMode is gated on !kReleaseMode (source)', () {
      expect(src(), contains("bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false)"));
      expect(src(),
          matches(RegExp(r'const bool kDevMode\s*=\s*kDevModeRequested\s*&&\s*!kReleaseMode\s*;')),
          reason: 'H1: a release build must never enter dev mode');
    });

    test('DEV-11b [R] under flutter test, kDevMode follows the define', () {
      expect(kReleaseMode, isFalse);
      expect(kDevMode, const bool.fromEnvironment('DOCEASE_DEV_MODE'));
    });

    test('DEV-12 [P] start-mode table (A2 seam)', () {
      // expect(resolveStartMode(requested: false, release: false), StartMode.normal);
      // expect(resolveStartMode(requested: false, release: true),  StartMode.normal);
      // expect(resolveStartMode(requested: true,  release: false), StartMode.dev);     // debug + profile
      // expect(resolveStartMode(requested: true,  release: true),  StartMode.refused); // never normal, never dev
    });

    testWidgets('DEV-13 [P] refused screen: no Home, banner, lock or login; no Firebase', (t) async {
      // await t.pumpWidget(const DevModeRefusedApp());
      // expect(find.textContaining('Refused'), findsOneWidget);
      // expect(find.byType(DevModeHome), findsNothing);
      // expect(find.text(kDevModeBannerText), findsNothing);
      // expect(find.text('DOCEase Secured'), findsNothing);
      // expect(hits, isEmpty);
    });

    test('DEV-14 [P] main(): refusal checked first, before the dev app and Firebase', () {
      final main = File('lib/main.dart').readAsStringSync();
      final body = main.substring(main.indexOf('main('));
      final refuse = body.indexOf('kReleaseMode');
      expect(refuse, greaterThan(0), reason: 'no release refusal in main()');
      expect(refuse, lessThan(body.indexOf('buildDevModeApp')));
      expect(refuse, lessThan(body.indexOf('Firebase.initializeApp')));
    });

    test('DEV-15 [P] docs build tester APKs with --profile, never --release', () {
      final doc = File('docs/DEV_MODE.md').readAsStringSync();
      final builds = RegExp(r'flutter build (apk|appbundle|ios)[^\n`]*DOCEASE_DEV_MODE=true[^\n`]*')
          .allMatches(doc)
          .map((m) => m.group(0)!)
          .toList();
      expect(builds, isNotEmpty);
      for (final b in builds) {
        expect(b, contains('--profile'), reason: b);
        expect(b, isNot(contains('--release')), reason: b);
      }
      expect(doc.toLowerCase(), contains('refuse'),
          reason: 'docs must say release builds refuse dev mode');
    });
  });

  // ------------------------------------------------------------ dev app ID
  group('DEV flavor: separate app ID', () {
    String gradle() => File('android/app/build.gradle.kts').readAsStringSync();

    test('DEV-16 [P] a "dev" flavor adds applicationIdSuffix ".dev"', () {
      expect(gradle(), contains('applicationId = "com.medhistory.app.medhistory"'));
      expect(gradle(),
          matches(RegExp(r'create\("dev"\)[\s\S]*?applicationIdSuffix\s*=\s*"\.dev"')));
    });

    test('DEV-17 [P] the real flavor keeps the plain app ID (no suffix)', () {
      final prod = RegExp(r'create\("prod"\)\s*\{[^}]*\}').firstMatch(gradle())?.group(0) ?? '';
      expect(prod, isNot(contains('applicationIdSuffix')));
    });

    test('DEV-18 [P] google-services not applied to the dev flavor (L2)', () {
      final devManifest = File('android/app/src/dev/AndroidManifest.xml');
      final conditional = RegExp(r'google-services"\)\s*apply\s*false').hasMatch(gradle());
      final removed = devManifest.existsSync() &&
          devManifest.readAsStringSync().contains('FirebaseInitProvider') &&
          devManifest.readAsStringSync().contains('tools:node="remove"');
      expect(conditional || removed, isTrue);
    }, skip: true /* 'OPEN: security recommends (L2); confirm with backend/DevOps it is in scope' */);

    // DEV-19 [D] dev APK: aapt2 dump badging -> package com.medhistory.app.medhistory.dev (REL-10)
    // DEV-20 [D] release APK: package com.medhistory.app.medhistory, no .dev (REL-11)
    // DEV-21 [D] dev and real installs coexist with separate data (MAN-DEV-03)
  });

  // ------------------------------------------------------------ dev app runs
  testWidgets('DEV-01 [R] DOCEaseApp(devMode: true): Home + banner, no lock, no cloud', (t) async {
    final photos = LocalPhotoStore(supportDir: () async => support);
    await t.runAsync(photos.init);
    final db = LocalSessionDb();
    final patients = localPatients(db, photos);
    final doctor = localDoctor(db, photos);
    final medicines = localMedicines(db);
    final session = SessionController.localOnly(
        db: db, patients: patients, doctor: doctor, medicines: medicines,
        observeAppLifecycle: false);
    await t.runAsync(() => session.idle);
    await t.pumpWidget(MultiProvider(providers: [
      ChangeNotifierProvider<PatientProvider>.value(value: patients),
      ChangeNotifierProvider<DoctorProvider>.value(value: doctor),
      ChangeNotifierProvider<MedicineProvider>.value(value: medicines),
      ChangeNotifierProvider<SessionController>.value(value: session),
    ], child: const DOCEaseApp(ready: true, devMode: true)));
    await t.pump();
    expect(find.byType(DevModeHome), findsOneWidget);
    expect(find.text(kDevModeBannerText), findsOneWidget);
    expect(find.text('DOCEase Secured'), findsNothing);
    expect(hits, isEmpty, reason: 'tripwire: $hits');
    session.dispose();
  }, skip: !kDevMode); // DOCEaseApp.devMode is gated on kDevMode (#13 29f009a)

  // ------------------------------------------------------------ per-owner folders (M2)
  group('DEV per-owner photo folders', () {
    test('DEV-22 [P] "local" photos land under attachments/<hash(local)>/ and profile/<hash(local)>/', () async {
      // final store = LocalPhotoStore(owner: kLocalOwnerId, supportDir: () async => support);
      // await store.init();
      // final visit = await store.keepVisitPhoto(pick('a.jpg'), UploadImageType.jpeg);
      // final avatar = await store.keepAvatar(pick('b.jpg'), UploadImageType.jpeg);
      // expect(p.dirname(visit), p.join(support.path, 'attachments', ownerHash(kLocalOwnerId)));
      // expect(p.dirname(avatar), p.join(support.path, 'profile', ownerHash(kLocalOwnerId)));
      // expect(Directory(p.join(support.path, 'attachments')).listSync().whereType<File>(), isEmpty,
      //     reason: 'nothing directly in the shared attachments/ root');
    });

    test('DEV-23 [P] a real uid gets a different folder; neither can see or delete the other\'s files', () async {
      // dev = LocalPhotoStore(owner: 'local'), real = LocalPhotoStore(owner: <28-char uid>)
      // f = await dev.keepVisitPhoto(...)
      // expect(real.isAppPhoto(f), isFalse); expect(await real.deleteAppPhoto(f), isFalse);
      // expect(File(f).existsSync(), isTrue); and the reverse direction.
    });

    test('DEV-24 [P] path tricks cannot cross owners', () async {
      // '../<hash(other)>/x.jpg', an absolute path into the other owner's folder,
      // and a symlink inside my folder pointing into the other one: all rejected
      // by isAppPhoto/deleteAppPhoto (extends #13's lexical + symlink check).
    });

    test('DEV-25 [P] folder hash = DB file hash for the same owner', () {
      // expect(LocalPhotoStore.folderNameFor('local'), ownerHash('local'));
      // expect(DatabaseHelper.dbFileNameFor('local'), 'docease_${ownerHash('local')}.db');
    });

    test('DEV-26 [P] photos already in the flat folders (from the #13 head or #8)', () async {
      // Decide with backend: moved into the owner folder on first open, or left
      // and still displayable. Either way a real owner must never adopt a
      // flat-folder photo referenced by a 'local' record.
    }, skip: true /* 'OPEN: ask backend how existing flat-folder photos are handled' */);
  });

  // ------------------------------------------------------------ cloud refuses "local" (M2)
  group('DEV cloud paths refuse the "local" owner', () {
    test('DEV-27 [P] cloud-mode PatientProvider with the DB open for "local": zero cloud calls', () async {
      // db = LocalSessionDb()..state = const DbReady(kLocalOwnerId)
      // pp = PatientProvider(db: db, cloudSync: true, firestore: TripHelper(),
      //     auth: TripAuth(), storage: TripStorage(), photos: ...)
      // await pp.addPatient(newPatient('p1')); await pp.loadAndSync();
      // await pp.retryDirty(); await pp.deletePatient('p1');
      // expect(hits, isEmpty);
      // expect(await db.unsyncedCount(), isNot(UnsyncedCount.known(0)), reason: 'refused, not marked synced');
    });

    test('DEV-28 [P] FirestoreHelper refuses uid "local" for sync, delete and fetch', () async {
      // h = FirestoreHelper(firestore: FakeFirestore(), auth: FakeAuth()..signIn('local'))
      // expect(await h.syncPatient(p), isFalse); expect(await h.deletePatient('p1'), isFalse);
      // expect(await h.fetchAllPatients(), isEmpty); no reads/writes on the fake.
    });

    test('DEV-29 [P] Storage: no upload or download-URL call for owner "local"', () async {
      // visit attachments and avatar: FakeStorage.putFile / getDownloadURL never called.
    });

    test('DEV-30 [P] DoctorProvider and MedicineProvider cloud branches refuse "local"', () async {
      // cloudSync: true, owner 'local': saveDoctorProfile, fetchDoctorProfile,
      // load('local'), addMedicineIfNew -> no Firestore get/set.
    });

    test('DEV-31 [P] SessionController: a signed-in user with uid "local" ends in failed', () async {
      // auth stream emits FakeUser('local') -> session.phase == SessionPhase.failed,
      // and the DB never sees openFor('local') from the cloud path.
    });

    test('DEV-32 [R] dev mode itself never touches the cloud', () {
      // Covered on 443a56d by test/backend/dev_mode_test.dart (tripwires) and by
      // the functional pass (hits == [] after every journey). Id kept so the
      // gate table stays complete.
    }, skip: true /* 'pointer only: covered by test/backend/dev_mode_test.dart and F-xx' */);
  });

  test('DEV-33 [P] #13 no longer carries the Firebase rules commits', () {
    // git: `git diff <#10 head>...<#13 head> --stat` lists no firestore.rules,
    // storage.rules or firebase/ test files (MAN-DEV-05). Rules stay parked with #2.
  }, skip: true /* 'git-level check, run by hand on the rebased head' */);
}

// ---------------------------------------------------------------------------
// MANUAL / DEVICE (also in the master draft, section 20)
// MAN-DEV-01 flutter build apk --release --dart-define=DOCEASE_DEV_MODE=true:
//            install, open -> refused screen only (no Home, banner, lock bypass).
// MAN-DEV-02 flutter build apk --profile --flavor dev --dart-define=DOCEASE_DEV_MODE=true:
//            dev mode opens (Home + banner, no lock or login).
// MAN-DEV-03 install the dev APK and a release APK together: two package ids
//            (.dev), separate data; uninstalling one keeps the other's data.
// MAN-DEV-04 flutter build apk --release (no define): normal lock -> login.
// MAN-DEV-05 git check that the rules commits are gone from #13.
// MAN-DEV-06 (L2, if in scope) dev APK behind a proxy: no *.googleapis.com.
//
// When the new commits land, these existing #13 tests encode today's layout
// and need updating, not just re-running:
//   * test/backend/dev_mode_test.dart attachmentsOnDisk() lists the flat
//     <support>/attachments/ folder -> must list the owner-hashed folder.
//   * photo-path assertions in the functional pass (F-PHOTO-*) likewise.
//   * the rules/emulator tests that came with the #2 commits leave with them,
//     so #13's 208-test total will drop; compare by file, not by total.
