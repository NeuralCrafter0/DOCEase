// Smoke tests for the plain-Dart data models.
//
// These replace the default Flutter template test, which imported a
// non-existent package (`medhistory`) and a non-existent `MyApp` widget.
// The models have no Firebase or platform-channel dependencies, so these
// tests are deterministic and run anywhere `flutter test` runs.
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Doctor', () {
    test('toJson/fromJson round-trip preserves all fields', () {
      final doctor = Doctor(
        id: 'doc-1',
        title: 'DR',
        name: 'Asha Rao',
        email: 'asha@example.com',
        age: '42',
        mobileNumber: '+910000000000',
        specialty: 'Cardiology',
        clinicName: 'Heart Care',
        practiceMode: 'Hospital',
        profileImageUrl: 'https://example.com/a.png',
      );

      final restored = Doctor.fromJson(doctor.toJson());

      expect(restored.toJson(), equals(doctor.toJson()));
    });

    test('fromJson applies defaults for missing fields', () {
      final doctor = Doctor.fromJson(<String, dynamic>{});

      expect(doctor.id, '');
      expect(doctor.title, 'MR');
      expect(doctor.practiceMode, 'Solo Practice');
      expect(doctor.profileImageUrl, isNull);
    });
  });

  group('Patient', () {
    test('toJson/fromJson round-trip preserves patient and visit history', () {
      final visit = VisitRecord(
        id: 'visit-1',
        date: DateTime.utc(2025, 1, 15, 10, 30),
        visitType: 'Follow-up',
        symptoms: 'Cough',
        diagnosis: 'Bronchitis',
        prescription: 'Rest and fluids',
        notes: 'Review in one week',
        attachmentPaths: ['scan.png'],
        bp: '120/80',
        temp: '98.6',
        pulse: '72',
        weight: '70',
        sugar: '95',
      );
      final patient = Patient(
        id: 'patient-1',
        name: 'Ravi Kumar',
        age: '35',
        gender: 'Male',
        phone: '+910000000001',
        relation: 'Self',
        history: [visit],
      );

      final restored = Patient.fromJson(patient.toJson());

      expect(restored.toJson(), equals(patient.toJson()));
      expect(restored.history.single.date, DateTime.utc(2025, 1, 15, 10, 30));
      expect(restored.history.single.attachmentPaths, ['scan.png']);
    });

    test('fromJson applies defaults for missing fields', () {
      final patient = Patient.fromJson(<String, dynamic>{'id': 'p-2'});

      expect(patient.id, 'p-2');
      expect(patient.name, 'Unknown');
      expect(patient.age, '0');
      expect(patient.gender, 'Other');
      expect(patient.relation, 'Self');
      expect(patient.history, isEmpty);
    });

    test('constructor generates distinct ids when none are given', () {
      final a = Patient(name: 'A', age: '1', gender: 'Other', phone: '');
      final b = Patient(name: 'B', age: '2', gender: 'Other', phone: '');

      expect(a.id, isNotEmpty);
      expect(a.id, isNot(equals(b.id)));
    });
  });
}
