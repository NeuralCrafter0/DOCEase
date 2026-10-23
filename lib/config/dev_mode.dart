import 'package:flutter/widgets.dart';

/// Compile-time development switch, OFF by default.
///
/// Dev runs and CI PR builds turn it on:
///
///     flutter run --dart-define=DOCEASE_DEV_MODE=true
///
/// (VS Code: the "DOCEase (dev mode)" entry in .vscode/launch.json.)
///
/// When on, the app never calls Firebase.initializeApp or GoogleSignIn,
/// skips the login screen and the biometric lock, and opens straight to
/// home. The encrypted DB is opened for [kLocalOwnerId]; sync, uploads and
/// fetches are skipped (not removed); a "DEV MODE: test data only" banner is
/// shown on every screen.
///
/// Nothing is deleted: a plain build (or `--dart-define=DOCEASE_DEV_MODE=false`)
/// has login, the lock, the security rules and sync. CI release builds pass
/// `--dart-define=DOCEASE_DEV_MODE=false` and refuse a release built with it on.
///
/// Code below main() should not read this constant directly: use
/// [DevMode.of] (widgets) or the providers' `cloudSync` parameter, so tests
/// can set the mode explicitly.
const bool kDevMode = bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false);

/// The owner id of the on-phone database used in dev mode. It is never a
/// Firebase uid (those are 28 characters), so dev data stays in its own
/// encrypted DB file and never mixes with a signed-in doctor's data.
const String kLocalOwnerId = 'local';

/// Text of the banner shown on every screen while dev mode is on.
const String kDevModeBannerText = 'DEV MODE: test data only';

/// Injectable dev-mode flag for widgets. The dev-mode app wraps everything
/// in `DevMode(enabled: true)`; without a scope the compile-time [kDevMode]
/// applies. Tests pump an explicit scope instead of relying on the define.
class DevMode extends InheritedWidget {
  const DevMode({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DevMode>()?.enabled ?? kDevMode;

  @override
  bool updateShouldNotify(DevMode oldWidget) => enabled != oldWidget.enabled;
}
