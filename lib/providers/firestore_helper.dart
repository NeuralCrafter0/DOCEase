import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/patient.dart';

class FirestoreHelper {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  Future<void> syncPatient(Patient patient) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      debugPrint('FIREBASE: Syncing patient ${patient.name}...');
      await _db.collection('doctors').doc(user.uid).collection('patients').doc(patient.id).set(patient.toJson());
      debugPrint('FIREBASE: Sync Success for ${patient.name}');
    } catch (e) { 
      debugPrint('FIREBASE: Sync Error for ${patient.name}: $e'); 
    }
  }

  Future<void> deletePatient(String patientId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await _db.collection('doctors').doc(user.uid).collection('patients').doc(patientId).delete();
    } catch (e) { debugPrint('FIREBASE: Delete error: $e'); }
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
      return snapshot.docs.map((doc) => Patient.fromJson(doc.data())).toList();
    } catch (e) { 
      debugPrint('FIREBASE: Fetch error: $e'); 
      return []; 
    }
  }
}
