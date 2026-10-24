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
/// [DevMode.of] (widgets) or the providers' `cloudSync` parameter. Every
/// injectable way to turn dev mode ON (`DevMode`, `DOCEaseApp.devMode`,
/// `SessionController.localOnly`, `LocalOnlySessionPlatform`,
/// `buildDevModeApp`) is gated on [kDevMode], so no code path can enable
/// it in a build without the define. `cloudSync: false` only turns cloud
/// work off and is not gated.
const bool kDevModeRequested =
    bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false);

/// Dev mode is only ever active outside release builds.
///
/// A compile-time constant: dev-only code sits directly under
/// `if (kDevMode) { ... }` (or `kDevMode && ...`), so the AOT compiler drops
/// it, and `buildDevModeApp`, the banner and the dev strings are not in a
/// build without the define.
const bool kDevMode = kDevModeRequested && !kReleaseMode;

/// A release build made with the define: main() shows only the refusal
/// screen.
const bool kDevBuildRefused = kDevModeRequested && kReleaseMode;

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
/// main() makes the same decision with the constants directly
/// (`if (kDevBuildRefused)`, `if (kDevMode)`) so the compiler can remove the
/// branches a build cannot take.
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

/// Dev-mode flag for widgets. The dev-mode app wraps everything in
/// `DevMode(enabled: true)`.
///
/// A scope can only turn dev mode OFF: [of] is `enabled && kDevMode`, so
/// without the define (or in a release build) it is always false, whatever
/// is injected. Without a scope [kDevMode] applies. Tests that need dev mode
/// on run with `--dart-define=DOCEASE_DEV_MODE=true` (see docs/DEV_MODE.md).
class DevMode extends InheritedWidget {
  const DevMode({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      kDevMode && (context.dependOnInheritedWidgetOfExactType<DevMode>()?.enabled ?? true);

  @override
  bool updateShouldNotify(DevMode oldWidget) => enabled != oldWidget.enabled;
}
