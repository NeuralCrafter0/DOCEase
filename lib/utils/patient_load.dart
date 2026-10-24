import '../providers/patient_provider.dart';

/// The screens' view of the strict patient read (backend contract, #16 at
/// 3a695b0):
///
/// * `bool get loadFailed`: true when the last load failed. A failed first
///   load leaves the list empty; a failed reload keeps the old list.
/// * `Future<void> reload()`: retries, and clears loadFailed on success.
/// * While loadFailed is true, every patient/visit write and delete throws
///   SaveRefusedException, so screens hide those actions (see [readOnly]).
///
/// Screens go through this class rather than the provider so the contract
/// is in one place. (`loadFailure` is diagnostics only and never shown.)
class PatientLoad {
  PatientLoad._();

  /// True when the last patient load failed.
  static bool failed(PatientProvider p) => p.loadFailed;

  /// Patient and visit writes are refused: hide add, edit and delete.
  static bool readOnly(PatientProvider p) => failed(p);

  /// True while the current owner's first load hasn't settled (#16
  /// `hasLoaded`, contract G2). A failed first load is not "loading": the
  /// failure view shows instead.
  static bool loading(PatientProvider p) => !p.hasLoaded && !p.loadFailed;

  /// Retries the load.
  static Future<void> reload(PatientProvider p) => p.reload();

  /// One patient's stored row can't be read (backend, per-patient flag).
  /// Set by the strict single-patient read on opening detail, or by a save
  /// refused because of that row; cleared on clear() or an owner change.
  /// No API yet: false until backend's commit, then it calls the real
  /// getter. Detail shows `patientDetail.unreadable` when true.
  static bool patientUnreadable(PatientProvider p, String id) => false;

  /// Run when patient detail opens, so the strict read can set the flag.
  /// A no-op until backend's commit names the call.
  static Future<void> openPatient(PatientProvider p, String id) async {}
}
