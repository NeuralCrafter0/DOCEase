// Regression tests for the fail-closed app lock (SecurityWrapper in
// lib/main.dart). Cases follow QA's BIO-01..BIO-10 drafts.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';

import 'package:docease/main.dart';
import 'package:docease/screens/login_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

const lockTitle = 'DOCEase Secured';
const unlockButton = 'Unlock Dashboard';

class FakeLocalAuth extends LocalAuthPlatform {
  bool deviceSupported = true;
  Object? error;
  bool result = true;
  Completer<bool>? pending;
  int authCalls = 0;
  int supportChecks = 0;
  AuthenticationOptions? lastOptions;

  @override
  Future<bool> isDeviceSupported() async {
    supportChecks++;
    return deviceSupported;
  }

  @override
  Future<bool> deviceSupportsBiometrics() async => deviceSupported;

  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async => const [];

  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    authCalls++;
    lastOptions = options;
    if (pending != null) return pending!.future;
    if (error != null) throw error!;
    return result;
  }
}

late FakeLocalAuth fake;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  // Past the lock the real auth gate builds FirebaseAuth.authStateChanges()
  // (and the login screen's network logo); neither is mocked on the host.
  while (t.takeException() != null) {}
}

Future<void> pumpWrapper(WidgetTester t) async {
  await t.pumpWidget(const MaterialApp(home: SecurityWrapper()));
  await settle(t);
}

/// Whatever sits behind the lock: the auth StreamBuilder or LoginScreen
/// today, or `Consumer<SessionController>` once the session branch lands
/// (matched by name so this file builds on both).
bool protectedSubtreeBuilt() => find
    .byWidgetPredicate(
      (w) => w is StreamBuilder<User?> || w is LoginScreen || w.runtimeType.toString() == 'Consumer<SessionController>',
      skipOffstage: false,
    )
    .evaluate()
    .isNotEmpty;

void expectLocked() {
  expect(find.text(lockTitle), findsOneWidget);
  expect(find.byType(LoginScreen), findsNothing);
}

void background(WidgetTester t) {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void foreground(WidgetTester t) {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  setUp(() {
    fake = FakeLocalAuth();
    LocalAuthPlatform.instance = fake;
  });

  group('fails closed', () {
    testWidgets('BIO-01 LocalAuthException keeps the lock and offers retry', (t) async {
      fake.error = const LocalAuthException(code: LocalAuthExceptionCode.uiUnavailable);
      await pumpWrapper(t);
      expectLocked();
      expect(protectedSubtreeBuilt(), isFalse);
      expect(find.text(unlockButton), findsOneWidget);
    });

    testWidgets('BIO-01 legacy PlatformException(NotAvailable) keeps the lock', (t) async {
      fake.error = PlatformException(code: 'NotAvailable', message: 'sensor error');
      await pumpWrapper(t);
      expectLocked();
      expect(protectedSubtreeBuilt(), isFalse);
      expect(find.text(unlockButton), findsOneWidget);
    });

    for (final code in [LocalAuthExceptionCode.temporaryLockout, LocalAuthExceptionCode.biometricLockout]) {
      testWidgets('BIO-02/03 ${code.name} shows "Try again later" and stays locked', (t) async {
        fake.error = LocalAuthException(code: code);
        await pumpWrapper(t);
        expectLocked();
        expect(find.text('Try again later'), findsOneWidget);
        expect(protectedSubtreeBuilt(), isFalse);
      });
    }

    for (final code in ['LockedOut', 'PermanentlyLockedOut']) {
      testWidgets('BIO-02/03 legacy $code shows "Try again later"', (t) async {
        fake.error = PlatformException(code: code);
        await pumpWrapper(t);
        expectLocked();
        expect(find.text('Try again later'), findsOneWidget);
      });
    }

    testWidgets('BIO-04 any other error keeps the lock', (t) async {
      fake.error = StateError('x');
      await pumpWrapper(t);
      expectLocked();
      expect(protectedSubtreeBuilt(), isFalse);
    });

    testWidgets('BIO-05 unsupported device shows "Set a screen lock" and never prompts', (t) async {
      fake.deviceSupported = false;
      await pumpWrapper(t);
      expectLocked();
      expect(find.text('Set a screen lock to use DOCEase'), findsOneWidget);
      expect(fake.authCalls, 0);
      expect(protectedSubtreeBuilt(), isFalse);
    });

    testWidgets('noCredentialsSet from authenticate shows "Set a screen lock"', (t) async {
      fake.error = const LocalAuthException(code: LocalAuthExceptionCode.noCredentialsSet);
      await pumpWrapper(t);
      expectLocked();
      expect(find.text('Set a screen lock to use DOCEase'), findsOneWidget);
    });

    testWidgets('BIO-07 authenticate() == false keeps the lock', (t) async {
      fake.result = false;
      await pumpWrapper(t);
      expectLocked();
      expect(find.text(unlockButton), findsOneWidget);
      expect(protectedSubtreeBuilt(), isFalse);
    });
  });

  testWidgets('BIO-06 prompts with biometricOnly: false (PIN/pattern fallback)', (t) async {
    await pumpWrapper(t);
    expect(fake.authCalls, 1);
    expect(fake.lastOptions!.biometricOnly, isFalse);
  });

  testWidgets('only a true result unlocks, and nothing behind the lock is built before it', (t) async {
    fake.pending = Completer<bool>();
    await pumpWrapper(t);
    expectLocked();
    expect(protectedSubtreeBuilt(), isFalse, reason: 'unlock must happen before session/account data loads');
    fake.pending!.complete(true);
    await settle(t);
    expect(find.text(lockTitle), findsNothing);
    expect(protectedSubtreeBuilt(), isTrue);
  });

  testWidgets('retry after a failure can unlock', (t) async {
    fake.result = false;
    await pumpWrapper(t);
    fake.result = true;
    await t.tap(find.text(unlockButton));
    await settle(t);
    expect(find.text(lockTitle), findsNothing);
    expect(protectedSubtreeBuilt(), isTrue);
  });

  group('re-lock', () {
    Future<void> unlockAndOpenPatientScreen(WidgetTester t) async {
      await pumpWrapper(t);
      expect(find.text(lockTitle), findsNothing);
      t.state<NavigatorState>(find.byType(Navigator)).push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('PATIENT DATA')))));
      await settle(t);
      expect(find.text('PATIENT DATA'), findsOneWidget);
    }

    testWidgets('BIO-08 re-locks on every resume, covering pushed screens', (t) async {
      await unlockAndOpenPatientScreen(t);
      fake.result = false;
      background(t);
      await settle(t);
      expect(find.text(lockTitle), findsOneWidget, reason: 'locked as soon as the app is backgrounded');
      expect(find.text('PATIENT DATA'), findsNothing);
      foreground(t);
      await settle(t);
      expect(fake.authCalls, 2, reason: 'prompted again immediately on resume');
      expect(find.text(lockTitle), findsOneWidget);
      expect(find.text('PATIENT DATA'), findsNothing);
    });

    testWidgets('unlocking again restores the screen the user was on', (t) async {
      await unlockAndOpenPatientScreen(t);
      background(t);
      foreground(t);
      await settle(t);
      expect(fake.authCalls, 2);
      expect(find.text(lockTitle), findsNothing);
      expect(find.text('PATIENT DATA'), findsOneWidget);
    });

    testWidgets('the lock route cannot be dismissed with back', (t) async {
      await unlockAndOpenPatientScreen(t);
      fake.result = false;
      background(t);
      foreground(t);
      await settle(t);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.text(lockTitle), findsOneWidget);
      expect(find.text('PATIENT DATA'), findsNothing);
    });

    testWidgets('BIO-09 inactive -> resumed only (notification shade) does not re-lock', (t) async {
      await unlockAndOpenPatientScreen(t);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(t);
      expect(fake.authCalls, 1);
      expect(find.text('PATIENT DATA'), findsOneWidget);
    });

    testWidgets('BIO-10 two quick resumes prompt only once', (t) async {
      await unlockAndOpenPatientScreen(t);
      fake.pending = Completer<bool>();
      background(t);
      foreground(t);
      background(t);
      foreground(t);
      await settle(t);
      expect(fake.authCalls, 2, reason: '1 initial + 1 for the re-lock');
      fake.pending!.complete(true);
      await settle(t);
      expect(find.text('PATIENT DATA'), findsOneWidget);
    });

    testWidgets('backgrounding caused by the system PIN screen does not loop', (t) async {
      fake.pending = Completer<bool>();
      await pumpWrapper(t);
      // Device-credential UI is a separate activity: the app pauses and resumes
      // while authenticate() is still pending.
      background(t);
      foreground(t);
      fake.pending!.complete(true);
      await settle(t);
      expect(fake.authCalls, 1);
      expect(find.text(lockTitle), findsNothing);
    });

    testWidgets('"Set a screen lock" re-checks when the user comes back from settings', (t) async {
      fake.deviceSupported = false;
      await pumpWrapper(t);
      expect(find.text('Set a screen lock to use DOCEase'), findsOneWidget);
      fake.deviceSupported = true;
      background(t);
      foreground(t);
      await settle(t);
      expect(find.text(lockTitle), findsNothing);
      expect(protectedSubtreeBuilt(), isTrue);
    });
  });
}
