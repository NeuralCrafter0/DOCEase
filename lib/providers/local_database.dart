import '../models/patient.dart';

// ---------------------------------------------------------------------------
// UI contract
// ---------------------------------------------------------------------------

/// Which recovery a [DbMigrating] state is running.
enum DbMigrationStep {
  /// A legacy plaintext database is being exported into an encrypted copy.
  encryptingPlaintext,

  /// A legacy database encrypted with the old hardcoded fallback key is being
  /// rekeyed to the doctor's real key.
  rekeyingFromFallback,

  /// A legacy database encrypted with the old unscoped key
  /// (`db_encryption_key_prod`) is being rekeyed to the doctor's own key.
  /// This is the normal, non-defect legacy path.
  rekeyingFromLegacyKey,
}

/// Why opening (or claiming) a database failed. Every case is retryable via
/// [LocalDatabase.openFor] / [LocalDatabase.claimLegacyDb]; only
/// [keyMismatch] may offer [LocalDatabase.resetAndResync].
enum DbOpenError {
  /// Secure storage threw while reading or writing the key. Retry only; never
  /// offer a reset (the key, and therefore the data, is probably fine).
  keyUnavailable,

  /// A database file exists but no available key decrypts it. This is the
  /// only error that offers [LocalDatabase.resetAndResync].
  keyMismatch,

  /// A recovery migration or schema upgrade failed (or an unclassified open
  /// error occurred). The original file is untouched; safe to retry.
  migrationFailed,

  /// The device ran out of space. The original file is untouched.
  storageFull,
}

/// Lifecycle of the doctor-scoped database. Every state except [DbClosed]
/// carries the Firebase uid it refers to, so a listener can ignore events
/// for a doctor who is no longer current.
sealed class DbOpenState {
  const DbOpenState(this.uid);

  /// The doctor this state refers to; `null` only for [DbClosed].
  final String? uid;
}

/// No database is open (initial state, or after [LocalDatabase.close]).
/// Nothing is ever opened without a uid.
final class DbClosed extends DbOpenState {
  const DbClosed() : super(null);
  @override
  String toString() => 'DbClosed()';
}

final class DbOpening extends DbOpenState {
  const DbOpening(String super.uid);
  @override
  String toString() => 'DbOpening($uid)';
}

final class DbMigrating extends DbOpenState {
  const DbMigrating(String super.uid, this.step, this.progress);
  final DbMigrationStep step;

  /// 0.0 to 1.0, non-decreasing within one migration.
  final double progress;
  @override
  String toString() => 'DbMigrating($uid, ${step.name}, $progress)';
}

final class DbReady extends DbOpenState {
  const DbReady(String super.uid);
  @override
  String toString() => 'DbReady($uid)';
}

final class DbFailed extends DbOpenState {
  const DbFailed(String super.uid, this.error, [this.cause]);
  final DbOpenError error;

  /// Underlying exception, for logging only (never show it to the user).
  final Object? cause;

  /// Only a key mismatch may offer a destructive reset. The file cannot be
  /// read in this state; [LocalDatabase.unsyncedCount] then comes from a
  /// counter kept outside the database and may be unknown.
  bool get canReset => error == DbOpenError.keyMismatch;
  @override
  String toString() => 'DbFailed($uid, ${error.name})';
}

class DbOpenException implements Exception {
  DbOpenException(this.error, {this.uid, this.cause});
  final DbOpenError error;
  final String? uid;
  final Object? cause;
  @override
  String toString() =>
      'DbOpenException(${error.name}, uid: $uid, cause: ${cause.runtimeType})';
}

/// How many local patient changes Firestore has not confirmed yet.
///
/// [UnsyncedCount.unknown] means the count could not be determined (counter
/// missing or unreadable). Treat it as "may have unsynced records": the
/// strongest data-loss warning, stronger than any known number.
sealed class UnsyncedCount {
  const UnsyncedCount();
  const factory UnsyncedCount.known(int count) = UnsyncedKnown;
  static const UnsyncedCount unknown = UnsyncedUnknown();

  /// True unless the count is known to be zero.
  bool get mayHaveUnsynced;

  /// Whether a user who was warned with this value has accepted at least the
  /// risk of [current]: known(0) needs nothing; known(n) needs known(>= n) or
  /// unknown; unknown needs unknown.
  bool covers(UnsyncedCount current) => switch (current) {
        UnsyncedKnown(count: 0) => true,
        UnsyncedKnown(:final count) => switch (this) {
            UnsyncedUnknown() => true,
            UnsyncedKnown(count: final acked) => acked >= count,
          },
        UnsyncedUnknown() => this is UnsyncedUnknown,
      };
}

final class UnsyncedKnown extends UnsyncedCount {
  const UnsyncedKnown(this.count) : assert(count >= 0);
  final int count;
  @override
  bool get mayHaveUnsynced => count > 0;
  @override
  bool operator ==(Object other) =>
      other is UnsyncedKnown && other.count == count;
  @override
  int get hashCode => count.hashCode;
  @override
  String toString() => 'UnsyncedCount.known($count)';
}

final class UnsyncedUnknown extends UnsyncedCount {
  const UnsyncedUnknown();
  @override
  bool get mayHaveUnsynced => true;
  @override
  bool operator ==(Object other) => other is UnsyncedUnknown;
  @override
  int get hashCode => 0;
  @override
  String toString() => 'UnsyncedCount.unknown';
}

/// Thrown by [LocalDatabase.resetAndResync] when the user was warned about
/// less than [current] (for example "0 unsynced" while the counter now says
/// 3, or a number while it is now unknown). Nothing was deleted.
class ResetNotConfirmedException implements Exception {
  const ResetNotConfirmedException(this.current);
  final UnsyncedCount current;
  @override
  String toString() => 'ResetNotConfirmedException(current: $current)';
}

/// A local save was refused because the unsynced counter could neither be
/// incremented nor cleared to "unknown" (secure storage failing). Saving
/// anyway could let a later reset under-report what would be lost.
class UnsyncedCounterException implements Exception {
  const UnsyncedCounterException(this.uid, [this.cause]);
  final String uid;
  final Object? cause;
  @override
  String toString() =>
      'UnsyncedCounterException($uid, cause: ${cause.runtimeType})';
}

/// Row-level sync marker stored in `patients.sync_state`.
abstract final class SyncState {
  static const dirty = 'dirty';
  static const synced = 'synced';
}

// ---------------------------------------------------------------------------
// Interface
// ---------------------------------------------------------------------------

/// The local, doctor-scoped patient store. [DatabaseHelper] is the SQLCipher
/// implementation; tests (and the backend engineer's sync tests) can supply a
/// hand-written fake with `implements LocalDatabase`.
abstract class LocalDatabase {
  /// Emits the current state immediately on listen, then every change.
  Stream<DbOpenState> get states;

  /// The current state.
  DbOpenState get state;

  /// Opens (creating if needed) the database for [uid] with that doctor's own
  /// key, closing any other doctor's database first. Fails closed: if the key
  /// is unavailable nothing is opened or created. Also the retry path after
  /// any [DbFailed]. Throws [DbOpenException] on failure.
  Future<void> openFor(String uid);

  /// Closes the current database. The state becomes [DbClosed].
  Future<void> close();

  /// Unsynced local changes for the current doctor (the open one, or the one
  /// whose open failed). Exact from the rows when the database is open, and
  /// the stored counter reconciled to match; otherwise the per-uid counter in
  /// secure storage, or [UnsyncedCount.unknown]. Never throws.
  Future<UnsyncedCount> unsyncedCount();

  /// Only valid in `DbFailed(keyMismatch)`: discards the current doctor's
  /// undecryptable database, starts a fresh one under a new key, then runs
  /// [resync] (for example a Firestore pull). [acknowledgedUnsynced] is the
  /// count the user was shown and accepted; if the current count is worse,
  /// throws [ResetNotConfirmedException] and deletes nothing. Throws
  /// [StateError] in any other state.
  Future<void> resetAndResync({
    required UnsyncedCount acknowledgedUnsynced,
    Future<void> Function()? resync,
  });

  /// Whether an unclaimed legacy (pre-per-doctor) database exists. Never
  /// opens it. Finishes or rolls back an interrupted claim first.
  Future<bool> hasLegacyDb();

  /// Converts the legacy database into [uid]'s database (recovering plaintext
  /// and fallback-key files), verifies row counts, then deletes the legacy
  /// file, leaving [uid]'s database open. Returns false, changing nothing, if
  /// there is no legacy database (so a repeat claim, or a claim by another
  /// doctor afterwards, is a no-op). If [uid] already has a database with
  /// patients, nothing is merged or overwritten: [uid]'s own database is
  /// opened as usual, the legacy file is left as is, and false is returned.
  /// Throws [DbOpenException] on failure, leaving the legacy file untouched.
  Future<bool> claimLegacyDb(String uid);

  // --- patient persistence (used by PatientProvider) ----------------------

  /// All patients. Rows that fail to parse are returned flagged
  /// ([Patient.hasParseErrors]) with their original data kept.
  Future<List<Patient>> fetchPatients();

  /// Inserts or replaces [patient]: dirty for local edits, synced when
  /// [fromCloud]. Returns the row's new `updated_at` (pass it to
  /// [markSynced] once Firestore confirms), or `null` if nothing was written
  /// (including patients with parse errors). Throws
  /// [UnsyncedCounterException] (nothing written) if the unsynced counter
  /// cannot be kept from under-reporting.
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false});

  /// Updates [patient] and marks it dirty. Returns the new `updated_at` or
  /// null. Throws [UnsyncedCounterException] like [insertPatient].
  Future<String?> updatePatient(Patient patient);

  /// Rows with sync_state dirty, oldest `updated_at` first, each with
  /// [Patient.updatedAt] set.
  Future<List<Patient>> dirtyPatients();

  /// Compare-and-set: marks [patientId] clean (and decrements the unsynced
  /// counter) only if its `updated_at` still equals [syncedUpdatedAt], the
  /// value that was sent to Firestore. Returns false, leaving the row dirty,
  /// if it was edited while the write was in flight.
  Future<bool> markSynced(String patientId, String syncedUpdatedAt);

  Future<void> deletePatient(String id);
}
