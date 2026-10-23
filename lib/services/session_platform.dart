import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../providers/firestore_settings.dart';

/// Whether the signed-in user may use the app's cloud data. Mirrors the
/// `isApprovedDoctor()` gate in firestore.rules / storage.rules.
enum ApprovalStatus {
  /// Verified email and an `approvedDoctors/{uid}` entry exists.
  approved,

  /// Verified email, but no `approvedDoctors/{uid}` entry (waiting for an
  /// admin).
  notApproved,

  /// The account's email address is not verified yet.
  emailNotVerified,

  /// Could not be checked (offline or server error).
  unknown,
}

/// Everything SessionController needs from Firebase, Google Sign-In, the
/// Flutter image cache and secure storage, behind one seam so the
/// controller can be unit-tested without any plugin.
abstract class SessionPlatform {
  /// Reloads [user], checks the verified-email claim and reads
  /// `approvedDoctors/{uid}` from the server.
  Future<ApprovalStatus> checkApproval(User user);

  /// Ids of the doctor's patients in Firestore, or null if they could not
  /// be fetched.
  Future<Set<String>?> cloudPatientIds(String uid);

  Future<void> signOutFirebase();
  Future<void> signOutGoogle();

  /// Drops Firestore's local cache: terminate, clearPersistence, then
  /// re-apply the no-persistence settings so the next use gets a fresh
  /// instance.
  Future<void> clearFirestoreCache();

  /// Drops decoded images (avatars, attachments) of the previous doctor.
  void clearImageCache();

  Future<String?> readFlag(String key);
  Future<void> writeFlag(String key, String value);
  Future<void> deleteFlag(String key);
}

class FirebaseSessionPlatform implements SessionPlatform {
  FirebaseSessionPlatform({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FlutterSecureStorage? secureStorage,
    GoogleSignIn? googleSignIn,
  })  : _authOverride = auth,
        _firestoreOverride = firestore,
        _secure = secureStorage ?? const FlutterSecureStorage(),
        _googleOverride = googleSignIn;

  final FirebaseAuth? _authOverride;
  final FirebaseFirestore? _firestoreOverride;
  final FlutterSecureStorage _secure;
  final GoogleSignIn? _googleOverride;

  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseFirestore get _db => _firestoreOverride ?? FirebaseFirestore.instance;
  GoogleSignIn get _google => _googleOverride ?? GoogleSignIn.instance;

  @override
  Future<ApprovalStatus> checkApproval(User user) async {
    var current = user;
    try {
      await user.reload();
      current = _auth.currentUser ?? user;
    } catch (_) {
      // Offline: fall back to the cached user.
    }
    if (current.uid != user.uid) return ApprovalStatus.unknown;
    if (!current.emailVerified) return ApprovalStatus.emailNotVerified;
    try {
      // The rules read email_verified from the ID token; refresh it so a
      // just-verified address is honoured.
      await current.getIdToken(true);
    } catch (_) {
      return ApprovalStatus.unknown;
    }
    try {
      final doc = await _db
          .collection('approvedDoctors')
          .doc(current.uid)
          .get(const GetOptions(source: Source.server));
      return doc.exists ? ApprovalStatus.approved : ApprovalStatus.notApproved;
    } on FirebaseException catch (e) {
      return e.code == 'permission-denied'
          ? ApprovalStatus.notApproved
          : ApprovalStatus.unknown;
    } catch (_) {
      return ApprovalStatus.unknown;
    }
  }

  @override
  Future<Set<String>?> cloudPatientIds(String uid) async {
    try {
      final snap = await _db
          .collection('doctors')
          .doc(uid)
          .collection('patients')
          .get(const GetOptions(source: Source.server));
      return snap.docs.map((d) => d.id).toSet();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> signOutFirebase() => _auth.signOut();

  @override
  Future<void> signOutGoogle() async {
    try {
      await _google.signOut();
    } catch (_) {
      // Not signed in with Google, or plugin unavailable.
    }
  }

  @override
  Future<void> clearFirestoreCache() async {
    final fs = _db;
    try {
      // Persistence is off, so pending writes are only in memory; give them
      // a moment to land before the instance is torn down. Unconfirmed
      // changes stay dirty in the local DB and are retried next session.
      await fs.waitForPendingWrites().timeout(const Duration(seconds: 3));
    } catch (_) {}
    await fs.terminate();
    await fs.clearPersistence();
    // FlutterFire recreates the native instance on next use; re-apply the
    // settings before anything touches it again.
    configureFirestoreForEncryptedLocalStore(fs);
  }

  @override
  void clearImageCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  }

  @override
  Future<String?> readFlag(String key) => _secure.read(key: key);

  @override
  Future<void> writeFlag(String key, String value) => _secure.write(key: key, value: value);

  @override
  Future<void> deleteFlag(String key) => _secure.delete(key: key);
}

/// Dev mode (kDevMode): no Firebase, Google Sign-In or secure-storage flags.
/// Everyone is "approved"; sign-out and cache clears do nothing.
class LocalOnlySessionPlatform implements SessionPlatform {
  final Map<String, String> _flags = {};

  @override
  Future<ApprovalStatus> checkApproval(User user) async => ApprovalStatus.approved;
  @override
  Future<Set<String>?> cloudPatientIds(String uid) async => null;
  @override
  Future<void> signOutFirebase() async {}
  @override
  Future<void> signOutGoogle() async {}
  @override
  Future<void> clearFirestoreCache() async {}
  @override
  void clearImageCache() {}
  @override
  Future<String?> readFlag(String key) async => _flags[key];
  @override
  Future<void> writeFlag(String key, String value) async => _flags[key] = value;
  @override
  Future<void> deleteFlag(String key) async => _flags.remove(key);
}
