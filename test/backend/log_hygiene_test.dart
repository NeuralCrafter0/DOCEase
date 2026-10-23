// Logs must carry error codes/types and ids only: never an exception's
// message (`$e`), a stack trace, or patient data. Raw DB errors can contain
// SQL and bound arguments; Firebase messages can echo document contents.
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/log_codes.dart';
import 'package:firebase_core/firebase_core.dart';
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

/// The files whose catch blocks must log codes only.
const auditedFiles = [
  'lib/main.dart',
  'lib/providers/patient_provider.dart',
  'lib/providers/firestore_helper.dart',
  'lib/providers/doctor_provider.dart',
  'lib/providers/medicine_provider.dart',
  'lib/services/session_controller.dart',
];

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
        r'\$\{?(e|err|error|ex|s|st|stack|stackTrace|exception|patient|p|cp|doctor)\b(?!\.(id|code)\b)'
        r'|\.(name|phone|diagnosis|symptoms|prescription|notes|email|mobileNumber)\b'
        r'|\.toString\(\)|\.message\b');
    final call = RegExp(r'debugPrint\((.*?)\);', dotAll: true);
    final offenders = <String>[];
    for (final path in auditedFiles) {
      final src = File(path).readAsStringSync();
      for (final m in call.allMatches(src)) {
        final arg = m.group(1)!;
        if (forbidden.hasMatch(arg)) offenders.add('$path: debugPrint($arg)');
      }
    }
    expect(offenders, isEmpty);
  });
}
