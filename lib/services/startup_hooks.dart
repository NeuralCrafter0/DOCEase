import 'package:flutter/foundation.dart';

import 'log_codes.dart';

/// Work that must run once the app has started, in dev mode and normal mode
/// alike, without each feature editing both start paths in main.dart.
///
/// main.dart calls [runAll] right after `runApp` on both paths (never on the
/// "dev build refused" screen). A feature registers its hook early in
/// `main()`, before the start-mode switch, for example PR #8:
///
/// ```dart
/// StartupHooks.register('picker_hygiene', PickerHygiene.atStartup);
/// ```
///
/// That one line replaces #8's `PickerHygiene.atStartup().ignore();` after
/// the normal path's `runApp`, which dev mode never reaches.
///
/// Hooks run in registration order, without awaiting one another and never
/// blocking the first frame. A failure is logged as an error code only (no
/// message, path or patient data) and does not stop the other hooks.
/// Registering after [runAll] runs the hook at once. A name registers once;
/// a repeat is ignored.
abstract final class StartupHooks {
  static final Map<String, Future<void> Function()> _hooks = {};
  static bool _started = false;

  /// Names of the registered hooks, in order (for tests and diagnostics).
  static List<String> get names => List.unmodifiable(_hooks.keys);

  static void register(String name, Future<void> Function() hook) {
    if (_hooks.containsKey(name)) return;
    _hooks[name] = hook;
    if (_started) _run(name, hook);
  }

  /// Starts every registered hook. Only the first call has an effect.
  static void runAll() {
    if (_started) return;
    _started = true;
    _hooks.forEach(_run);
  }

  static void _run(String name, Future<void> Function() hook) {
    Future<void>.sync(hook).catchError((Object e) {
      debugPrint('Startup: hook $name failed (${errorCode(e)})');
    }).ignore();
  }

  @visibleForTesting
  static void resetForTesting() {
    _hooks.clear();
    _started = false;
  }
}
