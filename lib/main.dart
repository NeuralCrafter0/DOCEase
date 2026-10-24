import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'providers/patient_provider.dart';
import 'providers/doctor_provider.dart';
import 'utils/picker_hygiene.dart';
import 'providers/medicine_provider.dart';
import 'providers/database_helper.dart';
import 'providers/firestore_settings.dart';
import 'config/dev_mode.dart';
import 'dev/dev_build_refused.dart';
import 'dev/dev_mode_app.dart';
import 'services/log_codes.dart';
import 'services/session_controller.dart';
import 'services/photo_sweep.dart';
import 'services/startup_hooks.dart';
import 'utils/attachment_storage.dart';
import 'services/current_owner.dart';
import 'widgets/session_status_view.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'security/app_lock.dart';
import 'theme/app_theme.dart';
import 'ui/session_route_reset.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Features register StartupHooks here (before the start-mode checks) so
  // they run in dev and normal mode alike; see services/startup_hooks.dart.
  // The photo sweep waits for the first open DB and sweeps only that owner.
  StartupHooks.register(PhotoSweep.hookName, PhotoSweep.startupHook);

  // #8 merge wiring (QA merge, per frontend): photo storage follows #13's
  // CurrentOwner (the Google uid, or the local owner in dev mode), and the
  // picker clean-up runs on both start paths (security re-review F8-R2, F8-R6).
  AttachmentStorage.currentOwnerId = () => CurrentOwner.id;
  StartupHooks.register('picker_hygiene', PickerHygiene.atStartup);
  // Both checks are compile-time constants (same decision as
  // decideStartMode), so the AOT compiler removes the branch a build can't
  // take: without the define there is no dev-mode code in the binary.
  if (kDevBuildRefused) {
    // Release build made with the dev define: refuse loudly, never fall
    // through to dev mode or silently to the normal app.
    runApp(const DevBuildRefusedApp());
    return;
  }
  if (kDevMode) {
    // Dev mode: no Firebase, Google Sign-In, login or lock (dev_mode.dart).
    runApp(await buildDevModeApp(const DOCEaseApp(ready: true, devMode: true)));
    StartupHooks.runAll();
    return;
  }

  bool firebaseReady = false;
  try {
    await Firebase.initializeApp();
    configureFirestoreForEncryptedLocalStore();
    await GoogleSignIn.instance.initialize(
      serverClientId: '1014476645992-6s886d3l0h84lb277ghfq571gkg6bfi9.apps.googleusercontent.com',
    );
    firebaseReady = true;
  } catch (e) {
    debugPrint('Init Error: ${errorCode(e)}');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (ctx) => PatientProvider()),
        ChangeNotifierProvider(create: (ctx) => DoctorProvider()),
        ChangeNotifierProvider(create: (ctx) => MedicineProvider()),
        // Created on first read (after unlock), so no session work starts
        // before the lock screen is passed.
        ChangeNotifierProvider(
          create: (ctx) => SessionController(
            patients: ctx.read<PatientProvider>(),
            doctor: ctx.read<DoctorProvider>(),
            medicines: ctx.read<MedicineProvider>(),
          ),
        ),
      ],
      child: DOCEaseApp(ready: firebaseReady),
    ),
  );
  StartupHooks.runAll();
}

class DOCEaseApp extends StatefulWidget {
  final bool ready;
  /// Dev mode as requested by main(). Only takes effect when [kDevMode] is
  /// true: in a build without the define it is ignored (see [isDevMode]).
  final bool devMode;

  /// The effective value: `kDevMode && devMode` (const first, so it folds).
  bool get isDevMode => kDevMode && devMode;
  const DOCEaseApp({super.key, required this.ready, this.devMode = false});
  @override
  State<DOCEaseApp> createState() => _DOCEaseAppState();
}

class _DOCEaseAppState extends State<DOCEaseApp> {
  // Root navigator, so a session end or owner change can close every
  // pushed screen, sheet and dialog (SessionRouteReset, security S2).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  bool get ready => widget.ready;
  bool get devMode => widget.devMode;

  @override
  Widget build(BuildContext context) {
    // Directly under the const kDevMode, so builds without the define
    // contain neither DevModeHome nor the banner.
    Widget? devHome;
    TransitionBuilder? devBanner;
    if (kDevMode) {
      if (devMode) {
        devHome = const DevModeHome(); // bypasses SecurityWrapper (lock) and login
        devBanner = devModeBannerBuilder;
      }
    }
    final app = MaterialApp(
      title: 'DOCEase',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      // Dark theme is built but held back until every screen is on the
      // new tokens (M2); then this becomes ThemeMode.system. Nothing is
      // stored either way.
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.light,
      // The route reset sits under the dev banner, which is chained, not
      // replaced (S8).
      builder: (ctx, child) {
        final guarded = SessionRouteReset(navigatorKey: _navigatorKey, child: child ?? const SizedBox.shrink());
        return devBanner == null ? guarded : devBanner(ctx, guarded);
      },
      home: devHome ??
          (!ready 
          ? const Scaffold(body: Center(child: Text('Clinical Cloud Connection Error')))
          : const SecurityWrapper()),
    );
    // The app lock is drawn above the MaterialApp, and so above its navigator:
    // no route, dialog or Navigator.pop from app code can remove it or draw
    // over it. It stays off until SecurityWrapper switches it on.
    return AppLockHost(child: app);
  }
}

/// The protected part of the app: the auth gate and everything behind it.
///
/// The lock itself is [AppLockHost] (lib/security/app_lock.dart), which
/// DOCEaseApp places above the MaterialApp. This widget switches the lock on
/// and builds nothing behind it until the first successful unlock, so no
/// session or account data loads before then.
///
/// Built without a host above it, it fails hard: an assertion in debug and,
/// in every build mode, a full-screen "App misconfigured" view with nothing
/// protected behind it. It never runs a weaker lock below the navigator,
/// where pushed routes would draw above it (security re-review F4-R1).
class SecurityWrapper extends StatefulWidget {
  const SecurityWrapper({super.key});

  @override
  State<SecurityWrapper> createState() => _SecurityWrapperState();
}

class _SecurityWrapperState extends State<SecurityWrapper> {
  AppLockController? _lock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _lock = AppLockHost.maybeOf(context);
    _lock?.engage();
  }

  bool get _hasUnlockedOnce => _lock?.hasUnlockedOnce ?? false;

  /// Blank stand-in; the lock screen itself is drawn by the host above.
  Widget _buildLockScreen() => const ColoredBox(color: Color(0xFF1E293B));

  @override
  Widget build(BuildContext context) {
    // Before the first successful unlock nothing behind the lock is built, so
    // no session or account data can load. Later re-locks hide this subtree
    // without rebuilding it (see AppLockHost).
    if (_lock == null) {
      assert(() {
        FlutterError.reportError(FlutterErrorDetails(
          exception: AssertionError(
              'SecurityWrapper needs an AppLockHost above the MaterialApp (DOCEaseApp provides it).'),
          library: 'docease app lock',
        ));
        return true;
      }());
      return const LockMisconfiguredView();
    }
    if (!_hasUnlockedOnce) return _buildLockScreen();

    // The session (auth, approval, local DB) sits below the unlock screen.
    return Consumer<SessionController>(
      builder: (ctx, session, _) => switch (session.phase) {
        SessionPhase.ready => const HomeScreen(),
        SessionPhase.signedOut => const LoginScreen(),
        _ => SessionStatusView(session: session),
      },
    );
  }
}

/// Shown instead of the app when [SecurityWrapper] has no [AppLockHost]
/// above it. Builds nothing protected, so there is nothing to bypass.
class LockMisconfiguredView extends StatelessWidget {
  const LockMisconfiguredView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Material(
      color: Color(0xFF1E293B),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Text(
              'App misconfigured\n\nThe app lock is missing, so no patient data is shown. Please reinstall the app.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 18),
            ),
          ),
        ),
      ),
    );
  }
}
