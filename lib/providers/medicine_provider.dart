import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class MedicineProvider with ChangeNotifier {
  List<String> _frequentMedicines = [];
  final List<String> _dosageTemplates = ['OD (1-0-0)', 'BD (1-0-1)', 'TDS (1-1-1)', 'SOS (As needed)', 'HS (Bedtime)', 'AC (Before Food)', 'PC (After Food)'];

  List<String> get frequentMedicines => _frequentMedicines;

  /// Whether the learned list was read from the store this session. Until
  /// then the in-memory list may be incomplete, so nothing that changes the
  /// stored list may run. Merge note: the backend adds the same guard on
  /// #13/#16; keep one flag (theirs or this one), not two.
  bool _learnedMedicinesLoaded = false;
  bool get learnedMedicinesLoaded => _learnedMedicinesLoaded;
  List<String> get dosageTemplates => _dosageTemplates;

  Future<void> fetchMedicines() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final doc = await FirebaseFirestore.instance.collection('doctors').doc(user.uid).get();
      _learnedMedicinesLoaded = true;
      if (doc.exists && doc.data()!.containsKey('frequentMedicines')) {
        _frequentMedicines = List<String>.from(doc.data()!['frequentMedicines']);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error fetching medicines: $e');
    }
  }

  Future<void> addMedicineIfNew(String med) async {
    final cleanMed = med.trim();
    if (cleanMed.isEmpty || _frequentMedicines.contains(cleanMed)) return;

    _frequentMedicines.add(cleanMed);
    notifyListeners();

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseFirestore.instance.collection('doctors').doc(user.uid).set({
        'frequentMedicines': _frequentMedicines,
      }, SetOptions(merge: true));
    }
  }

  /// Removes [name], matched exactly as stored, from the learned suggestions.
  ///
  /// Throws while the learned list has not loaded, so a partial in-memory
  /// list is never saved over the stored one. Merge note: this is a
  /// StateError because SaveRefusedException is not on main; once #13 is in,
  /// throw SaveRefusedException, the same guard as addMedicineIfNew.
  /// The cloud write removes only this entry (arrayRemove); on a failed
  /// write the entry is put back and the error rethrown.
  Future<void> removeLearnedMedicine(String name) async {
    if (!_learnedMedicinesLoaded) {
      throw StateError('Learned medicines have not loaded; nothing was removed.');
    }
    final index = _frequentMedicines.indexOf(name);
    if (index < 0) return;
    _frequentMedicines.removeAt(index);
    notifyListeners();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      await FirebaseFirestore.instance.collection('doctors').doc(user.uid).set({
        'frequentMedicines': FieldValue.arrayRemove([name]),
      }, SetOptions(merge: true));
    } catch (_) {
      _frequentMedicines.insert(index, name);
      notifyListeners();
      rethrow;
    }
  }
}
