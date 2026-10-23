import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';
import 'database_helper.dart';
import 'firestore_helper.dart';
import '../utils/patient_search.dart';

class PatientProvider with ChangeNotifier {
  List<Patient> _patients = [];
  String _searchQuery = '';
  bool _isSyncing = false;
  final FirestoreHelper _firestore = FirestoreHelper();

  List<Patient> get patients {
    // --- SMART SEARCH FIX ---
    final String cleanQuery = _searchQuery.trim().toLowerCase();
    
    if (cleanQuery.isEmpty) return [..._patients];
    
    return _patients.where((p) {
      final nameMatch = p.name.toLowerCase().contains(cleanQuery);
      final phoneMatch = phoneMatchesQuery(p.phone, cleanQuery);
      return nameMatch || phoneMatch;
    }).toList();
  }

  bool get isSyncing => _isSyncing;
  /// Every patient on this phone, ignoring the home-screen search. Use this
  /// for whole-practice views (Insights) and lookups by id.
  List<Patient> get allPatients => [..._patients];

  bool isPhoneRegistered(String phone) => _patients.any((p) => p.phone.trim() == phone.trim());

  Future<void> fetchAndSetPatients() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final localData = await DatabaseHelper.instance.fetchPatients();
    _patients = localData;
    notifyListeners();

    _performBackgroundSync();
  }

  Future<void> _performBackgroundSync() async {
    try {
      _isSyncing = true;
      notifyListeners();
      final cloudPatients = await _firestore.fetchAllPatients();
      if (cloudPatients.isNotEmpty) {
        Map<String, Patient> mergedMap = {for (var p in _patients) p.id: p};
        bool hasChanges = false;
        for (var cp in cloudPatients) {
          if (!mergedMap.containsKey(cp.id) || cp.history.length > mergedMap[cp.id]!.history.length) {
            mergedMap[cp.id] = cp;
            await DatabaseHelper.instance.insertPatient(cp);
            hasChanges = true;
          }
        }
        if (hasChanges) {
          _patients = mergedMap.values.toList();
          notifyListeners();
        }
      }
    } catch (e) { debugPrint('Sync Error: $e'); } finally { _isSyncing = false; notifyListeners(); }
  }

  void setSearchQuery(String query) { _searchQuery = query; notifyListeners(); }

  Future<void> addPatient(Patient patient) async {
    _patients.add(patient);
    notifyListeners();
    await DatabaseHelper.instance.insertPatient(patient);
    _firestore.syncPatient(patient);
  }

  Future<void> updatePatient(Patient patient) async {
    final index = _patients.indexWhere((p) => p.id == patient.id);
    if (index != -1) {
      _patients[index] = patient;
      notifyListeners();
      await DatabaseHelper.instance.insertPatient(patient);
      _firestore.syncPatient(patient);
    }
  }

  Future<void> deletePatient(String id) async {
    _patients.removeWhere((p) => p.id == id);
    notifyListeners();
    await DatabaseHelper.instance.deletePatient(id);
    await _firestore.deletePatient(id);
  }

  Future<void> addRecord(String patientId, VisitRecord record) async {
    final index = _patients.indexWhere((p) => p.id == patientId);
    if (index != -1) {
      _patients[index].history.insert(0, record);
      notifyListeners();
      await DatabaseHelper.instance.updatePatient(_patients[index]);
      _syncRecordToCloud(patientId, index, record);
    }
  }

  Future<void> _syncRecordToCloud(String patientId, int index, VisitRecord record) async {
    final urls = await _uploadAttachments(patientId, record.attachmentPaths);
    final processedRecord = VisitRecord(
      id: record.id, date: record.date, visitType: record.visitType,
      symptoms: record.symptoms, diagnosis: record.diagnosis, prescription: record.prescription,
      notes: record.notes, bp: record.bp, temp: record.temp, pulse: record.pulse, weight: record.weight, sugar: record.sugar,
      attachmentPaths: urls,
    );
    _patients[index].history[0] = processedRecord;
    await DatabaseHelper.instance.updatePatient(_patients[index]);
    await _firestore.syncPatient(_patients[index]);
    notifyListeners();
  }

  Future<List<String>> _uploadAttachments(String patientId, List<String> paths) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return paths;
    List<String> uploadedUrls = [];
    for (String path in paths) {
      if (path.startsWith('http')) { uploadedUrls.add(path); continue; }
      try {
        final ref = FirebaseStorage.instance.ref().child('clinical_attachments').child(user.uid).child(patientId).child('${const Uuid().v4()}.jpg');
        await ref.putFile(File(path));
        final url = await ref.getDownloadURL();
        uploadedUrls.add(url);
      } catch (e) { uploadedUrls.add(path); }
    }
    return uploadedUrls;
  }

  Future<void> updateRecord(String patientId, VisitRecord record) async {
    final pIndex = _patients.indexWhere((p) => p.id == patientId);
    if (pIndex != -1) {
      final rIndex = _patients[pIndex].history.indexWhere((r) => r.id == record.id);
      if (rIndex != -1) {
        _patients[pIndex].history[rIndex] = record;
        notifyListeners();
        await DatabaseHelper.instance.updatePatient(_patients[pIndex]);
        _syncUpdateRecordToCloud(patientId, pIndex, rIndex, record);
      }
    }
  }

  Future<void> _syncUpdateRecordToCloud(String patientId, int pIndex, int rIndex, VisitRecord record) async {
    final urls = await _uploadAttachments(patientId, record.attachmentPaths);
    final processedRecord = VisitRecord(
      id: record.id, date: record.date, visitType: record.visitType,
      symptoms: record.symptoms, diagnosis: record.diagnosis, prescription: record.prescription,
      notes: record.notes, bp: record.bp, temp: record.temp, pulse: record.pulse, weight: record.weight, sugar: record.sugar,
      attachmentPaths: urls,
    );
    _patients[pIndex].history[rIndex] = processedRecord;
    await DatabaseHelper.instance.updatePatient(_patients[pIndex]);
    await _firestore.syncPatient(_patients[pIndex]);
    notifyListeners();
  }

  Future<void> deleteRecord(String patientId, String recordId) async {
    final index = _patients.indexWhere((p) => p.id == patientId);
    if (index != -1) {
      _patients[index].history.removeWhere((r) => r.id == recordId);
      notifyListeners();
      await DatabaseHelper.instance.updatePatient(_patients[index]);
      await _firestore.syncPatient(_patients[index]);
    }
  }

  Patient findById(String id) => _patients.firstWhere((p) => p.id == id);
}
