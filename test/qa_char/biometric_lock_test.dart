// FLIPPED (was CHARACTERIZATION on main) of SecurityWrapper (lib/main.dart L102-117).
// "DEFECT" tests pass while the lock fails open; expected to FAIL after the
// fail-closed fix (then use the regression cases in /workspace/qa/drafts).
// ignore_for_file: depend_on_referenced_packages
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docease/main.dart';
import 'dart:io';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:provider/provider.dart';
import '../support/dev_tripwires.dart';
import '../support/lock_fakes.dart'; // LocalAuthPlatform fake (#4 uses the platform instance, not the old channel)

const lockText = 'DOCEase Secured';

Future<void> pumpWrapper(WidgetTester tester) async {
  // The real app as main() builds it: DOCEaseApp puts AppLockHost above
  // MaterialApp (#4 16968d7: a bare SecurityWrapper now shows 'App
  // misconfigured'), under a signed-out SessionController so the protected
  // subtree is the real LoginScreen.
  final db = LocalSessionDb();
  final photos = LocalPhotoStore(supportDir: () async => Directory.systemTemp.createTempSync('qachar'));
  final session = SessionController(
      authStateChanges: Stream.value(null),
      db: db,
      patients: localPatients(db, photos),
      doctor: localDoctor(db, photos),
      medicines: localMedicines(db),
      observeAppLifecycle: false);
  await tester.pumpWidget(ChangeNotifierProvider<SessionController>.value(value: session, child: const DOCEaseApp(ready: true)));
  // Real async so the session reaches signedOut (as in GATE-02).
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  tester.takeException();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  testWidgets('control: supported device + failed auth keeps the lock screen',
      (tester) async {
    installLocalAuth('deny');
    await pumpWrapper(tester);
    expect(find.text(lockText), findsOneWidget);
    expect(find.text('Unlock Dashboard'), findsOneWidget);
  });

  testWidgets('FIXED: local_auth throws (e.g. NotAvailable/LockedOut) -> lock stays',
      (tester) async {
    installLocalAuth('throw');
    await pumpWrapper(tester);
    expect(find.text('Continue with Google'), findsNothing,
        reason: 'local_auth error must not open the protected subtree');
  });

  testWidgets('FIXED: no biometrics and no device lock -> lock stays',
      (tester) async {
    installLocalAuth('unsupported');
    await pumpWrapper(tester);
    expect(find.text('Continue with Google'), findsNothing,
        reason: 'no device auth must not open the protected subtree');
  });

  testWidgets('FIXED: resume after <60s in background re-locks',
      (tester) async {
    installLocalAuth('allow');
    await pumpWrapper(tester);
    expect(find.text(lockText), findsNothing);
    expect(find.text('Continue with Google'), findsOneWidget,
        reason: 'positive control: unlocked, the protected subtree is visible');
    installLocalAuth('deny'); // any new prompt would now fail
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    tester.takeException();
    expect(find.text('Continue with Google'), findsNothing,
        reason: '#4 re-locks on every hidden/paused, regardless of time');
  });
}
