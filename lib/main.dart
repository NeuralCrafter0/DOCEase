import 'dart:async';
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
/// session or account data loads before then. Without a host it stays blank
/// (fail closed).
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
    assert(_lock != null, 'SecurityWrapper must be built below an AppLockHost');
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
