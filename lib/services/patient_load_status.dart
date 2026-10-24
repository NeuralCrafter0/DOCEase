/// Whether the app's patient list is loaded for an owner (security, #16
/// loadFailed contract). The app's PatientProvider publishes here; the
/// startup photo sweep, a StartupHook that runs before any provider
/// exists, reads it when it runs and skips while the load has failed
/// (defence in depth: the sweep's own fresh scan fails closed anyway).
///
/// Carries owner ids and a flag only, never patient data.
class PatientLoadStatus {
  PatientLoadStatus();

  /// The app's instance (PatientProvider() and PhotoSweep.forApp()).
  static final PatientLoadStatus instance = PatientLoadStatus();

  String? _owner;
  bool _loaded = false;
  bool _failed = false;

  /// The patient list for [owner] was read completely.
  void loaded(String owner) => _set(owner, loaded: true, failed: false);

  /// The last load for [owner] failed (the list is stale or empty).
  void failed(String owner) => _set(owner, loaded: false, failed: true);

  /// Session ended or owner changed: nothing is loaded.
  void cleared() => _set(null, loaded: false, failed: false);

  void _set(String? owner, {required bool loaded, required bool failed}) {
    _owner = owner;
    _loaded = loaded;
    _failed = failed;
  }

  /// True only while [owner]'s list is loaded and the last load succeeded.
  bool isLoaded(String owner) => _owner == owner && _loaded && !_failed;

  bool isFailed(String owner) => _owner == owner && _failed;
}
