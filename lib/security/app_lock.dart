import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

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

/// Lock state shared by [AppLockHost] (which draws the lock) and the
/// protected part of the app (which only reads [hasUnlockedOnce]).
///
/// Fail-closed:
/// * Once [engage]d, the app is locked until a `true` result from
///   [LocalAuthentication.authenticate]. Every exception and every
///   "can't check" path leaves it locked.
/// * It re-locks every time the app goes to the background (hidden/paused)
///   and prompts again on resume. A transient `inactive` (notification
///   shade, system dialogs) does not re-lock, and lifecycle changes caused
///   by the system auth UI itself are ignored.
/// * Engaging is one-way: nothing in the app can disengage the lock.
class AppLockController extends ChangeNotifier with WidgetsBindingObserver {
  AppLockController({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication() {
    // Registered before MaterialApp's own observer (the host is its parent),
    // so a system back while locked is consumed here and never pops a screen
    // hidden behind the lock.
    WidgetsBinding.instance.addObserver(this);
  }

  final LocalAuthentication _auth;
  _LockReason _reason = _LockReason.checking;
  bool _engaged = false;
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;
  bool _hasUnlockedOnce = false;
  bool _wentToBackground = false;
  bool _disposed = false;

  /// True once the protected part of the app has asked to be locked.
  bool get engaged => _engaged;

  /// True while the lock screen is shown and the app below is hidden.
  bool get isLocked => _engaged && !_isAuthenticated;

  /// The protected subtree is built only after this turns true.
  bool get hasUnlockedOnce => _hasUnlockedOnce;

  /// Turns the lock on. Called by the protected subtree from initState, so
  /// the first prompt is started after the current frame (an ancestor can't
  /// rebuild during a descendant's build).
  void engage() {
    if (_engaged) return;
    _engaged = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed) return;
      notifyListeners();
      authenticate();
    });
    SchedulerBinding.instance.scheduleFrame();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_engaged) return;
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
        if (!_isAuthenticated) authenticate();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  // While locked, back must not pop or reveal anything behind the lock.
  @override
  Future<bool> didPopRoute() => Future<bool>.value(isLocked);

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => isLocked;

  Future<void> authenticate() async {
    if (_isAuthenticating || !_engaged) return;
    _isAuthenticating = true;
    _reason = _LockReason.checking;
    notifyListeners();
    bool authenticated = false;
    _LockReason failure = _LockReason.failed;
    try {
      if (!await _auth.isDeviceSupported()) {
        failure = _LockReason.noScreenLock;
      } else {
        // biometricOnly: false lets the device PIN / pattern / password work
        // as a fallback when biometrics are unavailable or locked out.
        authenticated = await _auth.authenticate(localizedReason: 'Identity Check', biometricOnly: false);
      }
    } on LocalAuthException catch (e) {
      failure = _reasonForCode(e.code);
    } on PlatformException catch (e) {
      failure = _reasonForLegacyCode(e.code);
    } catch (_) {
      failure = _LockReason.failed;
    }
    _isAuthenticating = false;
    if (_disposed) return;
    if (authenticated) {
      _isAuthenticated = true;
      _hasUnlockedOnce = true;
      notifyListeners();
    } else {
      _lock(failure);
    }
  }

  void _lock(_LockReason reason) {
    _reason = reason;
    _isAuthenticated = false;
    notifyListeners();
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
}

/// Draws the app lock above the whole app, and so above its navigator.
///
/// Wraps the [MaterialApp]. Routes, dialogs, sheets and snackbars all live
/// inside the app's navigator and overlay, which sit *below* this widget, so
/// no `Navigator.pop`, `showDialog` or push from app code can remove the lock
/// or draw over it. While locked the app stays mounted (a half-written note
/// keeps its state) but is offstage, excluded from semantics, focus and
/// keyboard input, and its tickers are paused.
///
/// The host does nothing until the protected subtree ([SecurityWrapper])
/// calls [AppLockController.engage]. Screens that never build it, such as
/// the "Clinical Cloud Connection Error" screen, are not locked.
class AppLockHost extends StatefulWidget {
  final Widget child;

  /// For tests; the default uses the real plugin.
  final LocalAuthentication? auth;

  const AppLockHost({super.key, required this.child, this.auth});

  /// The controller of the nearest host, or null when there is none.
  /// Registers a dependency, so callers rebuild when the lock state changes.
  ///
  /// A host with a [Navigator] above it (placed inside a route, e.g.
  /// `MaterialApp(home: AppLockHost(...))`) is not a lock host: a pushed
  /// route would draw over its lock. It returns null, so [SecurityWrapper]
  /// fails hard with "App misconfigured" in every build mode, and debug
  /// builds also report the misplacement (security review #4).
  static AppLockController? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_AppLockScope>();
    if (scope == null || scope.misplaced) return null;
    return scope.notifier;
  }

  @override
  State<AppLockHost> createState() => _AppLockHostState();
}

class _AppLockHostState extends State<AppLockHost> {
  late final AppLockController _controller = AppLockController(auth: widget.auth);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final misplaced = Navigator.maybeOf(context) != null;
    assert(() {
      if (misplaced) {
        FlutterError.reportError(FlutterErrorDetails(
          exception: FlutterError(
            'AppLockHost has a Navigator above it.\n'
            'It must wrap the MaterialApp; inside a route, pushed routes draw over the lock. '
            'SecurityWrapper treats this host as missing.',
          ),
          library: 'app_lock',
        ));
      }
      return true;
    }());
    return _AppLockScope(
      notifier: _controller,
      misplaced: misplaced,
      child: ListenableBuilder(
        listenable: _controller,
        // The same element always holds the app, so locking never rebuilds
        // or resets it.
        child: widget.child,
        builder: (context, app) {
          final locked = _controller.isLocked;
          return Stack(
            textDirection: TextDirection.ltr,
            fit: StackFit.expand,
            children: [
              TickerMode(
                enabled: !locked,
                child: ExcludeFocus(
                  excluding: locked,
                  child: ExcludeSemantics(
                    excluding: locked,
                    child: Offstage(offstage: locked, child: app),
                  ),
                ),
              ),
              if (locked) _LockLayer(controller: _controller),
            ],
          );
        },
      ),
    );
  }
}

class _AppLockScope extends InheritedNotifier<AppLockController> {
  /// True when the host has a Navigator above it; such a host never locks.
  final bool misplaced;
  const _AppLockScope({required AppLockController super.notifier, required this.misplaced, required super.child});

  @override
  bool updateShouldNotify(_AppLockScope oldWidget) => misplaced != oldWidget.misplaced || super.updateShouldNotify(oldWidget);
}

/// The lock screen sits above MaterialApp, so it brings its own media
/// query, localizations, directionality and theme.
class _LockLayer extends StatelessWidget {
  final AppLockController controller;
  const _LockLayer({required this.controller});

  static final ThemeData _theme = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1), surface: const Color(0xFFF8FAFC)),
  );

  @override
  Widget build(BuildContext context) {
    return MediaQuery.fromView(
      view: View.of(context),
      child: Localizations(
        locale: const Locale('en', 'US'),
        delegates: const [DefaultMaterialLocalizations.delegate, DefaultWidgetsLocalizations.delegate],
        child: Theme(
          data: _theme,
          child: _LockScreen(reason: controller._reason, onUnlock: controller.authenticate),
        ),
      ),
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
