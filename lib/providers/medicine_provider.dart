import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'database_helper.dart';

/// The doctor's frequently used medicine names.
///
/// Stored at `doctors/{uid}/settings/medicines` as `{items: [...]}` (the only
/// field firestore.rules allows there). Older builds kept the list in a
/// `frequentMedicines` field on the profile document; [load] copies it over
/// once, the first time the settings document is missing.
///
/// With `cloudSync: false` (dev mode) Firebase is never touched: the list is
/// a JSON array under [localSettingKey] in the open encrypted DB.
class MedicineProvider with ChangeNotifier {
  MedicineProvider({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    bool cloudSync = true,
    LocalDatabase? localDb,
  })  : _authOverride = auth,
        _firestoreOverride = firestore,
        _cloud = cloudSync,
        _localDbOverride = localDb;

  /// Settings key of the on-phone list (dev mode).
  static const localSettingKey = 'frequent_medicines';

  final bool _cloud;
  final LocalDatabase? _localDbOverride;
  LocalDatabase get _local => _localDbOverride ?? DatabaseHelper.instance;

  final FirebaseAuth? _authOverride;
  final FirebaseFirestore? _firestoreOverride;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;
  FirebaseFirestore get _db => _firestoreOverride ?? FirebaseFirestore.instance;

  /// Limits enforced by firestore.rules (validMedicineItems).
  static const int maxItems = 2000;
  static const int maxItemLength = 200;

  List<String> _frequentMedicines = [];
  final List<String> _dosageTemplates = ['OD (1-0-0)', 'BD (1-0-1)', 'TDS (1-1-1)', 'SOS (As needed)', 'HS (Bedtime)', 'AC (Before Food)', 'PC (After Food)'];

  /// The uid whose list is loaded (or loading); null when cleared.
  String? _uid;
  Future<void>? _loading;

  /// Bumped by [clear] so a load or write started for a previous doctor
  /// never touches state after a sign-out or account switch.
  int _generation = 0;

  List<String> get frequentMedicines => _frequentMedicines;
  List<String> get dosageTemplates => _dosageTemplates;

  DocumentReference<Map<String, dynamic>> _settingsDoc(String uid) =>
      _db.collection('doctors').doc(uid).collection('settings').doc('medicines');

  /// Loads [uid]'s list. Called by SessionController once the local DB is
  /// ready; repeated calls for the same uid share one load.
  Future<void> load(String uid) {
    if (_uid == uid && _loading != null) return _loading!;
    _uid = uid;
    final gen = _generation;
    return _loading = _load(uid, gen);
  }

  /// Kept for existing callers: loads for the signed-in doctor.
  Future<void> fetchMedicines() async {
    final uid = _cloud ? _auth.currentUser?.uid : _uid;
    if (uid == null) return;
    await load(uid);
  }

  Future<void> _load(String uid, int gen) async {
    if (!_cloud) return _loadLocal(gen);
    try {
      final settings = await _settingsDoc(uid).get();
      if (gen != _generation) return;
      if (settings.exists) {
        _frequentMedicines = sanitize(settings.data()?['items']);
        notifyListeners();
        return;
      }
      // One-time migration from the legacy field on the profile document.
      final profile = await _db.collection('doctors').doc(uid).get();
      if (gen != _generation) return;
      final legacy = sanitize(profile.data()?['frequentMedicines']);
      _frequentMedicines = legacy;
      notifyListeners();
      try {
        await _settingsDoc(uid).set({'items': legacy});
      } catch (e) {
        // Keep the legacy list in memory; the copy is retried on next load.
        debugPrint('Medicines migration write failed: ${_code(e)}');
        if (gen == _generation) _loading = null;
      }
    } catch (e) {
      debugPrint('Error fetching medicines: ${_code(e)}');
      if (gen == _generation) _loading = null; // allow a retry
    }
  }

  Future<void> _loadLocal(int gen) async {
    try {
      final raw = await _local.getSetting(localSettingKey);
      if (gen != _generation) return;
      _frequentMedicines = raw == null ? [] : sanitize(jsonDecode(raw));
      notifyListeners();
    } catch (e) {
      debugPrint('Error reading medicines: ${_code(e)}');
      if (gen == _generation) _loading = null; // allow a retry
    }
  }

  Future<void> addMedicineIfNew(String med) async {
    final cleanMed = med.trim();
    if (!_isValidItem(cleanMed) || _frequentMedicines.contains(cleanMed)) return;
    if (_frequentMedicines.length >= maxItems) return;

    _frequentMedicines = [..._frequentMedicines, cleanMed];
    notifyListeners();

    if (!_cloud) {
      if (_uid == null) return; // no session yet: memory only
      final gen = _generation;
      try {
        await _local.putSetting(localSettingKey, jsonEncode(_frequentMedicines));
      } catch (e) {
        if (gen == _generation) debugPrint('Medicines save failed: ${_code(e)}');
      }
      return;
    }
    final uid = _uid ?? _auth.currentUser?.uid;
    if (uid == null || uid != _auth.currentUser?.uid) return;
    final gen = _generation;
    try {
      // Whole list, merge so nothing else on the document is touched.
      await _settingsDoc(uid).set({'items': _frequentMedicines}, SetOptions(merge: true));
    } catch (e) {
      if (gen == _generation) debugPrint('Medicines save failed: ${_code(e)}');
    }
  }

  /// Forgets the current doctor's list (sign-out / account switch).
  void clear() {
    _generation++;
    _uid = null;
    _loading = null;
    _frequentMedicines = [];
    notifyListeners();
  }

  /// Turns whatever is stored into a list the rules accept: strings only,
  /// trimmed, 1-200 characters, no line breaks, no duplicates, at most 2000.
  @visibleForTesting
  static List<String> sanitize(Object? raw) {
    if (raw is! List) return [];
    final out = <String>[];
    final seen = <String>{};
    for (final e in raw) {
      if (e is! String) continue;
      final s = e.trim();
      if (!_isValidItem(s) || !seen.add(s)) continue;
      out.add(s);
      if (out.length == maxItems) break;
    }
    return out;
  }

  static bool _isValidItem(String s) =>
      s.isNotEmpty && s.length <= maxItemLength && !s.contains('\n') && !s.contains('\r');

  static String _code(Object e) => e is FirebaseException ? e.code : e.runtimeType.toString();
}
