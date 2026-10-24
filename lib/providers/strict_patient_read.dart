// Interim shape of #10's strict patient read (fetchPatientsStrict()).
//
// TODO(db-strict-read): the DB engineer is adding `fetchPatientsStrict()` to
// LocalDatabase with a typed error and a reason enum (notOpen, readFailed,
// unreadableRow). Once their names are posted, replace these three
// declarations with theirs (or typedef them) and drop the
// [StrictPatientReads] check in PatientProvider._readPatients. Nothing
// else depends on these names.
import '../models/patient.dart';

/// Why a strict read gave up. Carries no patient data.
enum PatientReadFailure { notOpen, readFailed, unreadableRow }

/// Thrown by a strict read instead of returning a partial or empty list.
/// Only the [reason] is kept: never a path, a row or a message.
class PatientReadIncomplete implements Exception {
  const PatientReadIncomplete(this.reason);

  final PatientReadFailure reason;

  @override
  String toString() => 'PatientReadIncomplete(${reason.name})';
}

/// A database that can read every patient or throw [PatientReadIncomplete]
/// (unlike `fetchPatients()`, which returns `[]` on a read error).
abstract interface class StrictPatientReads {
  Future<List<Patient>> fetchPatientsStrict();
}
