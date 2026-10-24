import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'providers/patient_provider.dart';
import 'providers/doctor_provider.dart';
import 'providers/medicine_provider.dart';
import 'providers/database_helper.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'security/app_lock.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  bool firebaseReady = false;
  try {
    await Firebase.initializeApp();
    await GoogleSignIn.instance.initialize(
      serverClientId: '1014476645992-6s886d3l0h84lb277ghfq571gkg6bfi9.apps.googleusercontent.com',
    );
    firebaseReady = true;
  } catch (e) {
    debugPrint('Init Error: $e');
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (ctx) => PatientProvider()),
        ChangeNotifierProvider(create: (ctx) => DoctorProvider()),
        ChangeNotifierProvider(create: (ctx) => MedicineProvider()),
      ],
      child: DOCEaseApp(ready: firebaseReady),
    ),
  );
}

class DOCEaseApp extends StatelessWidget {
  final bool ready;
  const DOCEaseApp({super.key, required this.ready});

  @override
  Widget build(BuildContext context) {
    final app = MaterialApp(
      title: 'DOCEase',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1), surface: const Color(0xFFF8FAFC)),
      ),
      home: !ready 
          ? const Scaffold(body: Center(child: Text('Clinical Cloud Connection Error')))
          : const SecurityWrapper(),
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

    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (ctx, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        if (snapshot.hasData) return const HomeScreen();
        return const LoginScreen();
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
