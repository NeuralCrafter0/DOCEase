// Logs must carry error codes/types and ids only: never an exception's
// message (`$e`), a stack trace, or patient data. Raw DB errors can contain
// SQL and bound arguments; Firebase messages can echo document contents.
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/doctor.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/firestore_helper.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/log_codes.dart';
import 'package:docease/services/session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const secret = 'Jane Doe +919999 diagnosis:HIV key=x00';

class _ThrowingLoadDb extends MergeDb {
  @override
  Future<List<Patient>> fetchPatients() async => throw StateError(secret);
}

class _ThrowingMarkSyncedDb extends MergeDb {
  @override
  Future<bool> markSynced(String id, String version) async => throw StateError(secret);
}

class _ThrowingCloud extends CloudFirestoreHelper {
  @override
  Future<List<Patient>> fetchAllPatients() async => throw FirebaseException(
      plugin: 'cloud_firestore', code: 'unavailable', message: secret);
}

/// Every Dart file in lib/ must log codes only.
List<String> auditedFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .map((f) => f.path)
    .where((f) => f.endsWith('.dart'))
    .toList()
  ..sort();

/// Settings writes fail with a message full of patient data.
class _ThrowingSettingsDb extends MergeDb {
  _ThrowingSettingsDb() {
    state = const DbReady(kLocalOwnerId);
  }
  @override
  Future<void> putSetting(String key, String value) async => throw StateError(secret);
}

/// Every Firestore call throws a FirebaseException carrying patient data.
class _LeakyFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation i) =>
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable', message: secret);
}

void main() {
  late List<String> logs;
  late DebugPrintCallback original;

  setUp(() {
    logs = [];
    original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
  });
  tearDown(() => debugPrint = original);

  Patient patient(String id) => Patient(
      id: id, name: secret, age: '40', gender: 'Female', phone: '+919999',
      history: [], updatedAt: 'v1');

  PatientProvider make(MergeDb db, CloudFirestoreHelper remote) => PatientProvider(
      db: db..state = const DbReady('doctorA'),
      firestore: remote,
      auth: FakeAuth('doctorA'),
      storage: FakeStorage(),
      retryBaseDelay: const Duration(hours: 1),
      retryMaxDelay: const Duration(hours: 1));

  void expectClean() {
    for (final l in logs) {
      expect(l, isNot(contains('Jane')), reason: 'patient data in log: $l');
      expect(l, isNot(contains('HIV')), reason: 'patient data in log: $l');
      expect(l, isNot(contains('key=')), reason: 'raw error message in log: $l');
    }
  }

  test('errorCode never includes the exception message', () {
    expect(errorCode(StateError(secret)), 'StateError');
    expect(errorCode(FirebaseException(plugin: 'cloud_firestore', code: 'unavailable', message: secret)),
        'cloud_firestore/unavailable');
    expect(errorCode(Exception(secret)), isNot(contains('Jane')));
  });

  test('a failing local load logs only the error type', () async {
    final p = make(_ThrowingLoadDb(), CloudFirestoreHelper());
    await p.loadAndSync('doctorA');
    expect(logs, contains('Local load failed: StateError'));
    expectClean();
    p.dispose();
  });

  test('a failing cloud fetch logs only the Firebase code', () async {
    final db = MergeDb();
    db.rows['p1'] = patient('p1');
    db.dirty['p1'] = false;
    final p = make(db, _ThrowingCloud());
    await p.loadAndSync('doctorA');
    expect(logs, contains('Sync Error: cloud_firestore/unavailable'));
    expectClean();
    p.dispose();
  });

  test('a failing markSynced logs the patient id and type, not the patient', () async {
    final db = _ThrowingMarkSyncedDb();
    db.rows['p1'] = patient('p1');
    db.dirty['p1'] = true;
    db.versions['p1'] = 'v1';
    final p = make(db, CloudFirestoreHelper());
    await p.loadAndSync('doctorA');
    expect(logs, contains('markSynced failed for p1: StateError'));
    expectClean();
    p.dispose();
  });

  test('no debugPrint in the audited files interpolates an error, stack or patient field', () {
    // `$e`, `${e}`, `$err`, `$error`, `$ex`, `$s`, `$stack`, `${e.message}`,
    // `$patient`, `.name` / `.phone` / clinical fields, or `.toString()`.
    final forbidden = RegExp(
        r'\$\{?(e|err|error|ex|s|st|stack|stackTrace|exception|patient|p|cp|doctor)\b(?!\.(id|code|runtimeType|basename)\b)'
        r'|\.(name|phone|diagnosis|symptoms|prescription|notes|email|mobileNumber)\b'
        r'|\.toString\(\)|\.message\b');
    final call = RegExp(r'debugPrint\((.*?)\);', dotAll: true);
    final offenders = <String>[];
    final files = auditedFiles();
    expect(files.length, greaterThan(20), reason: 'the walk found lib/');
    var calls = 0;
    for (final f in files) {
      // Some screens are not UTF-8: read bytes so every file is scanned.
      final src = String.fromCharCodes(File(f).readAsBytesSync());
      for (final m in call.allMatches(src)) {
        calls++;
        final arg = m.group(1)!;
        if (forbidden.hasMatch(arg)) offenders.add('$f: debugPrint($arg)');
      }
      // Bare print() is never used for logging in the app.
      for (final m in RegExp(r'(^|[^\w.])print\(').allMatches(src)) {
        offenders.add('$f: print( at offset ${m.start}');
      }
      if (src.contains("import 'dart:developer'")) offenders.add('$f: dart:developer log');
    }
    expect(calls, greaterThan(50), reason: 'the scan saw the debugPrint calls');
    expect(offenders, isEmpty);
  });

  group('more providers log codes only', () {
    late Directory root;
    late LocalPhotoStore photos;
    setUp(() async {
      root = Directory.systemTemp.createTempSync('docease_logs');
      photos = LocalPhotoStore(supportDir: () async => root);
      await photos.init();
    });
    tearDown(() => root.deleteSync(recursive: true));

    Doctor doctor() => Doctor(
        id: 'x', title: 'DR', name: secret, email: 'jane@example.com', age: '40',
        mobileNumber: '+919999', specialty: 'GP', clinicName: secret, practiceMode: 'Solo Practice');

    test('a failing doctor profile save logs only the error type', () async {
      final d = DoctorProvider(
          cloudSync: false, localDb: _ThrowingSettingsDb(), photos: photos,
          auth: FakeAuth(), firestore: FakeFirestore(), storage: FakeStorage());
      await d.load(kLocalOwnerId);
      expect(await d.saveDoctorProfile(doctor()), isFalse);
      expect(logs, contains('Profile save failed: StateError'));
      expectClean();
    });

    test('a failing cloud doctor fetch logs only the Firebase code', () async {
      final d = DoctorProvider(auth: FakeAuth('doctorA'), firestore: _LeakyFirestore(), storage: FakeStorage());
      await d.load('doctorA');
      expect(logs.where((l) => l.startsWith('Error fetching doctor:')), isNotEmpty);
      expectClean();
    });

    test('a failing medicines save logs only the error type', () async {
      final m = MedicineProvider(
          cloudSync: false, localDb: _ThrowingSettingsDb(), auth: FakeAuth(), firestore: FakeFirestore());
      await m.load(kLocalOwnerId);
      await m.addMedicineIfNew('Jane Doe HIV pill');
      expect(logs, contains('Medicines save failed: StateError'));
      expectClean();
    });

    test('FirestoreHelper errors log the patient id and Firebase code only', () async {
      final h = FirestoreHelper(firestore: _LeakyFirestore(), auth: FakeAuth('doctorA'));
      await h.syncPatient(patient('p1'));
      await h.deletePatient('p1');
      await h.fetchAllPatients();
      expect(logs, contains('FIREBASE: Sync Error for p1: firebase:unavailable'));
      expect(logs, contains('FIREBASE: Delete error for p1: firebase:unavailable'));
      expect(logs, contains('FIREBASE: Fetch error: firebase:unavailable'));
      expectClean();
    });

    test('the session controller logs auth stream errors as codes', () async {
      final log = <String>[];
      final auth = StreamController<User?>.broadcast();
      final c = SessionController(
          authStateChanges: auth.stream, db: SessionDb(), patients: SpyPatients(log),
          doctor: SpyDoctor(log), medicines: SpyMedicines(log),
          platform: FakeSessionPlatform(log), observeAppLifecycle: false);
      auth.addError(FirebaseException(plugin: 'firebase_auth', code: 'network-request-failed', message: secret));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(logs, contains('Auth stream error: firebase_auth/network-request-failed'));
      expectClean();
      c.dispose();
      await auth.close();
    });
  });
}
