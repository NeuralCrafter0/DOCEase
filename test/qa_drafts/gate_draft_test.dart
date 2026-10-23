// DRAFT v9: test/deployment_gate/default_build_gate_test.dart   (v8 in drafts/_superseded/)
//
// What this gate protects: a build that can reach users (release / tag /
// signed) must lock first, must never enter dev mode, and must keep patient
// data off the keyboard, the logs and plaintext backups.
//
// CI (DevOps, PR #1, agreed):
//   dev job      flutter build apk --profile --flavor dev --dart-define=DOCEASE_DEV_MODE=true
//                (never release-signed)
//   release/tag  flutter build apk|appbundle --release --dart-define=DOCEASE_DEV_MODE=false
//                --obfuscate --split-debug-info=<dir>
//   guard        a signed build with the flag on fails the job
//   tests        `flutter test` in a matrix: DOCEASE_DEV_MODE=false and =true.
//                This file runs in the =false leg AND on every release/tag build:
//                  flutter test --tags deployment-gate --dart-define=DOCEASE_DEV_MODE=false
// Binary checks (refused screen in a release+flag APK, .dev app ID, signing)
// live in ci/verify_release_build.sh (REL-*), because kReleaseMode is always
// false under `flutter test`.
//
// The lock tests from PR #4 (test/security_wrapper_test.dart) also carry
// @Tags(['deployment-gate']). They must never run only under the dev define:
// dev mode skips the lock, so a dev-only run would hide a regression.
//
// Status: [R] runs today, [R-FAIL] runs today and fails (open defect),
// [P] pending a commit (skipped), [D] device/APK only (REL-* / MAN-*).
// Pointer cases that are implemented elsewhere are skipped here with the id
// of the real test, so nothing passes vacuously.
// Sources: security #13 review (H1, M1, M2, L1, L4), frontend PR review
// (F4-*, F7-*, F8-*), user requirement "no patient names in release logs".

@Tags(['deployment-gate'])
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:docease/config/dev_mode.dart';
import 'package:docease/main.dart';
import 'package:docease/screens/home_screen.dart';
import 'package:docease/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docease/dev/dev_mode_app.dart';
import 'package:docease/security/app_lock.dart';
import '../qa_functional/harness.dart' show loadRealFonts;
import 'package:image_picker/image_picker.dart';
import 'package:docease/utils/picker_hygiene.dart';
import 'package:docease/utils/attachment_processor.dart';
import 'package:docease/utils/attachment_storage.dart';
import 'package:path/path.dart' as p;
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:provider/provider.dart';
import '../support/dev_tripwires.dart';

import '../support/lock_fakes.dart'; // installLocalAuth('allow'|'deny'|'throw') over PR #4's LocalAuthPlatform fake

List<(String, String)> libDart() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .map((f) => (f.path, f.readAsStringSync()))
    .toList();

/// v9.1: after unlock SecurityWrapper reads Provider<SessionController>;
/// give it a signed-out session over #13's local fakes (no Firebase).
Widget signedOut(Widget child) {
  final db = LocalSessionDb();
  final photos = LocalPhotoStore(supportDir: () async => Directory.systemTemp.createTempSync('gate'));
  final session = SessionController(
      authStateChanges: Stream.value(null),
      db: db,
      patients: localPatients(db, photos),
      doctor: localDoctor(db, photos),
      medicines: localMedicines(db),
      observeAppLifecycle: false);
  return ChangeNotifierProvider<SessionController>.value(value: session, child: child);
}

// The deployment gate checks the default (no define) build; with the define it skips itself (#13 convention).
void main() => group('[default build, no DOCEASE_DEV_MODE define]', _main, skip: kDevMode);

void _main() {

  // ------------------------------------------------------------ default build boots locked
  group('GATE boot', () {
    testWidgets('GATE-01 [R] lock screen first; Home not built', (t) async {
      installLocalAuth('deny');
      await t.pumpWidget(signedOut(const DOCEaseApp(ready: true)));
      for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 100)); }
      expect(find.text('DOCEase Secured'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('GATE-02 [R] unlock with no user -> Login, not Home', (t) async {
      installLocalAuth('allow');
      await loadRealFonts();
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      // login_screen.dart:144 loads the Google logo from upload.wikimedia.org
      // at runtime (no errorBuilder). Tests get HTTP 400; tolerate only that.
      final prev = FlutterError.onError;
      final logoErrors = <String>[];
      FlutterError.onError = (d) {
        if (d.exception is NetworkImageLoadException) { logoErrors.add(d.exception.toString()); return; }
        // the failed logo's debug error placeholder overflows login_screen.dart:141
        if (logoErrors.isNotEmpty && d.toString().contains('overflowed') && d.toString().contains('login_screen.dart')) { logoErrors.add('overflow'); return; }
        prev?.call(d);
      };
      addTearDown(() => FlutterError.onError = prev);
      await t.pumpWidget(signedOut(const DOCEaseApp(ready: true)));
      for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 100)); }
      if (find.text('Unlock Dashboard').evaluate().isNotEmpty) {
        await t.tap(find.text('Unlock Dashboard'));
      }
      for (var i = 0; i < 10; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('DOCEase Secured'), findsNothing, reason: 'still locked');
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('GATE-03 [R] no dev banner on lock or login', (t) async {
      for (final mode in ['deny', 'allow']) {
        installLocalAuth(mode);
        await t.pumpWidget(signedOut(const DOCEaseApp(ready: true)));
        for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 100)); }
        expect(find.text(kDevModeBannerText), findsNothing, reason: mode);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('GATE-04 [R] DOCEaseApp defaults to devMode false; failed Firebase init shows the error screen', (t) async {
      // v8 assumed a bootstrap() seam; #13's real seam is DOCEaseApp.
      await t.pumpWidget(const DOCEaseApp(ready: false));
      expect(find.text('Clinical Cloud Connection Error'), findsOneWidget);
      expect(find.text(kDevModeBannerText), findsNothing);
      expect(find.byType(HomeScreen), findsNothing);
    });
  });

  // ------------------------------------------------------------ dev switch can't reach release
  group('GATE-05 source guards (lib/ read as text)', () {
    test('GATE-05a [R] exactly one DOCEASE_DEV_MODE read: const, defaultValue false', () {
      final hits = [
        for (final (p, s) in libDart())
          for (final m in RegExp(r"fromEnvironment\('DOCEASE_DEV_MODE'").allMatches(s)) (p, s, m.start)
      ];
      expect(hits, hasLength(1), reason: hits.map((h) => h.$1).join(', '));
      final (_, src, _) = hits.single;
      // v9.1: the declaration may wrap onto the next line.
      expect(src, matches(RegExp(r"const bool \w+\s*=\s*bool\.fromEnvironment\('DOCEASE_DEV_MODE',\s*defaultValue:\s*false\)\s*;")));
    });

    test('GATE-05b [P] kDevMode = kDevModeRequested && !kReleaseMode (H1)', () {
      final src = File('lib/config/dev_mode.dart').readAsStringSync();
      expect(src, matches(RegExp(r'const bool kDevMode\s*=\s*kDevModeRequested\s*&&\s*!kReleaseMode\s*;')));
    });

    test('GATE-05c [P] release + flag -> refusal, checked before any dev or Firebase code in main()', () {
      final main = File('lib/main.dart').readAsStringSync();
      final body = main.substring(main.indexOf('main('));
      // v9.2: #13 0d720a7 branches on compile-time consts so the AOT compiler
      // drops the branch a build can't take (no dev code without the define).
      final refused = body.indexOf('if (kDevBuildRefused)');
      expect(refused, isNot(-1), reason: 'no const refusal branch in main()');
      expect(body.indexOf('decideStartMode('), -1,
          reason: 'a runtime decision keeps dev code in every binary');
      expect(refused, lessThan(body.indexOf('if (kDevMode)')));
      expect(refused, lessThan(body.indexOf('buildDevModeApp')));
      expect(refused, lessThan(body.indexOf('Firebase.initializeApp')));
      final branch = body.substring(refused, body.indexOf('if (kDevMode)'));
      expect(branch, contains('DevBuildRefusedApp'));
      expect(branch, contains('return;'), reason: 'refusal must not fall through to the normal app');
      // the consts make the same decision as decideStartMode
      final m = decideStartMode(requested: kDevModeRequested, release: kReleaseMode);
      expect(kDevBuildRefused, m == StartMode.refused);
      expect(kDevMode, m == StartMode.dev);
      // truth table of the pure decision
      expect(decideStartMode(requested: false, release: false), StartMode.normal);
      expect(decideStartMode(requested: false, release: true), StartMode.normal);
      expect(decideStartMode(requested: true, release: false), StartMode.dev);
      expect(decideStartMode(requested: true, release: true), StartMode.refused);
    });

    test('GATE-05d [R] no runtime way to switch dev mode on', () {
      for (final (p, s) in libDart()) {
        expect(s.contains('Platform.environment'), isFalse, reason: p);
        expect(RegExp(r"(String|int)\.fromEnvironment\('DOCEASE").hasMatch(s), isFalse, reason: p);
        expect(RegExp(r'\bkDevMode\s*=(?!=)').allMatches(s).length,
            p.endsWith('config/dev_mode.dart') ? 1 : 0, reason: '$p assigns kDevMode');
      }
    });

    test('GATE-05e [R] the banner is only drawn from dev-mode code', () {
      for (final (p, s) in libDart()) {
        if (!s.contains('kDevModeBannerText')) continue;
        expect(p.contains('/dev/') || p.endsWith('config/dev_mode.dart'), isTrue,
            reason: '$p shows the dev banner outside lib/dev/');
      }
    });

    test('GATE-05f [P] cloud entry points refuse the "local" owner (M2)', () {
      // Source backstop for DEV-27..31 (behaviour is tested in dev_mode_test).
      for (final f in [
        'lib/providers/firestore_helper.dart',
        'lib/providers/patient_provider.dart',
        'lib/providers/doctor_provider.dart',
        'lib/providers/medicine_provider.dart',
        'lib/services/session_controller.dart',
      ]) {
        expect(File(f).readAsStringSync(), anyOf(contains('kLocalOwnerId'), contains('isLocalOwner(')), reason: f);
      }
    });
    testWidgets('GATE-05h [R] DOCEaseApp(devMode: true) in a non-dev build still shows the lock (F4-R3)', (t) async {
      installLocalAuth('deny');
      final prev = FlutterError.onError;
      final errors = <Object>[];
      FlutterError.onError = (d) => errors.add(d.exception);
      try {
        await t.pumpWidget(signedOut(const DOCEaseApp(ready: true, devMode: true)));
        for (var i = 0; i < 5; i++) { await t.pump(const Duration(milliseconds: 100)); }
      } catch (e) { errors.add(e); } finally { FlutterError.onError = prev; }
      expect(find.byType(DevModeHome), findsNothing, reason: 'devMode: true replaced the lock with DevModeHome while kDevMode is false');
      expect(find.text('DOCEase Secured'), findsOneWidget, reason: 'lock not shown; errors=$errors');
    });
    test('GATE-05i [R] no-flavor `flutter build apk --release` must not produce a devRelease APK (DevOps)', () {
      // `flutter build apk --release` with no --flavor runs :app:assembleRelease,
      // which builds every flavor's release variant, incl. the .dev
      // "DOCEase DEV" APK signed with the release config. Accept: devRelease is
      // disabled (beforeVariants/enable=false), or the task-graph guard refuses
      // any scheduled *DevRelease task.
      final kts = File('android/app/build.gradle.kts').readAsStringSync();
      final disabled = RegExp(r'beforeVariants[\s\S]{0,400}(dev|Dev)[\s\S]{0,200}(release|Release)[\s\S]{0,200}enable\s*=\s*false').hasMatch(kts) ||
          RegExp(r'beforeVariants[\s\S]{0,400}(release|Release)[\s\S]{0,200}(dev|Dev)[\s\S]{0,200}enable\s*=\s*false').hasMatch(kts);
      var graphGuard = false;
      final i = kts.indexOf('taskGraph.whenReady');
      if (i >= 0) {
        final block = kts.substring(i, kts.indexOf('\n}', i) + 2);
        graphGuard = block.contains('DevRelease') && block.contains('GradleException');
      }
      // what today's start-task guard does with the no-flavor command
      final start = ['assembleRelease'];
      final startRefuses = start.any((t) => t.contains('DevRelease')) || start.any((t) => t.contains('Dev'));
      expect(startRefuses, isFalse, reason: 'sanity: start-task names cannot see the devRelease variant');
      expect(disabled || graphGuard, isTrue,
          reason: 'assembleRelease would build devRelease: no beforeVariants disable and no task-graph *DevRelease refusal');
    });
    test('GATE-05g [R] Gradle dev guard is evaluated on the task graph and refuses the raw-task bypasses (security, #13)', () {
      // A raw `./gradlew :app:packageProdProfile -Pdart-defines=<DOCEASE_DEV_MODE=true>`
      // has no assemble/bundle/install start task, so a start-parameter guard
      // never runs. Security asked for compileFlutterBuild<Variant> in
      // taskGraph.whenReady; #13 4fd5d14 instead keys on the scheduled
      // package|bundle|assemble|install<Variant> tasks plus any *DevRelease task
      // (reason in build.gradle.kts: shared configureCMake tasks pull in other
      // flavors' Dart compiles). This test simulates that guard on the bypass
      // task graphs. Real-build proof: ci REL-GRADLE-01/02 (not run here).
      final kts = File('android/app/build.gradle.kts').readAsStringSync();
      final i = kts.indexOf('taskGraph.whenReady');
      expect(i, greaterThan(0), reason: 'guard is not evaluated on the task graph');
      final block = kts.substring(i, kts.indexOf('\n}', i) + 2);
      expect(block, contains('allTasks'), reason: 'guard does not look at scheduled tasks');
      expect(block, contains('GradleException'));
      final rx = RegExp(r'val docEaseOutputTask = Regex\("([^"]+)"\)').firstMatch(kts);
      expect(rx, isNotNull, reason: 'output-task regex not found');
      final out = RegExp(rx!.group(1)!.replaceAll(r'\\', '\\'));
      final devRelRefused = block.contains('it.name.contains("DevRelease")');
      String? guard(List<String> tasks, bool define) {
        if (devRelRefused && tasks.any((t) => t.contains('DevRelease'))) return 'devRelease';
        for (final v in tasks.map((t) => out.firstMatch(t)?.group(2)).whereType<String>().toSet()) {
          final dev = v.startsWith('Dev');
          if (dev && v.endsWith('Release')) return 'devRelease';
          if (define && !dev) return 'define in prod';
          if (!define && dev) return 'dev without define';
        }
        return null;
      }
      // raw package task + define, as security's probe
      expect(guard(['compileFlutterBuildProdProfile', 'packageProdProfile'], true), isNotNull, reason: 'packageProdProfile + define not refused');
      expect(guard(['compileFlutterBuildProdRelease', 'packageProdRelease'], true), isNotNull, reason: 'packageProdRelease + define not refused');
      expect(guard(['bundleProdRelease'], true), isNotNull);
      expect(guard(['installProdDebug'], true), isNotNull);
      // a dev compile/sign task scheduled on its own
      expect(guard(['compileFlutterBuildDevRelease'], false), isNotNull, reason: 'stand-alone DevRelease task not refused');
      // legitimate builds pass
      expect(guard(['compileFlutterBuildProdRelease', 'packageProdRelease', 'assembleProdRelease'], false), isNull);
      expect(guard(['compileFlutterBuildDevDebug', 'packageDevDebug', 'assembleDevDebug'], true), isNull);
      // GAP (by design, documented): a raw compileFlutterBuildProdProfile alone
      // with the define is not refused, but it packages nothing.
      expect(guard(['compileFlutterBuildProdProfile'], true), isNull);
    });
  });

  // ------------------------------------------------------------ #4 lock (F4-*)
  group('GATE-06 the lock cannot be removed or drawn over (#4)', () {
    // Security's POC-1..3 (review_poc/lock_poc_test.dart) with the
    // expectations reversed. Port the POC bodies verbatim; they use #4's own
    // LocalAuthPlatform fake. Expected to FAIL on the #4 head until F4-1 is fixed.
    testWidgets('GATE-06a [R, fixed by #4 241f398] save-then-pop under the re-lock keeps the lock (POC-1)', (t) async {
      // unlock -> open AddRecordScreen -> tap Save with addRecord delayed ->
      // paused/resumed -> auth fails -> let the save finish.
      // expect(find.text('DOCEase Secured'), findsOneWidget);
      // expect(find.text(<patient name>), findsNothing);
    }, skip: true /* 'ported: test/qa_lock/lock_poc_reversed_test.dart POC-1r (passes on 99b75b4)' */);
    testWidgets('GATE-06b [R, fixed by #4 241f398] after 06a the next background re-locks again (POC-2)', (t) async {
      // second paused/resumed + failed auth: lock visible; authCalls == 3.
    }, skip: true /* 'ported: qa_lock POC-2r (passes on 99b75b4)' */);
    testWidgets('GATE-06c [R, fixed by #4 241f398] a dialog opened while locked is not drawn above the lock (POC-3)', (t) async {
      // showDialog from an async callback while locked: lock stays top-most.
    }, skip: true /* 'ported: qa_lock POC-3r + LOCK-FOCUS + LOCK-BACK (pass on 99b75b4)' */);
    testWidgets('GATE-06d [P] lifecycle inactive -> privacy cover over the dashboard (F4-2, iOS snapshot)', (t) async {
      // handleAppLifecycleStateChanged(inactive) -> cover visible, patient text
      // offstage; resumed while unlocked -> cover removed.
    }, skip: true /* 'cover is native iOS (AppDelegate PrivacyCover): source check qa_lock LOCK-COVER + MAN-LOCK-01' */);
    testWidgets('GATE-06f [R] fallback lock fails hard: no degraded lock below the navigator (F4-R1)', (t) async {
      // With no AppLockHost above MaterialApp, SecurityWrapper must not wrap
      // itself in a lock inside the home route (pushed routes draw above it).
      // Accept: an assertion in debug, or a full-screen misconfigured view with
      // no SecurityWrapper session subtree.
      installLocalAuth('allow');
      final errors = <Object>[];
      final prev = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exception);
      try {
        await t.pumpWidget(signedOut(const MaterialApp(home: SecurityWrapper())));
        for (var i = 0; i < 5; i++) { await t.pump(const Duration(milliseconds: 100)); }
      } catch (e) { errors.add(e); } finally { FlutterError.onError = prev; }
      final failedHard = errors.any((e) => e is AssertionError) ||
          find.textContaining('misconfigured').evaluate().isNotEmpty;
      final degraded = find.descendant(of: find.byType(MaterialApp), matching: find.byType(AppLockHost)).evaluate().isNotEmpty;
      expect(failedHard, isTrue, reason: 'no assert and no "App misconfigured" view; errors=$errors');
      expect(degraded, isFalse, reason: 'SecurityWrapper built a fallback AppLockHost inside the home route');
    });
    testWidgets('GATE-06e [P] no provider fetch or sync while locked (F4-3, optional)', (t) async {},
        skip: true /* 'OPEN: frontend to say whether F4-3 is taken' */);
    // MAN-LOCK-01 iPhone: open a patient, swipe to the app switcher -> the thumbnail shows the cover.
    // MAN-LOCK-02 Face ID device: NSFaceIDUsageDescription present, Face ID prompt shown (F4-4).
  });

  // ------------------------------------------------------------ #7 keyboard and logs (F7-*)
  group('GATE-07 clinical text stays off the keyboard and out of logs (#7)', () {
    testWidgets('GATE-07a every TextField in AddRecordScreen: autocorrect + suggestions off (F7-1)', (t) async {},
        skip: true /* 'implemented and run as F-PRIV-01 in test/qa_functional/functional_pass_test.dart; '
            'move here when the functional harness moves to test/support' */);

    test('GATE-07b [R] no print/debugPrint in lib/ interpolates a name, clinical field or raw error (F7-2, L4: all of lib/)', () {
      final bad = RegExp(
          r'''(debugPrint|print)\([^;]*(\$\{?(e|error|err|st|stack|stackTrace)\b(?!\.runtimeType|\.code\b)|patient\.(name|phone|history)|\.name\b|\$\{?(name|phone|diagnosis|symptoms|prescription)\b)''');
      final offenders = [
        for (final (p, s) in libDart())
          for (final (i, l) in s.split('\n').indexed)
            // StartupHooks logs its own hook key (e.g. 'picker_hygiene') + an error code
            if (bad.hasMatch(l) && !(p.endsWith('services/startup_hooks.dart') && l.contains("hook \$name failed (\${errorCode(e)})")))
              '$p:${i + 1}: ${l.trim()}'
      ];
      expect(offenders, isEmpty, reason: offenders.join('\n'));
    });

    test('GATE-07c runtime: the patient journeys log nothing that contains patient data', () {},
        skip: true /* 'implemented and run as F-LOG-01 in the functional pass' */);

    test('GATE-07d [P] remaining diagnostics are silent in release (kDebugMode)', () {
      // Every debugPrint in lib/ sits inside `if (kDebugMode)` or goes through a
      // log() helper that checks kDebugMode.
    }, skip: true /* 'OPEN: backend to pick `if (kDebugMode)` vs a log() helper' */);

    // MAN-LOG-01 flutter run --release; adb logcat while saving, editing,
    //            exporting a patient: the name never appears.
    // F7-3 (share sheet starts with every field ticked) is a product decision,
    //      tracked as F-SHARE-03 in the functional pass, not a gate.
  });

  // ------------------------------------------------------------ #8 photos (F8-*)
  group('GATE-08 patient photos (#8)', () {
    test('GATE-08a [R] no photo code writes to Documents (F8-1)', () {
      final offenders = [
        for (final (p, s) in libDart())
          if (s.contains('getApplicationDocumentsDirectory')) p
      ];
      expect(offenders, isEmpty, reason: offenders.join(', '));
    });
    test('GATE-08b [R] attachments/ folder excluded from backup (F8-1; #8 31cf312)', () async {
      final base = Directory.systemTemp.createTempSync('g08b');
      final excluded = <String>[];
      AttachmentStorage.resetExclusionCache();
      final dir = await AttachmentStorage(ownerId: 'uidA', baseDirectory: () async => base, excludeFromBackup: (d) async => excluded.add(d)).directory();
      expect(excluded, hasLength(1));
      expect(p.isWithin(excluded.single, dir.path), isTrue, reason: '${excluded.single} does not contain ${dir.path}');
      expect(p.basename(excluded.single), 'attachments');
      expect(dir.path, isNot(contains('uidA')), reason: 'owner uid on disk');
      base.deleteSync(recursive: true);
    });
    test('GATE-08b2 [P] iOS: profile/ (avatar) folder excluded from backup (#13 L1)', () {
    }, skip: true /* 'pending L1: LocalPhotoStore profile folder exclusion not verified on this merge' */);
    test('GATE-08c [P] local copy deleted after a confirmed upload and on record/patient delete (F8-1)', () {},
        skip: true /* 'cloud path parked; un-skip when Firebase work resumes' */);
    test('GATE-08d [R] picker original deleted only if under a temp root (F8-2)', () async {
      final tmp = Directory.systemTemp.createTempSync('g08d_tmp');
      final keep = Directory.systemTemp.createTempSync('g08d_keep');
      final h = PickerHygiene(temporaryRoots: () async => [tmp]);
      final inTmp = File('${tmp.path}/image_picker_1.jpg')..writeAsBytesSync([1]);
      final outside = File('${keep.path}/photo.jpg')..writeAsBytesSync([1]);
      expect(await h.discardPickedSource(inTmp.path), isTrue);
      expect(inTmp.existsSync(), isFalse);
      expect(await h.discardPickedSource(outside.path), isFalse);
      expect(outside.existsSync(), isTrue, reason: 'deleted a file outside the temp roots');
      tmp.deleteSync(recursive: true);
      keep.deleteSync(recursive: true);
    });
    test('GATE-08e [R] output over the cap rejected; >100 MP input rejected before decode (F8-4, F8-5)', () async {
      expect(AttachmentProcessor.defaultMaxOutputBytes, 10 * 1024 * 1024);
      expect(AttachmentProcessor.maxPixels, 100 * 1000 * 1000);
      final out = Directory.systemTemp.createTempSync('g08e');
      final huge = AttachmentProcessor(outputDirectory: () async => out, discardSource: (_) async {});
      final sw = Stopwatch()..start();
      await expectLater(huge.toJpegFile(XFile('test/fixtures/attachments/huge_dimensions.png')),
          throwsA(isA<AttachmentException>().having((e) => e.error, 'error', AttachmentError.tooLarge)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)), reason: 'decoded before refusing');
      final tiny = AttachmentProcessor(outputDirectory: () async => out, maxOutputBytes: 64, discardSource: (_) async {});
      await expectLater(tiny.toJpegFile(XFile('test/fixtures/attachments/noise.png')),
          throwsA(isA<AttachmentException>().having((e) => e.error, 'error', AttachmentError.tooLarge)));
      expect(out.listSync(), isEmpty, reason: 'a refused photo left a file');
      out.deleteSync(recursive: true);
    });
    // F8-3 (contentType; no device path stored after a failed upload) is in
    // master-draft sections 4b and 13 (cloud, parked).
  });

  // ------------------------------------------------------------ binary checks (ci/verify_release_build.sh)
  // GATE-09 [D] release APK built WITH the flag shows only the refused screen -> REL-08 + MAN-DEV-01
  // GATE-10 [D] profile APK with the flag opens dev mode -> REL-07c + MAN-DEV-02
  // GATE-11 [D] dev APK id ends in .dev; release id does not -> REL-10 / REL-11
  // GATE-12 [D] a signed build with the flag fails CI -> REL-W9 negative control
}
