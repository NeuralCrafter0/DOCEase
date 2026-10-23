import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../models/doctor.dart';
import '../services/attachments.dart';
import '../services/local_photo_store.dart';
import 'database_helper.dart';

/// The signed-in doctor's profile at `doctors/{uid}`.
///
/// With `cloudSync: false` (dev mode) Firebase is never touched: the profile
/// is a JSON string under [profileSettingKey] in the open encrypted DB and
/// the photo is a file in [LocalPhotoStore]'s profile folder.
class DoctorProvider with ChangeNotifier {
  DoctorProvider({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    bool cloudSync = true,
    LocalDatabase? localDb,
    LocalPhotoStore? photos,
  })  : _authOverride = auth,
        _firestoreOverride = firestore,
        _storageOverride = storage,
        _cloud = cloudSync,
        _localDbOverride = localDb,
        _photosOverride = photos;

  /// Settings key of the on-phone profile (dev mode).
  static const profileSettingKey = 'doctor_profile';

  final bool _cloud;
  final LocalDatabase? _localDbOverride;
  final LocalPhotoStore? _photosOverride;
  LocalDatabase get _local => _localDbOverride ?? DatabaseHelper.instance;
  LocalPhotoStore get _photos => _photosOverride ?? LocalPhotoStore.instance;

  final FirebaseAuth? _authOverride;
  final FirebaseFirestore? _firestoreOverride;
  final FirebaseStorage? _storageOverride;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseFirestore get _db => _firestoreOverride ?? FirebaseFirestore.instance;
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

  Doctor? _currentDoctor;
  bool _isLoading = true;

  String? _uid;
  Future<void>? _loading;
  int _generation = 0;

  Doctor? get currentDoctor => _currentDoctor;
  bool get isLoading => _isLoading;

  /// The id a saved profile gets: the signed-in uid, or in dev mode the
  /// on-phone owner. Null when nobody is signed in.
  String? get ownerUid => _cloud ? _auth.currentUser?.uid : _uid;

  /// The account's email to prefill the form (null in dev mode).
  String? get accountEmail => _cloud ? _auth.currentUser?.email : null;

  /// Loads [uid]'s profile. Called by SessionController once the local DB is
  /// ready; repeated calls for the same uid share one load.
  Future<void> load(String uid) {
    if (_uid == uid && _loading != null) return _loading!;
    _uid = uid;
    final gen = _generation;
    return _loading = _load(uid, gen);
  }

  /// Kept for existing callers (HomeScreen): loads for the signed-in doctor.
  Future<void> fetchDoctorProfile() async {
    final uid = ownerUid;
    if (uid == null) {
      _isLoading = false;
      notifyListeners();
      return;
    }
    await load(uid);
  }

  Future<void> _load(String uid, int gen) async {
    try {
      if (!_cloud) {
        final data = _decode(await _local.getSetting(profileSettingKey));
        if (gen != _generation) return;
        if (data != null) _currentDoctor = Doctor.fromJson(data);
      } else {
        final doc = await _db.collection('doctors').doc(uid).get();
        if (gen != _generation) return;
        final data = doc.data();
        if (doc.exists && data != null) _currentDoctor = Doctor.fromJson(data);
      }
    } catch (e) {
      debugPrint('Error fetching doctor: ${_code(e)}');
      if (gen == _generation) _loading = null; // allow a retry
    }
    if (gen != _generation) return;
    _isLoading = false;
    notifyListeners();
  }

  /// Uploads a new avatar to `doctor_profiles/{uid}/{timestamp}.{ext}` and
  /// returns its download URL, or null if the upload failed.
  ///
  /// Throws [UnsupportedAttachmentException] before uploading anything when
  /// the file is not a JPEG, PNG or WebP image, is empty, or is over 5 MiB
  /// (the limits in storage.rules). The old flat path
  /// `doctor_profiles/{uid}_{timestamp}.jpg` is denied by the new rules.
  ///
  /// Dev mode: copies the photo into the app's profile folder and returns
  /// that file path (nothing is uploaded).
  Future<String?> uploadProfileImage(File file) async {
    final uid = ownerUid;
    if (uid == null) return null;
    final type = await AttachmentPolicy.validateLocalImage(file.path,
        maxBytes: AttachmentPolicy.maxAvatarBytes);
    if (!_cloud) {
      try {
        return await _photos.keepAvatar(file.path, type);
      } catch (e) {
        debugPrint('Profile photo copy failed: ${_code(e)}');
        return null;
      }
    }
    try {
      // A new timestamped name per upload forces a fresh URL (no caching).
      final name = '${DateTime.now().millisecondsSinceEpoch}.${type.fileExtension}';
      final ref = _storage.ref().child(AttachmentPolicy.avatarFolder(uid)).child(name);
      final snapshot = await ref.putFile(file, SettableMetadata(contentType: type.contentType));
      if (snapshot.state == TaskState.success) return await ref.getDownloadURL();
      return null;
    } catch (e) {
      debugPrint('Profile image upload failed: ${_code(e)}');
      return null;
    }
  }

  /// Saves the profile with `merge: true`, so fields this form does not
  /// manage (the legacy `frequentMedicines` list during migration) survive.
  /// `id` is always the signed-in uid (the rules require it). A null
  /// `profileImageUrl` is left out so a failed avatar upload does not erase
  /// the existing photo. Returns whether the save reached Firestore.
  ///
  /// Dev mode: merges into the on-phone profile instead; after a successful
  /// save the previous local photo is deleted when it was replaced, and on
  /// a failed save the new (unreferenced) photo copy is deleted.
  Future<bool> saveDoctorProfile(Doctor doctor) async {
    final uid = ownerUid;
    if (uid == null) return false;
    if (_uid != null && _uid != uid) return false; // session switched
    final payload = {...doctor.toJson(), 'id': uid};
    if (payload['profileImageUrl'] == null) payload.remove('profileImageUrl');
    final gen = _generation;
    final oldPhoto = _currentDoctor?.profileImageUrl;
    final newPhoto = doctor.profileImageUrl;
    try {
      if (!_cloud) {
        final stored = _decode(await _local.getSetting(profileSettingKey)) ?? {};
        await _local.putSetting(profileSettingKey, jsonEncode({...stored, ...payload}));
        if (oldPhoto != null && newPhoto != null && oldPhoto != newPhoto && _photos.isAppPhoto(oldPhoto)) {
          await _photos.deleteAppPhoto(oldPhoto);
        }
      } else {
        await _db.collection('doctors').doc(uid).set(payload, SetOptions(merge: true));
      }
      if (gen != _generation) return true;
      _currentDoctor = Doctor(
        id: uid,
        title: doctor.title,
        name: doctor.name,
        email: doctor.email,
        age: doctor.age,
        mobileNumber: doctor.mobileNumber,
        specialty: doctor.specialty,
        clinicName: doctor.clinicName,
        practiceMode: doctor.practiceMode,
        profileImageUrl: doctor.profileImageUrl ?? _currentDoctor?.profileImageUrl,
      );
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Profile save failed: ${_code(e)}');
      if (!_cloud && newPhoto != null && newPhoto != oldPhoto && _photos.isAppPhoto(newPhoto)) {
        await _photos.deleteAppPhoto(newPhoto); // never referenced by a saved profile
      }
      return false;
    }
  }

  /// Forgets the current doctor (sign-out / account switch).
  void clear() {
    _generation++;
    _uid = null;
    _loading = null;
    _currentDoctor = null;
    _isLoading = true;
    notifyListeners();
  }

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null) return null;
    final v = jsonDecode(raw);
    return v is Map<String, dynamic> ? v : null;
  }

  static String _code(Object e) => e is FirebaseException ? e.code : e.runtimeType.toString();
}
