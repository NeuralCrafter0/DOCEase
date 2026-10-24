import '../providers/patient_provider.dart';

/// The screens' view of the strict patient read (backend contract, #16):
///
/// * `bool get loadFailed`: true when the last load failed. A failed first
///   load leaves the list empty; a failed reload keeps the old list.
/// * `Future<void> reload()`: retries, and clears loadFailed on success.
/// * While loadFailed is true, every patient/visit write and delete throws
///   SaveRefusedException, so screens hide those actions (see [readOnly]).
///
/// main's [PatientProvider] does not have these members yet, so they are read
/// by name here and nowhere else. On a provider without them, [failed] is
/// false and [reload] falls back to `fetchAndSetPatients()`, which is exactly
/// today's behaviour. Once #16 merges, replace both bodies with direct calls
/// (`p.loadFailed`, `p.reload()`); no screen needs to change.
class PatientLoad {
  PatientLoad._();

  /// True when the last patient load failed.
  static bool failed(PatientProvider p) {
    try {
      return (p as dynamic).loadFailed == true;
    } on NoSuchMethodError {
      return false;
    }
  }

  /// Patient and visit writes are refused: hide add, edit and delete.
  static bool readOnly(PatientProvider p) => failed(p);

  /// Retries the load.
  static Future<void> reload(PatientProvider p) {
    try {
      return (p as dynamic).reload() as Future<void>;
    } on NoSuchMethodError {
      return p.fetchAndSetPatients();
    }
  }
}
