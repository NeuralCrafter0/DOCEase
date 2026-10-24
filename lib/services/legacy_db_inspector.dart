/// Optional capability a [LocalDatabase] can add so SessionController can
/// tell whether the pre-update (unscoped) database belongs to the doctor
/// signing in, before claiming it.
///
/// Not implemented by DatabaseHelper yet (proposed to the DB engineer).
/// Until it is, SessionController cannot compare patient ids and always
/// asks before merging a legacy database (fail safe: never merges silently).
abstract interface class LegacyDbInspector {
  /// Patient ids stored in the unclaimed legacy database, read without
  /// claiming, converting or deleting it. Empty when there is none. Throws
  /// DbOpenException if the legacy file cannot be read.
  Future<Set<String>> legacyPatientIds();
}
