// UI redesign contract §4.3 B2 / §7 G9: the visit form neither loads nor
// sends `notes`, so updateRecord must not erase them. Inside the existing
// per-patient lock, building from the strictly read stored row:
// `record.notes == null` means "not provided" (keep the stored notes), and
// an explicit '' clears them. A refused or failed save changes nothing.
import 'dart:io';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'fakes.dart';

const doctorA = 'doctorA';

VisitRecord visit(String id, {String? notes, String diagnosis = 'd', List<String> photos = const []}) =>
    VisitRecord(
        id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
        diagnosis: diagnosis, prescription: 'p', notes: notes, bp: '120/80',
        attachmentPaths: photos);

class _Db extends MergeDb {
  /// When set, the next updatePatient throws it (nothing written).
  Object? updateThrowsOnce;
  int rowWrites = 0;
  @override
  Future<String?> updatePatient(Patient patient) async {
    final e = updateThrowsOnce;
    if (e != null) {
      updateThrowsOnce = null;
      throw e;
    }
    rowWrites++;
    return super.updatePatient(patient);
  }
}

void main() {
  late Directory root;
  late _Db db;
  late CloudFirestoreHelper remote;
  late PatientProvider provider;

  VisitRecord storedVisit(String id) => db.rows['p1']!.history.singleWhere((v) => v.id == id);
  VisitRecord shownVisit(String id) => provider.findById('p1').history.singleWhere((v) => v.id == id);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_visit_notes');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    final photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _Db()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1', history: [
      visit('v1', notes: 'allergic to penicillin', photos: const ['clinical_attachments/doctorA/p1/a.jpg']),
      visit('v2', notes: 'follow up in 2 weeks'),
      visit('v3'),
    ]);
    db.dirty['p1'] = false;
    remote = CloudFirestoreHelper();
    provider = PatientProvider(
        db: db, firestore: remote, auth: FakeAuth(doctorA), storage: FakeStorage(),
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1),
        photos: photos);
    await provider.loadAndSync(doctorA);
    await provider.backgroundIdleForTesting();
  });

  tearDown(() {
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  test('an edit without notes (the visit form) keeps the stored notes', () async {
    // Exactly what the form sends: every field but notes, which is null.
    await provider.updateRecord('p1',
        visit('v1', diagnosis: 'edited', photos: const ['clinical_attachments/doctorA/p1/a.jpg']));
    await provider.backgroundIdleForTesting();
    expect(storedVisit('v1').diagnosis, 'edited', reason: 'the edit itself is saved');
    expect(storedVisit('v1').notes, 'allergic to penicillin');
    expect(storedVisit('v1').attachmentPaths, ['clinical_attachments/doctorA/p1/a.jpg']);
    expect(shownVisit('v1').notes, 'allergic to penicillin');
    expect(storedVisit('v2').notes, 'follow up in 2 weeks', reason: 'other visits untouched');
    final pushed = remote.payloads.lastWhere((x) => x.id == 'p1');
    expect(pushed.history.singleWhere((v) => v.id == 'v1').notes, 'allergic to penicillin');
  });

  test('an explicit empty string clears the notes; a new value replaces them', () async {
    await provider.updateRecord('p1', visit('v2', notes: ''));
    expect(storedVisit('v2').notes, '');
    expect(shownVisit('v2').notes, '');
    // Cleared stays cleared: a later edit without notes keeps ''.
    await provider.updateRecord('p1', visit('v2', diagnosis: 'later'));
    expect(storedVisit('v2').notes, '');
    await provider.updateRecord('p1', visit('v1', notes: 'new note'));
    expect(storedVisit('v1').notes, 'new note');
    expect(storedVisit('v1').attachmentPaths, isEmpty, reason: 'the form removed the photo');
  });

  test('the kept notes come from the stored row read under the lock, not from memory', () async {
    // The stored row changed after memory was loaded (another writer, e.g.
    // a pull); the in-memory copy still has the old notes.
    db.rows['p1'] = testPatient('p1', history: [
      visit('v1', notes: 'stored newer', photos: const ['clinical_attachments/doctorA/p1/a.jpg']),
      visit('v2', notes: 'follow up in 2 weeks'),
      visit('v3'),
    ]);
    expect(shownVisit('v1').notes, 'allergic to penicillin');
    await provider.updateRecord('p1', visit('v1', diagnosis: 'edited'));
    expect(storedVisit('v1').notes, 'stored newer');
    expect(shownVisit('v1').notes, 'stored newer');
  });

  test('a visit stored without notes stays without notes', () async {
    await provider.updateRecord('p1', visit('v3', diagnosis: 'edited'));
    expect(storedVisit('v3').notes, isNull);
    expect(storedVisit('v3').diagnosis, 'edited');
  });

  test('refused strict read: nothing written, notes and memory unchanged', () async {
    final before = db.rows['p1'];
    final writes = db.rowWrites;
    db.fetchStrictThrows = const DbReadException(DbReadFailure.readFailed);
    await expectLater(provider.updateRecord('p1', visit('v1', notes: '', diagnosis: 'x')),
        throwsA(isA<SaveRefusedException>().having((e) => e.error, 'error', isA<DbReadException>())));
    db.fetchStrictThrows = null;
    expect(identical(db.rows['p1'], before), isTrue);
    expect(db.rowWrites, writes);
    expect(storedVisit('v1').notes, 'allergic to penicillin');
    expect(shownVisit('v1').notes, 'allergic to penicillin');
    expect(shownVisit('v1').diagnosis, 'd');
  });

  test('refused swap read: nothing written, notes unchanged', () async {
    final before = db.rows['p1'];
    db.swappedPathsThrows = const DbReadException(DbReadFailure.readFailed);
    await expectLater(provider.updateRecord('p1', visit('v1', notes: '')),
        throwsA(isA<SaveRefusedException>()));
    db.swappedPathsThrows = null;
    expect(identical(db.rows['p1'], before), isTrue);
    expect(shownVisit('v1').notes, 'allergic to penicillin');
  });

  test('failed write: stored row and memory unchanged', () async {
    final before = db.rows['p1'];
    db.updateThrowsOnce = StateError('disk full');
    await expectLater(provider.updateRecord('p1', visit('v2', notes: '', diagnosis: 'x')), throwsA(anything));
    expect(identical(db.rows['p1'], before), isTrue);
    expect(storedVisit('v2').notes, 'follow up in 2 weeks');
    expect(shownVisit('v2').notes, 'follow up in 2 weeks');
    expect(shownVisit('v2').diagnosis, 'd');
  });
}
