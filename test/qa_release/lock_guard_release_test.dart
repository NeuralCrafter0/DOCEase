// REL-LOCK: #4 659a363's misplaced-lock-host guard must hold in RELEASE,
// not just under asserts (user 08:01). flutter test always runs with
// asserts on, so the release check runs this same file on a copy of the
// tree made by tool/qa_release_sim/make_release_sim.py (every assert body
// removed, kDebugMode=false, kReleaseMode=true) with
// --dart-define=QA_RELEASE_SIM=true. A plain run checks debug behaviour.
import 'dart:async';

import 'package:docease/main.dart';
import 'package:docease/security/app_lock.dart';
import 'package:docease/screens/login_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';

const releaseSim = bool.fromEnvironment('QA_RELEASE_SIM');

class _Auth extends LocalAuthPlatform {
  int calls = 0;
  @override
  Future<bool> isDeviceSupported() async => true;
  @override
  Future<bool> deviceSupportsBiometrics() async => true;
  @override
  Future<List<BiometricType>> getEnrolledBiometrics() async => const [];
  @override
  Future<bool> authenticate({
    required String localizedReason,
    required Iterable<AuthMessages> authMessages,
    AuthenticationOptions options = const AuthenticationOptions(),
  }) async {
    calls++;
    return true;
  }
}

bool _protectedBuilt() => find
    .byWidgetPredicate(
        (w) =>
            w is StreamBuilder<User?> ||
            w is LoginScreen ||
            w.runtimeType.toString() == 'Consumer<SessionController>',
        skipOffstage: false)
    .evaluate()
    .isNotEmpty;

Future<List<String>> _pumpCollecting(WidgetTester t, Widget app) async {
  final errors = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (d) => errors.add('${d.exception}');
  try {
    await t.pumpWidget(app);
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  } finally {
    FlutterError.onError = prev;
  }
  while (t.takeException() != null) {}
  return errors;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  late _Auth auth;
  setUp(() => LocalAuthPlatform.instance = auth = _Auth());

  testWidgets(
      'REL-LOCK-01 host inside a route: "App misconfigured", nothing behind '
      'it, no prompt, still nothing after a push (${releaseSim ? 'release sim' : 'debug'})',
      (t) async {
    final nav = GlobalKey<NavigatorState>();
    final errors = await _pumpCollecting(
        t,
        MaterialApp(
            navigatorKey: nav,
            home: const AppLockHost(child: SecurityWrapper())));
    expect(find.textContaining('App misconfigured'), findsOneWidget);
    expect(_protectedBuilt(), isFalse);
    expect(auth.calls, 0);
    nav.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('pushed'))));
    await t.pumpAndSettle();
    expect(_protectedBuilt(), isFalse);
    final reported = errors.any((m) => m.contains('Navigator above it'));
    // Proves which mode really ran: the report lives only inside assert().
    expect(reported, releaseSim ? isFalse : isTrue,
        reason: releaseSim
            ? 'asserts were not stripped: this is not a release simulation'
            : 'debug builds report the misplaced host');
  });

  testWidgets('REL-LOCK-02 control: host above MaterialApp locks normally',
      (t) async {
    final errors = await _pumpCollecting(
        t, const AppLockHost(child: MaterialApp(home: SecurityWrapper())));
    expect(find.textContaining('App misconfigured'), findsNothing);
    expect(errors.where((m) => m.contains('Navigator above it')), isEmpty);
    expect(auth.calls, greaterThanOrEqualTo(1), reason: 'the real lock prompts');
    expect(_protectedBuilt(), isTrue, reason: 'unlocked: protected subtree builds');
  });

  testWidgets('REL-LOCK-03 no host at all: "App misconfigured"', (t) async {
    await _pumpCollecting(t, const MaterialApp(home: SecurityWrapper()));
    expect(find.textContaining('App misconfigured'), findsOneWidget);
    expect(_protectedBuilt(), isFalse);
    expect(auth.calls, 0);
  });
}
