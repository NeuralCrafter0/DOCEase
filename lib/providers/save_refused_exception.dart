import '../models/patient.dart' show UnreadablePatientException;
import '../services/log_codes.dart';
import 'local_database.dart' show UnsyncedCounterException;

/// Which patient save was refused.
enum PatientSaveOperation { add, update, delete, addVisit, updateVisit, deleteVisit }

/// Thrown by `PatientProvider.addPatient` and `updatePatient` when the save
/// is refused, in normal and dev mode alike. By the time it is thrown the
/// provider has already rolled back its in-memory list: a refused add is no
/// longer shown, and a refused update shows the previous version again.
/// Nothing was synced.
///
/// Screens catch this one type, show an error message (for example a
/// SnackBar saying "Could not save"), close the form and keep no partial
/// data (QA F-PAT-05/06, frontend #5); they never need to know the
/// reason. [error] is the original error for code that does need to tell
/// them apart.
///
/// Compatible with code written against the original errors: a refusal
/// caused by `UnsyncedCounterException` (secure storage failing) or
/// `UnreadablePatientException` (the patient has records this app version
/// cannot read) is thrown as a subtype of that exception that also
/// implements [SaveRefusedException]. So `on UnsyncedCounterException` and
/// `isA<UnsyncedCounterException>()` keep matching.
///
/// [toString] holds only the operation and [causeCode] (an error code or
/// type name, see `errorCode`), never patient data, ids or raw messages,
/// so it is safe to log.
abstract class SaveRefusedException implements Exception {
  factory SaveRefusedException(PatientSaveOperation operation, Object error) => switch (error) {
        UnsyncedCounterException c => _CounterSaveRefused(operation, c),
        UnreadablePatientException c => _UnreadableSaveRefused(operation, c),
        _ => _SaveRefused(operation, error),
      };

  PatientSaveOperation get operation;

  /// The original error. Do not log it directly: use [causeCode]. (Named
  /// `error`, not `cause`: `UnsyncedCounterException.cause` is its own
  /// sanitized code.)
  Object get error;

  /// Sanitized code of [error], safe to log.
  String get causeCode;
}

String _describe(PatientSaveOperation operation, String causeCode) =>
    'SaveRefusedException(${operation.name}, cause: $causeCode)';

class _SaveRefused implements SaveRefusedException {
  _SaveRefused(this.operation, this.error) : causeCode = errorCode(error);
  @override
  final PatientSaveOperation operation;
  @override
  final Object error;
  @override
  final String causeCode;
  @override
  String toString() => _describe(operation, causeCode);
}

class _CounterSaveRefused extends UnsyncedCounterException implements SaveRefusedException {
  _CounterSaveRefused(this.operation, UnsyncedCounterException original)
      : error = original,
        causeCode = errorCode(original),
        super(original.uid, original.cause);
  @override
  final PatientSaveOperation operation;
  @override
  final Object error;
  @override
  final String causeCode;
  @override
  String toString() => _describe(operation, causeCode);
}

class _UnreadableSaveRefused extends UnreadablePatientException implements SaveRefusedException {
  _UnreadableSaveRefused(this.operation, UnreadablePatientException original)
      : error = original,
        causeCode = errorCode(original),
        super(original.patientId);
  @override
  final PatientSaveOperation operation;
  @override
  final Object error;
  @override
  final String causeCode;
  @override
  String toString() => _describe(operation, causeCode);
}
