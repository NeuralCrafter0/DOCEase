// Security's F4-1 PoCs (review_poc/lock_poc_test.dart) with the expectations
// reversed, run against the real DOCEaseApp (lock host above MaterialApp,
// PR #4 241f398) on qa-merged2, plus QA probes for overlays, keyboard focus,
// back/pop while locked, and the app-switcher cover (F4-2).
//
// Locked content is wrapped in Offstage, so the default finders (which skip
// offstage widgets) only find what is actually on screen.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:docease/main.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:provider/provider.dart';

import '../support/dev_tripwires.dart';

const lockTitle = 'DOCEase Secured';

class FakeLocalAuth extends LocalAuthPlatform {
  bool result = true;
  int authCalls = 0;
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
    authCalls++;
    return result;
  }
}

late FakeLocalAuth fake;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  while (t.takeException() != null) {}
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

/// Stand-in for AddRecordScreen._saveRecord: `await save; if (mounted) Navigator.pop(context);`
class SlowSaveScreen extends StatefulWidget {
  final Completer<void> save;
  const SlowSaveScreen(this.save, {super.key});
  @override
  State<SlowSaveScreen> createState() => _SlowSaveScreenState();
}

class _SlowSaveScreenState extends State<SlowSaveScreen> {
  Future<void> _saveRecord() async {
    await widget.save.future;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          const Text('CLINICAL NOTE'),
          const TextField(key: Key('noteField')),
          ElevatedButton(onPressed: _saveRecord, child: const Text('Save')),
        ]),
      );
}

Widget app() {
  final db = LocalSessionDb();
  final photos = LocalPhotoStore(supportDir: () async => Directory.systemTemp.createTempSync('lockpoc'));
  final session = SessionController(
      authStateChanges: Stream.value(null),
      db: db,
      patients: localPatients(db, photos),
      doctor: localDoctor(db, photos),
      medicines: localMedicines(db),
      observeAppLifecycle: false);
  return ChangeNotifierProvider<SessionController>.value(value: session, child: const DOCEaseApp(ready: true));
}

bool visible(String s) => find.text(s).evaluate().isNotEmpty;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());
  setUp(() {
    fake = FakeLocalAuth();
    LocalAuthPlatform.instance = fake;
  });

  late NavigatorState nav;
  Future<Completer<void>> unlockAndOpenNote(WidgetTester t) async {
    await t.pumpWidget(app());
    await settle(t);
    if (visible('Unlock Dashboard')) {
      await t.tap(find.text('Unlock Dashboard'));
      await settle(t);
    }
    expect(find.text(lockTitle), findsNothing, reason: 'precondition: unlocked');
    nav = t.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('PATIENT DATA')))));
    await settle(t);
    final save = Completer<void>();
    nav.push(MaterialPageRoute<void>(builder: (_) => SlowSaveScreen(save)));
    await settle(t);
    return save;
  }

  testWidgets('POC-1r a save that completes while locked does not pop the lock', (t) async {
    final save = await unlockAndOpenNote(t);
    await t.tap(find.text('Save'));
    fake.result = false;
    background(t);
    await settle(t);
    expect(visible(lockTitle), isTrue, reason: 'locked on background');
    foreground(t);
    await settle(t);
    expect(visible(lockTitle), isTrue, reason: 'still locked after failed auth');
    save.complete();
    await settle(t);
    // ignore: avoid_print
    print('POC-1r lockVisible=${visible(lockTitle)} patientDataVisible=${visible('CLINICAL NOTE') || visible('PATIENT DATA')}');
    expect(visible(lockTitle), isTrue);
    expect(visible('CLINICAL NOTE'), isFalse);
    expect(visible('PATIENT DATA'), isFalse);
  });

  testWidgets('POC-2r after a late pop, the next background + failed auth still locks', (t) async {
    final save = await unlockAndOpenNote(t);
    await t.tap(find.text('Save'));
    fake.result = false;
    background(t);
    foreground(t);
    await settle(t);
    save.complete();
    await settle(t);
    background(t);
    foreground(t);
    await settle(t);
    // ignore: avoid_print
    print('POC-2r authCalls=${fake.authCalls} lockVisible=${visible(lockTitle)} patientDataVisible=${visible('PATIENT DATA')}');
    expect(visible(lockTitle), isTrue);
    expect(visible('PATIENT DATA'), isFalse);
    // and a successful auth really unlocks (no stuck lock)
    fake.result = true;
    if (visible('Unlock Dashboard')) await t.tap(find.text('Unlock Dashboard'));
    await settle(t);
    expect(visible(lockTitle), isFalse, reason: 'good auth must unlock');
    expect(visible('PATIENT DATA'), isTrue);
  });

  testWidgets('POC-3r a dialog, bottom sheet, snackbar or overlay entry opened while locked is not shown above the lock', (t) async {
    await unlockAndOpenNote(t);
    final ctx = t.element(find.text('CLINICAL NOTE'));
    fake.result = false;
    background(t);
    foreground(t);
    await settle(t);
    expect(visible(lockTitle), isTrue);
    unawaited(showDialog<void>(context: ctx, builder: (_) => const AlertDialog(content: Text('Delete Rahul Sharma?'))));
    unawaited(showModalBottomSheet<void>(context: ctx, builder: (_) => const Text('Sheet: Rahul Sharma')));
    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Snack: Rahul Sharma')));
    final entry = OverlayEntry(builder: (_) => const Material(child: Text('Overlay: Rahul Sharma')));
    Overlay.of(ctx, rootOverlay: true).insert(entry);
    await settle(t);
    final shown = ['Delete Rahul Sharma?', 'Sheet: Rahul Sharma', 'Snack: Rahul Sharma', 'Overlay: Rahul Sharma'].where(visible).toList();
    // ignore: avoid_print
    print('POC-3r shown over lock: $shown');
    expect(shown, isEmpty);
    // the lock screen is what receives taps
    expect(find.text(lockTitle).hitTestable(), findsOneWidget);
    entry.remove();
  });

  testWidgets('LOCK-FOCUS keyboard focus and key input cannot reach the app while locked', (t) async {
    await unlockAndOpenNote(t);
    await t.tap(find.byKey(const Key('noteField')));
    await settle(t);
    final field = find.byKey(const Key('noteField'));
    final editable = t.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
    expect(editable.focusNode.hasFocus, isTrue, reason: 'precondition: field focused before lock');
    fake.result = false;
    background(t);
    foreground(t);
    await settle(t);
    expect(visible(lockTitle), isTrue);
    expect(editable.focusNode.hasFocus, isFalse, reason: 'the note field kept focus behind the lock');
    final pf = FocusManager.instance.primaryFocus;
    final pfCtx = pf?.context;
    final insideApp = pfCtx != null && find.byType(SlowSaveScreen, skipOffstage: false).evaluate().any((e) {
      var inside = false;
      pfCtx.visitAncestorElements((a) {
        if (a == e) inside = true;
        return !inside;
      });
      return inside;
    });
    expect(insideApp, isFalse, reason: 'primary focus is inside the locked app: $pf');
    // try to programmatically focus and type
    editable.focusNode.requestFocus();
    await settle(t);
    expect(editable.focusNode.hasFocus, isFalse, reason: 'requestFocus() worked behind the lock');
    await t.sendKeyEvent(LogicalKeyboardKey.keyA);
    await settle(t);
    expect(editable.controller.text, isEmpty, reason: 'key input reached the note field behind the lock');
  });

  testWidgets('LOCK-BACK system back / root pop while locked leaves the lock up', (t) async {
    await unlockAndOpenNote(t);
    fake.result = false;
    background(t);
    foreground(t);
    await settle(t);
    expect(visible(lockTitle), isTrue);
    await t.binding.handlePopRoute();
    await settle(t);
    nav.maybePop();
    await settle(t);
    nav.popUntil((r) => r.isFirst);
    await settle(t);
    expect(visible(lockTitle), isTrue, reason: 'back/pop removed the lock');
    expect(visible('PATIENT DATA'), isFalse);
  });

  // F4-2: the app-switcher cover is native (ios/Runner/AppDelegate.swift
  // PrivacyCover), drawn on UIScene.willDeactivate before iOS snapshots, so a
  // Flutter test cannot see it. Source check here; device check is manual
  // (iOS: open a patient, swipe to the app switcher, snapshot shows the cover).
  // By design a transient Flutter `inactive` does not lock (app_lock.dart:30).
  test('LOCK-COVER (F4-2) native app-switcher cover installed; Face ID usage string present', () {
    final d = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(d, contains('UIScene.willDeactivateNotification'));
    expect(d, contains('UIScene.didActivateNotification'));
    expect(d, contains('removeFromSuperview'));
    expect(RegExp(r'PrivacyCover\.shared\.install\(\)').hasMatch(d), isTrue, reason: 'cover never installed');
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(RegExp(r'<key>NSFaceIDUsageDescription</key>\s*<string>[^<]+</string>').hasMatch(plist), isTrue);
  });
}
