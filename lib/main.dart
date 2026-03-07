import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:local_auth/local_auth.dart';
import 'providers/patient_provider.dart';
import 'providers/doctor_provider.dart';
import 'providers/medicine_provider.dart';
import 'providers/database_helper.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

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
    return MaterialApp(
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
