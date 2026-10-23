import 'dart:math' show min;
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/patient.dart';
import 'database_helper.dart';
import 'firestore_helper.dart';

class PatientProvider with ChangeNotifier {
  List<Patient> _patients = [];
  String _searchQuery = '';
  bool _isSyncing = false;
  final LocalDatabase _db;
  final FirestoreHelper _firestore;

  /// Defaults to the real SQLCipher database and Firestore; tests inject fakes.
  PatientProvider({LocalDatabase? db, FirestoreHelper? firestore})
      : _db = db ?? DatabaseHelper.instance,
        _firestore = firestore ?? FirestoreHelper();

  List<Patient> get patients {
    // --- SMART SEARCH FIX ---
    final String cleanQuery = _searchQuery.trim().toLowerCase();
    
    if (cleanQuery.isEmpty) return [..._patients];
    
    return _patients.where((p) {
      final nameMatch = p.name.toLowerCase().contains(cleanQuery);
      final phoneMatch = p.phone.contains(cleanQuery);
      return nameMatch || phoneMatch;
    }).toList();
  }

  bool get isSyncing => _isSyncing;

  bool isPhoneRegistered(String phone) => _patients.any((p) => p.phone.trim() == phone.trim());

  Future<void> fetchAndSetPatients() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final localData = await _db.fetchPatients();
    _patients = localData;
    notifyListeners();

    _performBackgroundSync();
  }

  Future<void> _performBackgroundSync() async {
    // Never read or merge cloud data unless the local DB is open and ready.
    if (_db.state is! DbReady) return;
    try {
      _isSyncing = true;
      notifyListeners();
      final cloudPatients = await _firestore.fetchAllPatients();
      if (cloudPatients.isNotEmpty) {
        Map<String, Patient> mergedMap = {for (var p in _patients) p.id: p};
        bool hasChanges = false;
        for (var cp in cloudPatients) {
          // A doc that failed to parse is skipped: never stored or re-synced.
          // Likewise never overwrite a local row that failed to parse.
          if (cp.hasParseErrors || (mergedMap[cp.id]?.hasParseErrors ?? false)) {
            debugPrint('Sync: skipping unparsed patient ${cp.id}');
            continue;
          }
          if (!mergedMap.containsKey(cp.id) || cp.history.length > mergedMap[cp.id]!.history.length) {
            mergedMap[cp.id] = cp;
            await _db.insertPatient(cp, fromCloud: true);
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
    _ensureWritable(patient);
    _patients.add(patient);
    notifyListeners();
    final String? version;
    try {
      version = await _db.insertPatient(patient);
    } on UnsyncedCounterException {
      // Save refused (secure storage failing): don't show it as saved.
      _patients.removeWhere((p) => identical(p, patient));
      notifyListeners();
      rethrow;
    }
    _pushToCloud(patient, version);
  }

  /// Uploads [patient]; marks the local row clean only after Firestore
  /// confirmed the write and only if no newer local write happened since.
  Future<bool> _pushToCloud(Patient patient, String? version) async {
    final ok = await _firestore.syncPatient(patient);
    if (ok && version != null) await _db.markSynced(patient.id, version);
    return ok;
  }

  /// Patients with unreadable records are read-only: saving them would
  /// overwrite the stored data with placeholders.
  void _ensureWritable(Patient patient) {
    if (patient.hasParseErrors) throw UnreadablePatientException(patient.id);
  }

  Future<void> updatePatient(Patient patient) async {
    final index = _patients.indexWhere((p) => p.id == patient.id);
    if (index != -1) {
      _ensureWritable(_patients[index]);
      _ensureWritable(patient);
      final previous = _patients[index];
      _patients[index] = patient;
      notifyListeners();
      final String? version;
      try {
        version = await _db.insertPatient(patient);
      } on UnsyncedCounterException {
        _patients[index] = previous;
        notifyListeners();
        rethrow;
      }
      _pushToCloud(patient, version);
    }
  }

  Future<void> deletePatient(String id) async {
    final index = _patients.indexWhere((p) => p.id == id);
    final removed = index == -1 ? null : _patients[index];
    _patients.removeWhere((p) => p.id == id);
    notifyListeners();
    void restore() {
      if (removed != null) {
        _patients.insert(min(index, _patients.length), removed);
        notifyListeners();
      }
    }

    // Tombstone first, so a failed cloud delete is retried, never undone.
    // Refused (nothing recorded locally): restore, and don't touch the cloud.
    try {
      await _db.markPendingDelete(id);
    } catch (_) {
      restore();
      rethrow;
    }
    if (await _firestore.deletePatient(id)) await _db.clearPendingDelete(id);
  }

  Future<void> addRecord(String patientId, VisitRecord record) async {
    final index = _patients.indexWhere((p) => p.id == patientId);
    if (index != -1) {
      _ensureWritable(_patients[index]);
      _patients[index].history.insert(0, record);
      notifyListeners();
      await _db.updatePatient(_patients[index]);
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
    final version = await _db.updatePatient(_patients[index]);
    await _pushToCloud(_patients[index], version);
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
        _ensureWritable(_patients[pIndex]);
        _patients[pIndex].history[rIndex] = record;
        notifyListeners();
        await _db.updatePatient(_patients[pIndex]);
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
    final version = await _db.updatePatient(_patients[pIndex]);
    await _pushToCloud(_patients[pIndex], version);
    notifyListeners();
  }

  Future<void> deleteRecord(String patientId, String recordId) async {
    final index = _patients.indexWhere((p) => p.id == patientId);
    if (index != -1) {
      _ensureWritable(_patients[index]);
      _patients[index].history.removeWhere((r) => r.id == recordId);
      notifyListeners();
      final version = await _db.updatePatient(_patients[index]);
      await _pushToCloud(_patients[index], version);
    }
  }

  Patient findById(String id) => _patients.firstWhere((p) => p.id == id);

  /// Runs one background sync now (tests only; no Firebase sign-in check).
  @visibleForTesting
  Future<void> syncNowForTesting() => _performBackgroundSync();
}
