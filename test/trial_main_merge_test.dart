// Trial merge #13 (0d720a7) + #4 + #8: QA's two main.dart concerns.
// 1. #8's owner wiring and PickerHygiene hook sit above the
//    kDevBuildRefused / kDevMode early returns, so they apply in every mode.
// 2. The dev home stays inside AppLockHost (the host wraps the MaterialApp
//    whatever its home is).
// Run in both modes:
//   flutter test test/trial_main_merge_test.dart
//   flutter test --dart-define=DOCEASE_DEV_MODE=true test/trial_main_merge_test.dart
import 'dart:io';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/dev/dev_mode_app.dart';
import 'package:docease/main.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/security/app_lock.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'backend/dev_mode_test.dart' as dm;

void main() {
  group('main() order (source)', () {
    final src = File('lib/main.dart').readAsStringSync();
    final body = src.substring(src.indexOf('void main() async {'), src.indexOf('class DOCEaseApp'));
    int at(String s) {
      final i = body.indexOf(s);
      expect(i, greaterThanOrEqualTo(0), reason: 'missing in main(): $s');
      return i;
    }

    test('#8 owner + hygiene hook come before both mode checks', () {
      final refused = at('if (kDevBuildRefused) {');
      final dev = at('if (kDevMode) {');
      for (final line in [
        'AttachmentStorage.currentOwnerId = () => CurrentOwner.id;',
        "StartupHooks.register('picker_hygiene', PickerHygiene.atStartup);",
      ]) {
        expect(at(line), lessThan(refused), reason: line);
        expect(at(line), lessThan(dev), reason: line);
        expect(body.indexOf(line, at(line) + 1), -1, reason: 'registered twice: $line');
      }
      expect(at('WidgetsFlutterBinding.ensureInitialized();'),
          lessThan(at('AttachmentStorage.currentOwnerId')));
    });

    test('no direct PickerHygiene call; both paths run the hooks', () {
      expect(body, isNot(contains('PickerHygiene.atStartup()')));
      expect(RegExp(r'StartupHooks\.runAll\(\);').allMatches(body).length, 2);
    });

    test('DOCEaseApp returns AppLockHost around the MaterialApp for every home', () {
      final build = src.substring(src.indexOf('class DOCEaseApp'), src.indexOf('class SecurityWrapper'));
      expect(build, contains('final app = MaterialApp('));
      expect(build, contains('home: devHome ??'));
      expect(build, contains('return AppLockHost(child: app);'));
      expect(RegExp(r'return\s').allMatches(build).length, 1, reason: 'only one return in build');
    });
  });

  group('dev home inside AppLockHost (dev mode)', () {
    late Directory root;
    late LocalPhotoStore photos;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('docease_trial');
      final support = Directory(p.join(root.path, 'support'))..createSync();
      photos = LocalPhotoStore(supportDir: () async => support);
      await photos.init();
    });
    tearDown(() => root.deleteSync(recursive: true));

    testWidgets('DevModeHome and the banner sit under AppLockHost; lock not engaged', (tester) async {
      final db = dm.LocalSessionDb()..openError = DbOpenException(DbOpenError.keyUnavailable, uid: 'local');
      final session = SessionController.localOnly(
          db: db,
          patients: dm.localPatients(db, photos),
          doctor: dm.localDoctor(db, photos),
          medicines: dm.localMedicines(db),
          observeAppLifecycle: false);
      await tester.runAsync(() => session.idle);
      await tester.pumpWidget(ChangeNotifierProvider<SessionController>.value(
          value: session, child: const DOCEaseApp(ready: true, devMode: true)));
      expect(find.byType(DevModeHome), findsOneWidget);
      expect(find.ancestor(of: find.byType(DevModeHome), matching: find.byType(AppLockHost)), findsOneWidget);
      expect(find.ancestor(of: find.text(kDevModeBannerText), matching: find.byType(AppLockHost)), findsOneWidget);
      expect(find.byType(SecurityWrapper), findsNothing);
      expect(find.text('DOCEase Secured'), findsNothing, reason: 'host stays off: nothing engages it');
      expect(AppLockHost.maybeOf(tester.element(find.byType(DevModeHome))), isNotNull);
      session.dispose();
    });
  }, skip: !kDevMode);

  group('normal mode', () {
    testWidgets('devMode: true is ignored; SecurityWrapper under AppLockHost', (tester) async {
      await tester.pumpWidget(const DOCEaseApp(ready: true, devMode: true));
      await tester.pump();
      expect(find.byType(DevModeHome), findsNothing);
      expect(find.text(kDevModeBannerText), findsNothing);
      // The engaged lock keeps the app offstage behind it, so look offstage too.
      final wrapper = find.byType(SecurityWrapper, skipOffstage: false);
      expect(wrapper, findsOneWidget);
      expect(find.ancestor(of: wrapper, matching: find.byType(AppLockHost, skipOffstage: false)), findsOneWidget);
      expect(find.byType(LockMisconfiguredView, skipOffstage: false), findsNothing);
    });
  }, skip: kDevMode);
}
