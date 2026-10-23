import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/widgets.dart';

/// Compile-time development switch, OFF by default, and never on in a
/// release build.
///
/// Dev runs use the Android `dev` flavor in debug or profile mode:
///
///     flutter run --flavor dev --dart-define=DOCEASE_DEV_MODE=true
///     flutter build apk --profile --flavor dev --dart-define=DOCEASE_DEV_MODE=true
///
/// (VS Code: the "DOCEase (dev mode)" entries in .vscode/launch.json.)
///
/// When on, the app never calls Firebase.initializeApp or GoogleSignIn,
/// skips the login screen and the biometric lock, and opens straight to
/// home. The encrypted DB is opened for [kLocalOwnerId]; sync, uploads and
/// fetches are skipped (not removed); a "DEV MODE: test data only" banner is
/// shown on every screen.
///
/// Nothing is deleted: a plain build (or `--dart-define=DOCEASE_DEV_MODE=false`)
/// has login, the lock, the security rules and sync.
///
/// Code below main() should not read these constants directly: use
/// [DevMode.of] (widgets) or the providers' `cloudSync` parameter, so tests
/// can set the mode explicitly.
const bool kDevModeRequested =
    bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false);

/// Dev mode is only ever active outside release builds.
const bool kDevMode = kDevModeRequested && !kReleaseMode;

/// How the app starts for a given define and build mode.
enum StartMode {
  /// The real app: Firebase, login, lock, sync.
  normal,

  /// Dev mode (debug/profile only).
  dev,

  /// Release build made with DOCEASE_DEV_MODE=true: blocked, nothing runs.
  refused,
}

/// Pure version of the startup decision, for tests:
/// release + requested is refused, never silently normal or dev.
StartMode decideStartMode({required bool requested, required bool release}) {
  if (!requested) return StartMode.normal;
  return release ? StartMode.refused : StartMode.dev;
}

/// The owner id of the on-phone database used in dev mode. It is never a
/// Firebase uid (those are 28 characters), so dev data stays in its own
/// encrypted DB file and never mixes with a signed-in doctor's data.
const String kLocalOwnerId = 'local';

/// Whether [uid] is the dev owner. Every cloud path (sync, upload, fetch,
/// session approval) refuses it, so dev data can never reach Firebase and a
/// Firebase account called `local` can never open the dev database.
bool isLocalOwner(String? uid) => uid == kLocalOwnerId;

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
