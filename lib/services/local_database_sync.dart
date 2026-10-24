import '../models/patient.dart';

/// The DB engineer's confirmed additions to LocalDatabase, declared here
/// until their commit lands (same names; PatientProvider uses them when
/// the database implements this, else falls back to the 09a405f API).
///
/// TODO(db-merge): once LocalDatabase declares these, delete this file,
/// drop the `is LocalDatabaseSync` checks in PatientProvider and add
/// @override in test/backend/fakes.dart (MergeDb).
abstract interface class LocalDatabaseSync {
  /// One conditional write: stores the cloud copy as synced only if the
  /// local row is missing or clean AND the id has no pending-delete
  /// tombstone. False = skipped (dirty or tombstoned), not an error.
  Future<bool> applyCloudPatient(Patient patient);

  /// Removes the row and writes a tombstone in one transaction; the
  /// tombstone counts as unsynced. Throws (e.g. UnsyncedCounterException)
  /// when refused; then nothing changed.
  Future<void> markPendingDelete(String patientId);

  /// Ids whose cloud delete Firestore has not confirmed yet.
  Future<List<String>> pendingDeletes();

  /// Call only after Firestore confirmed the delete.
  Future<void> clearPendingDelete(String patientId);
}
