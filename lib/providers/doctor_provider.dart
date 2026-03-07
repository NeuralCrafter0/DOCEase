import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/doctor.dart';

class DoctorProvider with ChangeNotifier {
  Doctor? _currentDoctor;
  bool _isLoading = true;

  Doctor? get currentDoctor => _currentDoctor;
  bool get isLoading => _isLoading;

  Future<void> fetchDoctorProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('doctors').doc(user.uid).get();
        if (doc.exists) {
          _currentDoctor = Doctor.fromJson(doc.data()!);
        }
      } catch (e) {
        debugPrint('Error fetching doctor: $e');
      }
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<String?> uploadProfileImage(File file) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    
    try {
      // Use a timestamp to force URL refresh and avoid caching issues
      final String fileName = '${user.uid}_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final ref = FirebaseStorage.instance.ref().child('doctor_profiles').child(fileName);
      
      // Upload the file
      final uploadTask = await ref.putFile(file);
      if (uploadTask.state == TaskState.success) {
        return await ref.getDownloadURL();
      }
      return null;
    } catch (e) {
      debugPrint('Firebase Storage Upload error: $e');
      return null;
    }
  }

  Future<void> saveDoctorProfile(Doctor doctor) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instance.collection('doctors').doc(user.uid).set(doctor.toJson());
        _currentDoctor = doctor;
        notifyListeners();
      } catch (e) {
        debugPrint('Firestore Save error: $e');
      }
    }
  }
}
