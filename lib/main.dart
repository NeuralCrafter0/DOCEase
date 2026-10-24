import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:local_auth/local_auth.dart';
import 'providers/patient_provider.dart';
import 'providers/doctor_provider.dart';
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
import 'widgets/session_status_view.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Features register StartupHooks here (before the start-mode checks) so
  // they run in dev and normal mode alike; see services/startup_hooks.dart.
  // The photo sweep waits for the first open DB and sweeps only that owner.
  StartupHooks.register(PhotoSweep.hookName, PhotoSweep.startupHook);

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

class DOCEaseApp extends StatelessWidget {
  final bool ready;
  /// Dev mode as requested by main(). Only takes effect when [kDevMode] is
  /// true: in a build without the define it is ignored (see [isDevMode]).
  final bool devMode;

  /// The effective value: `kDevMode && devMode` (const first, so it folds).
  bool get isDevMode => kDevMode && devMode;
  const DOCEaseApp({super.key, required this.ready, this.devMode = false});

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
    return MaterialApp(
      title: 'DOCEase',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1), surface: const Color(0xFFF8FAFC)),
      ),
      builder: devBanner,
      home: devHome ??
          (!ready 
          ? const Scaffold(body: Center(child: Text('Clinical Cloud Connection Error')))
          : const SecurityWrapper()),
    );
  }
}

class SecurityWrapper extends StatefulWidget {
  const SecurityWrapper({super.key});

  @override
  State<SecurityWrapper> createState() => _SecurityWrapperState();
}

class _SecurityWrapperState extends State<SecurityWrapper> with WidgetsBindingObserver {
  final LocalAuthentication auth = LocalAuthentication();
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  DateTime? _backgroundTimestamp;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authenticate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _backgroundTimestamp = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      if (_backgroundTimestamp != null) {
        final diff = DateTime.now().difference(_backgroundTimestamp!);
        if (diff.inMinutes >= 1) {
          setState(() { _isAuthenticated = false; _backgroundTimestamp = null; });
          _authenticate();
        }
      }
    }
  }

  Future<void> _authenticate() async {
    if (_isAuthenticating) return;
    setState(() => _isAuthenticating = true);
    bool authenticated = false;
    try {
      final bool canCheck = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (canCheck) {
        authenticated = await auth.authenticate(localizedReason: 'Identity Check');
      } else {
        authenticated = true; 
      }
    } catch (e) {
      authenticated = true; 
    }
    if (mounted) setState(() { _isAuthenticated = authenticated; _isAuthenticating = false; });
  }

  @override
  Widget build(BuildContext context) {
    if (!_isAuthenticated) {
      return Scaffold(
        backgroundColor: const Color(0xFF1E293B),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.shield_outlined, size: 80, color: Colors.white),
              const SizedBox(height: 24),
              const Text('DOCEase Secured', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 48),
              ElevatedButton.icon(
                onPressed: _authenticate,
                icon: const Icon(Icons.lock_open_rounded),
                label: const Text('Unlock Dashboard'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
              )
            ],
          ),
        ),
      );
    }

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
