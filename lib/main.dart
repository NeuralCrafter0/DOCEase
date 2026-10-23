import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Why the app is locked. Drives the copy on the lock screen; it never
/// unlocks anything by itself.
enum _LockReason {
  /// An authentication prompt is (about to be) on screen.
  checking,

  /// The last attempt failed, was cancelled or errored. Retry is offered.
  failed,

  /// Too many attempts (LockedOut / PermanentlyLockedOut).
  lockedOut,

  /// The device has no PIN, pattern, password or biometric set.
  noScreenLock,
}

/// App lock, fail-closed.
///
/// * [_isAuthenticated] starts false and only a `true` result from
///   [LocalAuthentication.authenticate] sets it. Every exception and every
///   "can't check" path leaves the app locked.
/// * Nothing behind the lock (the auth gate, and with it any session or
///   account data) is built until the first successful unlock.
/// * The app re-locks every time it goes to the background (hidden/paused)
///   and prompts again on resume. A transient `inactive` (notification
///   shade, system dialogs) does not re-lock, and lifecycle changes caused
///   by the system auth UI itself are ignored.
/// * After the first unlock, re-locking pushes an opaque, non-poppable lock
///   route on the root navigator. It covers every screen and sheet the user
///   had open while keeping their state (e.g. a half-written clinical note).
class _SecurityWrapperState extends State<SecurityWrapper> with WidgetsBindingObserver {
  final LocalAuthentication auth = LocalAuthentication();
  final ValueNotifier<_LockReason> _lockReason = ValueNotifier(_LockReason.checking);
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  bool _hasUnlockedOnce = false;
  bool _wentToBackground = false;
  NavigatorState? _relockNavigator;
  Route<void>? _relockRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _authenticate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockReason.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // The system biometric / device-credential UI can background the app
        // while a prompt is running. That is not the user leaving.
        if (_isAuthenticating) return;
        _wentToBackground = true;
        if (_isAuthenticated) _lock(_LockReason.checking);
      case AppLifecycleState.resumed:
        if (!_wentToBackground || _isAuthenticating) return;
        _wentToBackground = false;
        if (!_isAuthenticated) _authenticate();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _authenticate() async {
    if (_isAuthenticating) return;
    _isAuthenticating = true;
    _lockReason.value = _LockReason.checking;
    bool authenticated = false;
    _LockReason failure = _LockReason.failed;
    try {
      if (!await auth.isDeviceSupported()) {
        failure = _LockReason.noScreenLock;
      } else {
        // biometricOnly: false lets the device PIN / pattern / password work
        // as a fallback when biometrics are unavailable or locked out.
        authenticated = await auth.authenticate(localizedReason: 'Identity Check', biometricOnly: false);
      }
    } on LocalAuthException catch (e) {
      failure = _reasonForCode(e.code);
    } on PlatformException catch (e) {
      failure = _reasonForLegacyCode(e.code);
    } catch (_) {
      failure = _LockReason.failed;
    }
    _isAuthenticating = false;
    if (!mounted) return;
    if (authenticated) {
      _unlock();
    } else {
      _lock(failure);
    }
  }

  static _LockReason _reasonForCode(LocalAuthExceptionCode code) {
    switch (code) {
      case LocalAuthExceptionCode.temporaryLockout:
      case LocalAuthExceptionCode.biometricLockout:
        return _LockReason.lockedOut;
      case LocalAuthExceptionCode.noCredentialsSet:
        return _LockReason.noScreenLock;
      default:
        return _LockReason.failed;
    }
  }

  /// Error codes used by local_auth < 3 and some platform implementations.
  static _LockReason _reasonForLegacyCode(String code) {
    switch (code) {
      case 'LockedOut':
      case 'PermanentlyLockedOut':
        return _LockReason.lockedOut;
      case 'PasscodeNotSet':
        return _LockReason.noScreenLock;
      default:
        return _LockReason.failed;
    }
  }

  void _lock(_LockReason reason) {
    _lockReason.value = reason;
    if (_hasUnlockedOnce && _relockRoute == null) {
      final navigator = Navigator.of(context, rootNavigator: true);
      final route = PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => PopScope(canPop: false, child: _buildLockScreen()),
      );
      _relockNavigator = navigator;
      _relockRoute = route;
      navigator.push(route);
    }
    setState(() => _isAuthenticated = false);
  }

  void _unlock() {
    final route = _relockRoute;
    final navigator = _relockNavigator;
    _relockRoute = null;
    _relockNavigator = null;
    if (route != null && navigator != null && route.isActive) navigator.removeRoute(route);
    setState(() {
      _isAuthenticated = true;
      _hasUnlockedOnce = true;
    });
  }

  Widget _buildLockScreen() {
    return ValueListenableBuilder<_LockReason>(
      valueListenable: _lockReason,
      builder: (context, reason, _) => _LockScreen(reason: reason, onUnlock: _authenticate),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Before the first successful unlock nothing behind the lock is built, so
    // no session or account data can load. Later re-locks are drawn by the
    // lock route on top of this subtree (see _lock).
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

class _LockScreen extends StatelessWidget {
  final _LockReason reason;
  final VoidCallback onUnlock;
  const _LockScreen({required this.reason, required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    final (String? message, String? detail, String action) = switch (reason) {
      _LockReason.checking => (null, null, 'Unlock Dashboard'),
      _LockReason.failed => (null, null, 'Unlock Dashboard'),
      _LockReason.lockedOut => ('Try again later', 'Too many attempts. Wait a moment, then unlock with your fingerprint, face or device PIN.', 'Try Again'),
      _LockReason.noScreenLock => ('Set a screen lock to use DOCEase', 'DOCEase protects patient records with your device PIN, pattern, password or biometrics. Add a screen lock in your device settings, then come back.', 'Check Again'),
    };
    return Scaffold(
      backgroundColor: const Color(0xFF1E293B),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.shield_outlined, size: 80, color: Colors.white),
                const SizedBox(height: 24),
                const Text('DOCEase Secured', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                if (message != null) ...[
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                ],
                if (detail != null) ...[
                  const SizedBox(height: 8),
                  Text(detail, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 14, height: 1.4)),
                ],
                const SizedBox(height: 48),
                if (reason == _LockReason.checking)
                  const SizedBox(height: 56, child: Center(child: CircularProgressIndicator(color: Colors.white)))
                else
                  ElevatedButton.icon(
                    onPressed: onUnlock,
                    icon: const Icon(Icons.lock_open_rounded),
                    label: Text(action),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 18),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
