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

  /// Retries the load.
  static Future<void> reload(PatientProvider p) => p.reload();
}
