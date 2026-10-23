import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/patient.dart';

/// Patient documents at `doctors/{uid}/patients/{patientId}`.
///
/// Returns true only once Firestore confirmed a write or delete, never
/// pushes a patient that failed to parse, and logs ids and error codes only
/// (no names or clinical data).
///
/// Auth and Firestore come through the constructor, resolved lazily so
/// tests never touch Firebase. [expectedUid] is the session guard: when it
/// returns a uid, every call is refused unless that uid is still the
/// signed-in user, so work started for doctor A can never write into or
/// read from doctor B's folder after an account switch. The public method
/// signatures are unchanged (test fakes implement this class).
class FirestoreHelper {
  FirestoreHelper({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    String? Function()? expectedUid,
  })  : _firestoreOverride = firestore,
        _authOverride = auth,
        _expectedUid = expectedUid;

  final FirebaseFirestore? _firestoreOverride;
  final FirebaseAuth? _authOverride;
  final String? Function()? _expectedUid;

  FirebaseFirestore get _db => _firestoreOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  /// The uid to act for, or null if nobody is signed in or the session this
  /// helper belongs to is no longer the signed-in user.
  String? _owner() {
    final current = _auth.currentUser?.uid;
    if (current == null) return null;
    final expected = _expectedUid?.call();
    if (expected != null && expected != current) return null;
    return current;
  }

  CollectionReference<Map<String, dynamic>> _patients(String uid) =>
      _db.collection('doctors').doc(uid).collection('patients');

  /// Returns true only once Firestore confirmed the write. A patient that
  /// failed to parse is never written (it would overwrite the real document).
  Future<bool> syncPatient(Patient patient) async {
    if (patient.hasParseErrors) {
      debugPrint('FIREBASE: Not syncing unparsed patient ${patient.id}');
      return false;
    }
    final uid = _owner();
    if (uid == null) return false;
    try {
      await _patients(uid).doc(patient.id).set(patient.toJson());
      debugPrint('FIREBASE: Sync Success for ${patient.id}');
      return true;
    } catch (e) {
      debugPrint('FIREBASE: Sync Error for ${patient.id}: ${_code(e)}');
      return false;
    }
  }

  /// Returns true only once Firestore confirmed the delete.
  Future<bool> deletePatient(String patientId) async {
    final uid = _owner();
    if (uid == null) return false;
    try {
      await _patients(uid).doc(patientId).delete();
      return true;
    } catch (e) {
      debugPrint('FIREBASE: Delete error for $patientId: ${_code(e)}');
      return false;
    }
  }

  /// All of the doctor's patients, or an empty list on error. Documents
  /// that fail to parse come back flagged ([Patient.hasParseErrors]).
  Future<List<Patient>> fetchAllPatients() async {
    final uid = _owner();
    if (uid == null) {
      debugPrint('FIREBASE: No matching signed-in user, skipping fetch.');
      return [];
    }
    try {
      final snapshot = await _patients(uid).get();
      debugPrint('FIREBASE: Found ${snapshot.docs.length} patients in cloud.');
      return snapshot.docs.map((doc) => Patient.fromJson(doc.data(), docId: doc.id)).toList();
    } catch (e) {
      debugPrint('FIREBASE: Fetch error: ${_code(e)}');
      return [];
    }
  }

  /// Error code only: Firestore messages can echo document contents.
  static String _code(Object e) =>
      e is FirebaseException ? 'firebase:${e.code}' : e.runtimeType.toString();
}
