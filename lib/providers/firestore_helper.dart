import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/patient.dart';

class FirestoreHelper {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Returns true only once Firestore confirmed the write. A patient that
  /// failed to parse is never written (it would overwrite the real document).
  Future<bool> syncPatient(Patient patient) async {
    if (patient.hasParseErrors) {
      debugPrint('FIREBASE: Not syncing unparsed patient ${patient.id}');
      return false;
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      debugPrint('FIREBASE: Syncing patient ${patient.id}...');
      await _db.collection('doctors').doc(user.uid).collection('patients').doc(patient.id).set(patient.toJson());
      debugPrint('FIREBASE: Sync Success for ${patient.id}');
      return true;
    } catch (e) { 
      debugPrint('FIREBASE: Sync Error for ${patient.id}: ${_code(e)}'); 
      return false;
    }
  }

  /// Returns true only once Firestore confirmed the delete.
  Future<bool> deletePatient(String patientId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    try {
      await _db.collection('doctors').doc(user.uid).collection('patients').doc(patientId).delete();
      return true;
    } catch (e) { debugPrint('FIREBASE: Delete error: ${_code(e)}'); return false; }
  }

  Future<List<Patient>> fetchAllPatients() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      debugPrint('FIREBASE: No user logged in, skipping fetch.');
      return [];
    }
    try {
      debugPrint('FIREBASE: Fetching all patients for doctor ${user.uid}...');
      final snapshot = await _db.collection('doctors').doc(user.uid).collection('patients').get();
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
