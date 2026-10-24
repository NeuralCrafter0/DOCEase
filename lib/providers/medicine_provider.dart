import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../config/dev_mode.dart';
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
        _cloudSync = cloudSync,
        _localDbOverride = localDb;

  /// Settings key of the on-phone list (dev mode).
  static const localSettingKey = 'frequent_medicines';

  final bool _cloudSync;

  /// Cloud work only with cloudSync on and never for the dev owner.
  bool get _cloud => _cloudSync && !isLocalOwner(_uid);
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

  // DB audit #5: a failed load must never let an addition save a short
  // list over the stored one. Until a load succeeds, additions are kept in
  // memory ([_unsaved]) and merged into the stored list once it loads.
  //
  // The ONE load guard (shared with #6's removeLearnedMedicine): true only
  // after the stored list was read for the current owner this session
  // ([_onLoaded]: cloud settings, legacy profile, local setting); never set
  // by a failed read; reset by [clear] (sign-out / account switch), by a
  // failed load and by [load] for a different owner. Every write checks it.
  bool _learnedMedicinesLoaded = false;
  bool get learnedMedicinesLoaded => _learnedMedicinesLoaded;
  // UI status only (not a guard): the last read failed, as opposed to not
  // having been attempted yet.
  bool _loadFailed = false;
  final List<String> _unsaved = [];

  /// True when the stored list could not be read (until a later load
  /// succeeds). Meanwhile new medicines are suggested from memory but not
  /// saved; they are saved together with the stored list once it loads.
  bool get loadFailed => _loadFailed;
  List<String> get dosageTemplates => _dosageTemplates;

  DocumentReference<Map<String, dynamic>> _settingsDoc(String uid) =>
      _db.collection('doctors').doc(uid).collection('settings').doc('medicines');

  /// Loads [uid]'s list. Called by SessionController once the local DB is
  /// ready; repeated calls for the same uid share one load.
  Future<void> load(String uid) {
    if (_uid == uid && _loading != null) return _loading!;
    // Owner change without a clear(): nothing loaded for the old owner may
    // count as loaded (or be saved) for the new one.
    if (_uid != null && _uid != uid) clear();
    _uid = uid;
    final gen = _generation;
    return _loading = _load(uid, gen);
  }

  /// Kept for existing callers: loads for the signed-in doctor.
  Future<void> fetchMedicines() async {
    final uid = _cloud ? _auth.currentUser?.uid : _uid;
    if (uid == null || (_cloud && isLocalOwner(uid))) return; // `local` account refused
    await load(uid);
  }

  Future<void> _load(String uid, int gen) async {
    if (!_cloud) return _loadLocal(gen);
    if (isLocalOwner(uid)) return; // hard guard: no cloud fetch for the dev owner
    try {
      final settings = await _settingsDoc(uid).get();
      if (gen != _generation) return;
      if (settings.exists) {
        _onLoaded(sanitize(settings.data()?['items']));
        return;
      }
      // One-time migration from the legacy field on the profile document.
      final profile = await _db.collection('doctors').doc(uid).get();
      if (gen != _generation) return;
      final legacy = sanitize(profile.data()?['frequentMedicines']);
      final hadUnsaved = _unsaved.isNotEmpty;
      _onLoaded(legacy, persist: false); // the migration write below saves it
      try {
        await _settingsDoc(uid).set({'items': hadUnsaved ? _frequentMedicines : legacy});
      } catch (e) {
        // Keep the legacy list in memory; the copy is retried on next load.
        debugPrint('Medicines migration write failed: ${_code(e)}');
        if (gen == _generation) _loading = null;
      }
    } catch (e) {
      debugPrint('Error fetching medicines: ${_code(e)}');
      if (gen == _generation) _onLoadFailed(); // allows a retry
    }
  }

  Future<void> _loadLocal(int gen) async {
    try {
      final raw = await _local.getSetting(localSettingKey);
      if (gen != _generation) return;
      final Object? decoded = raw == null ? const <Object?>[] : jsonDecode(raw);
      // Something stored that is not a list is unreadable, not "empty".
      if (decoded is! List) throw const FormatException('not a list');
      _onLoaded(sanitize(decoded));
    } catch (e) {
      debugPrint('Error reading medicines: ${_code(e)}');
      if (gen == _generation) _onLoadFailed(); // allows a retry
    }
  }

  /// The stored list was read: use it, plus anything added while it was
  /// not loaded (then saved, unless [persist] is false).
  void _onLoaded(List<String> stored, {bool persist = true}) {
    final extra = [for (final m in _unsaved) if (!stored.contains(m)) m];
    _unsaved.clear();
    final room = maxItems - stored.length;
    _frequentMedicines = [...stored, ...extra.take(room < 0 ? 0 : room)];
    _learnedMedicinesLoaded = true;
    _loadFailed = false;
    notifyListeners();
    if (persist && extra.isNotEmpty) unawaited(_persist());
  }

  void _onLoadFailed() {
    _loading = null;
    _learnedMedicinesLoaded = false;
    _loadFailed = true;
    notifyListeners();
  }

  Future<void> addMedicineIfNew(String med) async {
    final cleanMed = med.trim();
    if (!_isValidItem(cleanMed) || _frequentMedicines.contains(cleanMed)) return;
    if (_frequentMedicines.length >= maxItems) return;

    _frequentMedicines = [..._frequentMedicines, cleanMed];
    notifyListeners();
    if (!_learnedMedicinesLoaded) {
      // Never save over a list that could not be read (DB audit #5).
      _unsaved.add(cleanMed);
      return;
    }
    await _persist();
  }

  /// Saves the whole list, only once it was loaded for this doctor.
  Future<void> _persist() async {
    if (!_learnedMedicinesLoaded) return;
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
    if (uid == null || isLocalOwner(uid) || uid != _auth.currentUser?.uid) return;
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
    _learnedMedicinesLoaded = false;
    _loadFailed = false;
    _unsaved.clear();
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

  Future<void> removeLearnedMedicine(String name) async {
    if (!_learnedMedicinesLoaded) {
      // TODO(backend): throw the medicines SaveRefusedException here.
      throw StateError('Learned medicines have not loaded; nothing was removed.');
    }
    final index = _frequentMedicines.indexOf(name);
    if (index < 0) return;
    final before = _frequentMedicines;
    _frequentMedicines = [...before]..removeAt(index);
    notifyListeners();
    final gen = _generation;
    try {
      if (!_cloud) {
        if (_uid == null) return;
        await _local.putSetting(localSettingKey, jsonEncode(_frequentMedicines));
        return;
      }
      final uid = _uid ?? _auth.currentUser?.uid;
      if (uid == null || isLocalOwner(uid) || uid != _auth.currentUser?.uid) return;
      await _settingsDoc(uid).set({'items': FieldValue.arrayRemove([name])}, SetOptions(merge: true));
    } catch (e) {
      if (gen == _generation) {
        _frequentMedicines = before;
        notifyListeners();
      }
      rethrow;
    }
  }
}

/// A learned-medicines write was refused because the stored list has not
/// been read for the current owner this session (not loaded yet, the read
/// failed, or the owner changed). Nothing was written. For #6's
/// removeLearnedMedicine (its TODO(backend)).
class LearnedMedicinesNotLoadedException implements Exception {
  const LearnedMedicinesNotLoadedException();
  @override
  String toString() => 'LearnedMedicinesNotLoadedException';
}
