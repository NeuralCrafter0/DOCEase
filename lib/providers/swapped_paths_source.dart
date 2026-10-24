/// Interim seam for #10's `LocalDatabase.swappedPathsFor` (announced by
/// the DB engineer, not posted yet). PatientProvider.updateRecord uses it
/// when the database implements this interface; once #10's commit lands
/// on LocalDatabase, delete this file and call `_db.swappedPathsFor`
/// directly (one line in PatientProvider._swappedPathsFor).
///
/// Contract (as announced): strict; returns local attachment key
/// (`attachments/<file>`) -> Storage path from attachment_swaps for
/// [patientId], only entries whose Storage path passes
/// `isStoragePathFor(expectedOwner, patientId)`; throws DbReadException
/// when it cannot read (including an owner mismatch).
abstract interface class SwappedPathsSource {
  Future<Map<String, String>> swappedPathsFor({
    required String expectedOwner,
    required String patientId,
  });
}
