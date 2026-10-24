// Parse fix: original ids and readable fields are kept, failures are
// flagged, and nothing is invented.
import 'package:docease/models/patient.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> visitJson({Object? id = 'r1', Object? date = '2026-01-02T10:00:00.000'}) => {
      'id': ?id,
      'date': ?date,
      'visitType': 'Routine',
      'symptoms': 'cough',
      'diagnosis': 'URTI',
      'prescription': 'Paracetamol 500mg',
      'bp': '120/80',
      'attachmentPaths': ['a.jpg'],
    };

Map<String, dynamic> patientJson({Object? id = 'p1', List<Object?>? history}) => {
      'id': ?id,
      'name': 'Asha',
      'age': '34',
      'gender': 'Female',
      'phone': '+919990000000',
      'relation': 'Self',
      'history': history ?? [visitJson()],
    };

void main() {
  test('clean patient round-trips with no flags', () {
    final p = Patient.fromJson(patientJson());
    expect(p.hasParseErrors, isFalse);
    expect(p.id, 'p1');
    expect(p.history.single.id, 'r1');
    expect(Patient.fromJson(p.toJson()).toJson(), p.toJson());
  });

  test('bad date keeps every other field and the id (PARSE-04, SYNC-09)', () {
    final p = Patient.fromJson(patientJson(history: [visitJson(date: '31/02/2026')]));
    final v = p.history.single;
    expect(v.id, 'r1');
    expect(v.dateInvalid, isTrue);
    expect(v.parseFailed, isTrue);
    expect(v.date, VisitRecord.epochFallback);
    expect(v.diagnosis, 'URTI');
    expect(v.prescription, 'Paracetamol 500mg');
    expect(v.symptoms, 'cough');
    expect(v.bp, '120/80');
    expect(v.attachmentPaths, ['a.jpg']);
    // Never written back with a placeholder: the stored value is kept.
    expect(v.toJson()['date'], '31/02/2026');
    expect(p.hasParseErrors, isTrue, reason: 'patient becomes read-only');
    expect(p.parseErrors, isEmpty, reason: 'patient fields themselves are fine');
  });

  test('missing id is flagged, never replaced by an invented one (PARSE-03)', () {
    final p = Patient.fromJson(patientJson(id: null));
    expect(p.id, '');
    expect(p.parseErrors, contains('id'));
    final v = VisitRecord.fromJson(visitJson(id: null));
    expect(v.id, '');
    expect(v.parseErrors, contains('id'));
  });

  test('Firestore doc id is used when the body has no id', () {
    final p = Patient.fromJson(patientJson(id: null), docId: 'doc42');
    expect(p.id, 'doc42');
    expect(p.parseErrors, isEmpty);
  });

  test('one bad visit leaves siblings, order and ids intact (PARSE-05)', () {
    final p = Patient.fromJson(patientJson(history: [
      visitJson(id: 'r1'),
      'garbage',
      visitJson(id: 'r3', date: 12345),
    ]));
    expect(p.history.map((v) => v.id), ['r1', '', 'r3']);
    expect(p.history[0].parseFailed, isFalse);
    expect(p.history[1].parseFailed, isTrue);
    expect(p.history[1].raw, 'garbage');
    expect(p.history[2].dateInvalid, isTrue);
    expect(p.history[2].diagnosis, 'URTI');
  });

  test('malformed patient keeps its original id and raw data (PARSE-01)', () {
    final json = patientJson(history: null)..['history'] = 'not a list';
    final p = Patient.fromJson(json);
    expect(p.id, 'p1');
    expect(p.parseErrors, contains('history'));
    expect(p.toJson(), json, reason: 'serialises what was stored');
  });

  test('wrong field types are flagged but the record is kept', () {
    final json = patientJson()..['age'] = 34;
    final p = Patient.fromJson(json);
    expect(p.age, '34');
    expect(p.parseErrors, ['age']);
    expect(p.toJson()['age'], 34);
  });

  test('updatedAt comes only from the local row and is not serialised', () {
    final p = Patient.fromJson(patientJson(), updatedAt: '1730000000000');
    expect(p.updatedAt, '1730000000000');
    expect(p.toJson().containsKey('updatedAt'), isFalse);
    expect(p.toJson().containsKey('updated_at'), isFalse);
  });
}
