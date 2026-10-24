// Security #16 M-1: a save made while the startup cloud pull is in flight
// must never write a stale copy over a row the pull just stored.
//
// Every save builds from the stored row, read strictly inside the
// per-patient lock (never from the in-memory list), and the pull updates
// memory per patient inside that same lock, right after applying the row.
// Both orders are covered: the pull applies first and the save runs while
// the pull is still busy with another patient; or the save holds the lock
// and the pull waits for it. A pull whose snapshot predates a local save is
// never applied to that patient (retried with a fresh snapshot instead).
//
// Gates are hook-based (Completers), no timers.
import 'dart:async';
import 'dart:io';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'fakes.dart';

const doctorA = 'doctorA';

VisitRecord visit(String id) => VisitRecord(
    id: id, date: DateTime(2026, 1, 2), visitType: 'Consultation', symptoms: 's',
    diagnosis: 'd-$id', prescription: 'p', attachmentPaths: const []);

/// MergeDb with hook gates: hold one patient's cloud apply, or hold the
/// next local row write between the save's read and its write.
class _RaceDb extends MergeDb {
  final Map<String, Completer<void>> applyGates = {};
  final Map<String, Completer<void>> applyEntered = {};
  Completer<void>? writeEntered;
  Completer<void>? writeRelease;

  Future<void> _holdWrite() async {
    final gate = writeRelease;
    if (gate == null) return;
    writeRelease = null;
    writeEntered?.complete();
    await gate.future;
  }

  @override
  Future<bool> applyCloudPatient(Patient patient) async {
    final gate = applyGates.remove(patient.id);
    if (gate != null) {
      applyEntered[patient.id]?.complete();
      await gate.future;
    }
    return super.applyCloudPatient(patient);
  }

  @override
  Future<String?> updatePatient(Patient patient) async {
    await _holdWrite();
    return super.updatePatient(patient);
  }

  @override
  Future<String?> insertPatient(Patient patient, {bool fromCloud = false}) async {
    await _holdWrite();
    return super.insertPatient(patient, fromCloud: fromCloud);
  }
}

typedef _Op = ({String name, Future<void> Function(PatientProvider) run});

void main() {
  late Directory root;
  late _RaceDb db;
  late CloudFirestoreHelper remote;
  late PatientProvider provider;

  // The local row: one visit v1, original name. The cloud (another device)
  // has an extra visit vC and a rename.
  Patient local() => testPatient('p1', history: [visit('v1')]);
  Patient cloud() => testPatient('p1', name: 'Renamed', history: [visit('vC'), visit('v1')]);

  setUp(() async {
    root = Directory.systemTemp.createTempSync('docease_pull_race');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    final photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _RaceDb()..state = const DbReady(doctorA);
    db.rows['p1'] = local();
    db.dirty['p1'] = false;
    remote = CloudFirestoreHelper();
    provider = PatientProvider(
        db: db, firestore: remote, auth: FakeAuth(doctorA), storage: FakeStorage(), photos: photos,
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(doctorA);
    await provider.backgroundIdleForTesting();
    db.applyLog.clear();
  });

  tearDown(() {
    provider.dispose();
    root.deleteSync(recursive: true);
  });

  List<String> ids(Patient p) => [for (final r in p.history) r.id];
  Patient stored() => db.rows['p1']!;

  final ops = <_Op>[
    (name: 'addRecord', run: (pp) => pp.addRecord('p1', visit('vNew'))),
    (name: 'deleteRecord', run: (pp) => pp.deleteRecord('p1', 'v1')),
    (name: 'details save', run: (pp) => pp.updatePatientDetails('p1', phone: '+919991112222')),
  ];

  group('M-1 order 1: the pull applied p1 and is still busy (held on p2)', () {
    late Future<void> pull;
    Future<Completer<void>> pullHeldOnP2() async {
      remote.cloud = [cloud(), testPatient('p2', history: [visit('v2')])];
      final entered = Completer<void>();
      final release = Completer<void>();
      db.applyEntered['p2'] = entered;
      db.applyGates['p2'] = release;
      pull = provider.syncNowForTesting();
      await entered.future; // p1 applied; the pull now holds p2's lock
      expect(db.applyLog, ['apply:p1']);
      return release;
    }

    test('memory follows per patient, inside its lock: no end-of-pull lag', () async {
      final release = await pullHeldOnP2();
      expect(provider.findById('p1').name, 'Renamed');
      expect(ids(provider.findById('p1')), ['vC', 'v1']);
      release.complete();
      await pull;
      await provider.backgroundIdleForTesting();
      expect(ids(provider.findById('p2')), ['v2']);
    });

    for (final op in ops) {
      test('${op.name} during the pull keeps the pulled visit and rename', () async {
        final release = await pullHeldOnP2();
        await op.run(provider);
        release.complete();
        await pull;
        await provider.backgroundIdleForTesting();

        expect(stored().name, 'Renamed', reason: 'the rename is not undone');
        expect(ids(stored()), contains('vC'), reason: 'the pulled visit is not lost');
        switch (op.name) {
          case 'addRecord':
            expect(ids(stored()), ['vNew', 'vC', 'v1']);
          case 'deleteRecord':
            expect(ids(stored()), ['vC']);
          default:
            expect(ids(stored()), ['vC', 'v1']);
            expect(stored().phone, '+919991112222');
        }
        expect(ids(provider.findById('p1')), ids(stored()), reason: 'memory shows the stored row');
        expect(provider.findById('p1').name, 'Renamed');
        // What goes to Firestore is the stored row: the pulled visit stays.
        final pushed = remote.payloads.where((x) => x.id == 'p1').last;
        expect(ids(pushed), ids(stored()));
        expect(pushed.name, 'Renamed');
      });
    }

    test('all three saves during one pull: nothing pulled is lost', () async {
      final release = await pullHeldOnP2();
      await provider.addRecord('p1', visit('vNew'));
      await provider.deleteRecord('p1', 'v1');
      await provider.updatePatientDetails('p1', phone: '+919991112222');
      release.complete();
      await pull;
      await provider.backgroundIdleForTesting();
      expect(ids(stored()), ['vNew', 'vC']);
      expect(stored().name, 'Renamed');
      expect(stored().phone, '+919991112222');
      expect(ids(provider.findById('p1')), ['vNew', 'vC']);
      expect(db.rows['p2'], isNotNull, reason: 'the pull finished p2 too');
      expect(provider.findById('p2').history.single.id, 'v2');
    });
  });

  group('M-1 order 2: the save holds the lock, the pull waits for it', () {
    for (final op in ops) {
      test('${op.name} first: the pull never overwrites it', () async {
        remote.cloud = [cloud()];
        final entered = Completer<void>();
        final release = Completer<void>();
        db.writeEntered = entered;
        db.writeRelease = release;
        final save = op.run(provider);
        await entered.future; // the save read the row and holds the lock
        final pull = provider.syncNowForTesting();
        for (var i = 0; i < 200; i++) {
          await Future<void>.value();
        }
        expect(db.applyLog, isEmpty, reason: 'the pull waits for the save');
        release.complete();
        await save;
        await pull;
        await provider.backgroundIdleForTesting();

        expect(db.applyLog.where((e) => e == 'apply:p1'), isEmpty,
            reason: 'the snapshot predates the save: not applied');
        expect(stored().name, 'Asha');
        switch (op.name) {
          case 'addRecord':
            expect(ids(stored()), ['vNew', 'v1']);
          case 'deleteRecord':
            expect(ids(stored()), isEmpty);
          default:
            expect(ids(stored()), ['v1']);
            expect(stored().phone, '+919991112222');
        }
        expect(ids(provider.findById('p1')), ids(stored()));
        expect(provider.findById('p1').name, stored().name);
      });
    }
  });

  test('a snapshot fetched before a save (whose push already made the row clean) is not applied', () async {
    remote.cloud = [testPatient('p1', name: 'Renamed', history: [visit('vC'), visit('v1'), visit('vX')])];
    final fetch = Completer<List<Patient>>();
    remote.fetchGate = fetch;
    final pull = provider.syncNowForTesting();
    await Future<void>.value();
    await provider.deleteRecord('p1', 'v1'); // awaits its push: row clean again
    expect(db.dirty['p1'], isFalse, reason: 'precondition: pushed and clean');
    fetch.complete(remote.cloud);
    await pull;
    await provider.backgroundIdleForTesting();
    expect(db.applyLog.where((e) => e == 'apply:p1'), isEmpty);
    expect(ids(stored()), isEmpty, reason: 'the deleted visit does not come back');
    expect(ids(provider.findById('p1')), isEmpty);
  });

  test('source pin: no save path builds a row from the in-memory list', () {
    final src = File('lib/providers/patient_provider.dart').readAsStringSync();
    final member = RegExp(r'^  [A-Za-z_@][^\n]*?[ ]([_a-zA-Z]+)[<(]', multiLine: true);
    String body(String fn) {
      // A declaration line (no `=` before the name: not a call in an
      // expression body).
      final start = src.indexOf(RegExp('^  [^\\n=]*[ ]$fn[<(]', multiLine: true));
      expect(start, isNot(-1), reason: fn);
      final next = member.allMatches(src).firstWhere((m) => m.start > start, orElse: () => member.allMatches(src).last);
      return src.substring(start, next.start > start ? next.start : src.length);
    }

    const saves = [
      'addPatient', 'updatePatient', 'updatePatientDetails', 'deletePatient',
      '_mutateHistory', 'addRecord', 'updateRecord', 'deleteRecord',
    ];
    for (final fn in saves) {
      final b = body(fn);
      expect(b, isNot(contains('_patients')), reason: '$fn must not read the in-memory list');
      expect(b, isNot(contains('findById(')), reason: fn);
      // _byId only as an "is it loaded" check, never as a row to build from.
      for (final m in RegExp(r'_byId\([^)]*\)(.{0,8})').allMatches(b)) {
        expect(m.group(1), anyOf(startsWith(' == null'), startsWith(' != null')),
            reason: '$fn uses _byId only as a loaded check: ${m.group(0)}');
      }
    }
    final mutate = body('_mutateHistory');
    expect(mutate, contains('_storedRowFor('), reason: 'built from the strict stored row');
    expect(mutate, contains('_withHistory(stored, history)'));
    expect(body('updatePatientDetails'), contains('fetchPatientsStrict('));
    expect(body('deletePatient'), contains('fetchPatientsStrict('));
    // The pull: no list-wide overwrite; memory follows per patient in the lock.
    expect(body('_pullFromCloud'), isNot(contains('_patients =')));
    final apply = body('_applyCloud');
    expect(apply, contains('_underPatientLock('));
    expect(apply.indexOf('_db.applyCloudPatient('), lessThan(apply.indexOf('_showInMemory(cp)')));
  });
}
