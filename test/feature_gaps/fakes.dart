// Local-only provider fakes for the feature-gap tests.
//
// They *implement* the providers instead of extending them, so no
// FirestoreHelper / FirebaseAuth / FirebaseStorage is ever constructed:
// these tests run with no Firebase app at all, like the app's dev mode.
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:flutter/foundation.dart';

class LocalPatientProvider with ChangeNotifier implements PatientProvider {
  LocalPatientProvider(this.list);
  final List<Patient> list;
  final added = <(String, VisitRecord)>[];
  final updated = <(String, VisitRecord)>[];

  @override
  List<Patient> get patients => [...list];

  @override
  Patient findById(String id) => list.firstWhere((p) => p.id == id);

  @override
  bool get isSyncing => false;

  @override
  Future<void> addRecord(String patientId, VisitRecord record) async {
    added.add((patientId, record));
    findById(patientId).history.insert(0, record);
    notifyListeners();
  }

  @override
  Future<void> updateRecord(String patientId, VisitRecord record) async {
    updated.add((patientId, record));
    final h = findById(patientId).history;
    final i = h.indexWhere((r) => r.id == record.id);
    if (i != -1) h[i] = record;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LocalMedicineProvider with ChangeNotifier implements MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];

  @override
  List<String> get dosageTemplates => const [];

  @override
  Future<void> addMedicineIfNew(String name) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class LocalDoctorProvider with ChangeNotifier implements DoctorProvider {
  @override
  Doctor? get currentDoctor => null;

  @override
  bool get isLoading => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

VisitRecord visit(
  String id,
  DateTime date, {
  String type = 'Routine',
  String diagnosis = 'Review',
  String? bp,
  String? temp,
  String? pulse,
  String? weight,
  String? sugar,
}) =>
    VisitRecord(
      id: id,
      date: date,
      visitType: type,
      symptoms: 'symptoms',
      diagnosis: diagnosis,
      prescription: 'Rx',
      bp: bp,
      temp: temp,
      pulse: pulse,
      weight: weight,
      sugar: sugar,
    );

Patient patientWith(List<VisitRecord> history, {String id = 'p1', String name = 'Asha'}) =>
    Patient(id: id, name: name, age: '54', gender: 'Female', phone: '+9199999 $id', history: history);
