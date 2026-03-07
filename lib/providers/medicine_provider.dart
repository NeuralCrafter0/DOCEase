import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class MedicineProvider with ChangeNotifier {
  List<String> _frequentMedicines = [];
  final List<String> _dosageTemplates = ['OD (1-0-0)', 'BD (1-0-1)', 'TDS (1-1-1)', 'SOS (As needed)', 'HS (Bedtime)', 'AC (Before Food)', 'PC (After Food)'];

  List<String> get frequentMedicines => _frequentMedicines;
  List<String> get dosageTemplates => _dosageTemplates;

  Future<void> fetchMedicines() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final doc = await FirebaseFirestore.instance.collection('doctors').doc(user.uid).get();
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
}
