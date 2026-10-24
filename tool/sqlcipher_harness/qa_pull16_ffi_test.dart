// Real SQLCipher via FFI + the real PatientProvider: security M-1 on #16
// 3a695b0 (Medium). The startup cloud pull writes each row under the
// per-patient lock but refreshes the in-memory list only after the whole
// loop. A save made in that window (addRecord / deleteRecord / updateRecord /
// details save) builds from the stale in-memory copy and overwrites the
// freshly pulled row: the other device's visit vC and rename are lost
// locally and then in Firestore (syncPatient is a full-document set()).
//
// Fix contract (user 10:06): every save builds from the stored row, read
// strictly inside the per-patient lock; the pull refreshes memory per
// patient inside its lock.
//
// Run: QA_FFI_TEST=qa_pull16_ffi_test.dart bash tool/sqlcipher_harness/run_qa.sh
// Failing-first on 3a695b0: the PULL-0x cases are skipped unless
// QA_FAILING_FIRST=true. PULL-CTRL runs always (it proves the hold really
// opens the window: memory lacks vC while the DB already has it).
// Env: QA_PULL_LOOPS (default 5) iterations per order.
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'backend/fakes.dart';
import 'qa_sweep_ffi_test.dart' show RecOpener;
import 'sqlcipher_ffi_test.dart' show MemKeys;

const uidA = 'doctorA';
final bool _ff = Platform.environment['QA_FAILING_FIRST'] == 'true';
final int loops = int.tryParse(Platform.environment['QA_PULL_LOOPS'] ?? '') ?? 5;
const _why = 'M-1 (security #16 3a695b0, CONFIRMED): a save during the startup pull builds from the '
    'stale in-memory copy and overwrites the pulled row; QA_FAILING_FIRST=true until fixed';

/// Where the pull is held while the save runs.
///  heldInP1 : inside p1's apply (p1's lock held) - the save queues on the
///             lock and runs right after p1 is stored, memory not yet refreshed.
///  heldInP2 : p1 already applied, pull held inside p2's apply.
enum Order { heldInP1, heldInP2 }

class _GateDb extends DatabaseHelper {
  _GateDb({required super.keyStore, required super.opener, required super.databasesPath});
  Future<void> Function(Patient cp)? afterApplyCloud;
  @override
  Future<bool> applyCloudPatient(Patient patient) async {
    final r = await super.applyCloudPatient(patient);
    final h = afterApplyCloud;
    if (h != null) await h(patient);
    return r;
  }
}

VisitRecord visit(String id, {String dx = 'd'}) => VisitRecord(
    id: id, date: DateTime(2026, 3, 1), visitType: 'Follow-up',
    symptoms: 's', diagnosis: dx, prescription: 'rx', attachmentPaths: const []);

Patient p1(String name, List<VisitRecord> h) =>
    Patient(id: 'p1', name: name, age: '41', gender: 'Female', phone: '9800000001', history: h);
Patient p2(List<VisitRecord> h) =>
    Patient(id: 'p2', name: 'Other', age: '50', gender: 'Male', phone: '', history: h);

class _World {
  late Directory tmp;
  late _GateDb db;
  late CloudFirestoreHelper fs;
  late PatientProvider provider;
  Future<void>? sync;
  final reached = Completer<void>();
  final release = Completer<void>();

  /// Local: p1 'Asha' [v1], p2 [w1], both synced. Cloud (another device):
  /// p1 renamed 'Asha Cloud' with an extra visit vC; p2 with an extra wC.
  Future<void> boot() async {
    tmp = Directory.systemTemp.createTempSync('qa_pull16_');
    Directory(p.join(tmp.path, 'db')).createSync();
    final support = Directory(p.join(tmp.path, 'support'))..createSync();
    final photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = _GateDb(keyStore: MemKeys(), opener: RecOpener(), databasesPath: () async => p.join(tmp.path, 'db'));
    await db.openFor(uidA);
    await db.insertPatient(p1('Asha', [visit('v1')]));
    await db.insertPatient(p2([visit('w1')]));
    fs = CloudFirestoreHelper();
    provider = PatientProvider(
        db: db, firestore: fs, auth: FakeAuth(uidA), storage: FakeStorage(), photos: photos,
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(uidA); // cloud empty: nothing pulled yet
    await provider.backgroundIdleForTesting();
    expect((await db.dirtyPatientsStrict()).map((x) => x.id), isEmpty, reason: 'precondition: synced');
  }

  /// Starts a pull and returns once it is held at [order].
  Future<void> holdPull(Order order) async {
    fs.cloud = [
      p1('Asha Cloud', [visit('vC', dx: 'cloud-visit'), visit('v1')]),
      p2([visit('wC'), visit('w1')]),
    ];
    final holdAt = order == Order.heldInP1 ? 'p1' : 'p2';
    db.afterApplyCloud = (cp) async {
      if (cp.id == holdAt && !reached.isCompleted) {
        reached.complete();
        await release.future;
      }
    };
    sync = provider.syncNowForTesting();
    await reached.future;
  }

  Future<void> finish() async {
    if (!release.isCompleted) release.complete();
    await sync;
    db.afterApplyCloud = null;
    await provider.backgroundIdleForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await provider.backgroundIdleForTesting();
  }

  Future<Patient> stored() async => (await db.fetchPatientsStrict()).singleWhere((x) => x.id == 'p1');
  Patient memory() => provider.findById('p1');
  Patient? lastPush() {
    final l = fs.payloads.where((x) => x.id == 'p1');
    return l.isEmpty ? null : l.last;
  }

  Future<void> dispose() async {
    if (!release.isCompleted) release.complete();
    provider.dispose();
    try {
      await db.close();
    } catch (_) {}
    tmp.deleteSync(recursive: true);
  }
}

List<String> ids(Patient? x) => x == null ? const ['<no push>'] : [for (final v in x.history) v.id];

/// Runs [body] in the held window for every order x loops, collects every
/// bad end state, prints them and fails if any.
Future<void> inWindow(String tag, Future<void> Function(_World w) body,
    String? Function(Patient stored, Patient mem, Patient? push) check) async {
  final bad = <String>[];
  for (final order in Order.values) {
    for (var i = 0; i < loops; i++) {
      final w = _World();
      await w.boot();
      try {
        await w.holdPull(order);
        final save = body(w).then<Object?>((_) => null, onError: (Object e) => e);
        // heldInP1: the save is queued on p1's lock; let it get there first.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await w.finish();
        final err = await save;
        final s = await w.stored(), m = w.memory(), push = w.lastPush();
        final why = err != null ? 'save failed: ${err.runtimeType}' : check(s, m, push);
        if (why != null) {
          bad.add('${order.name}#$i $why | stored=${s.name}${ids(s)} memory=${m.name}${ids(m)} '
              'push=${push?.name}${ids(push)}');
        }
      } finally {
        await w.dispose();
      }
    }
  }
  // ignore: avoid_print
  print('$tag observed bad=${bad.length}/${loops * Order.values.length}${bad.isEmpty ? '' : '\n  ${bad.take(4).join('\n  ')}'}');
  expect(bad, isEmpty);
}

String? _all(Patient x, List<String> want, String name, String where) {
  final got = ids(x);
  final missing = want.where((v) => !got.contains(v)).toList();
  if (missing.isNotEmpty) return '$where lost $missing';
  if (x.name != name) return '$where name=${x.name} (want $name)';
  return null;
}

String? _three(Patient s, Patient m, Patient? push, List<String> want, String name,
    {List<String> gone = const []}) {
  for (final (x, where) in [(s, 'DB'), (m, 'memory')]) {
    final r = _all(x, want, name, where);
    if (r != null) return r;
    if (ids(x).any(gone.contains)) return '$where still has $gone';
  }
  if (push == null) return 'never pushed';
  final r = _all(push, want, name, 'push');
  if (r != null) return r;
  if (ids(push).any(gone.contains)) return 'push still has $gone';
  return null;
}

void main() {
  test('PULL-CTRL positive control (runs today): the hold opens the window - '
      'DB already has vC, memory does not', () async {
    for (final order in Order.values) {
      final w = _World();
      await w.boot();
      try {
        await w.holdPull(order);
        final s = await w.stored();
        // ignore: avoid_print
        print('PULL-CTRL ${order.name}: stored=${s.name}${ids(s)} memory=${w.memory().name}${ids(w.memory())}');
        expect(ids(s), contains('vC'), reason: 'the pull applied p1 to the DB');
        expect(ids(w.memory()), isNot(contains('vC')), reason: 'memory not refreshed yet = the M-1 window');
        await w.finish();
        // No save in the window: the pull alone must land vC + the rename everywhere.
        expect(ids(await w.stored()), containsAll(['vC', 'v1']));
        expect(w.memory().name, 'Asha Cloud');
      } finally {
        await w.dispose();
      }
    }
  });

  test('PULL-01 addRecord during the pull: vNew, vC, v1 and the cloud rename survive '
      'in the DB, in memory and in the pushed payload',
      () => inWindow('PULL-01', (w) => w.provider.addRecord('p1', visit('vNew')),
          (s, m, push) => _three(s, m, push, ['vNew', 'vC', 'v1'], 'Asha Cloud')),
      skip: _ff ? null : _why);

  test('PULL-02 deleteRecord(v1) during the pull: only v1 goes; vC and the rename survive everywhere',
      () => inWindow('PULL-02', (w) => w.provider.deleteRecord('p1', 'v1'),
          (s, m, push) => _three(s, m, push, ['vC'], 'Asha Cloud', gone: ['v1'])),
      skip: _ff ? null : _why);

  test('PULL-03 updateRecord(v1) during the pull: the edit lands; vC and the cloud rename '
      '(details part of a visit save) survive everywhere',
      () => inWindow('PULL-03', (w) => w.provider.updateRecord('p1', visit('v1', dx: 'edited')),
          (s, m, push) {
            final r = _three(s, m, push, ['vC', 'v1'], 'Asha Cloud');
            if (r != null) return r;
            for (final (x, where) in [(s, 'DB'), (m, 'memory'), (push!, 'push')]) {
              if (x.history.singleWhere((v) => v.id == 'v1').diagnosis != 'edited') return '$where lost the edit';
            }
            return null;
          }),
      skip: _ff ? null : _why);

  test('PULL-04 details rename during the pull, then a later visit save: the local rename '
      'and vC both survive everywhere', () async {
    await inWindow('PULL-04', (w) async {
      final cur = w.memory();
      await w.provider.updatePatient(Patient(
          id: 'p1', name: 'Asha Renamed', age: cur.age, gender: cur.gender, phone: cur.phone,
          history: cur.history));
    }, (s, m, push) => _three(s, m, push, ['vC', 'v1'], 'Asha Renamed'));
  }, skip: _ff ? null : _why);

  test('PULL-05 (security G5b shape) details rename in the window, pull ends, THEN addRecord: '
      'the next memory-built save does not write the old name or drop vC', () async {
    final bad = <String>[];
    for (final order in Order.values) {
      for (var i = 0; i < loops; i++) {
        final w = _World();
        await w.boot();
        try {
          await w.holdPull(order);
          final cur = w.memory();
          final rename = w.provider.updatePatient(Patient(
              id: 'p1', name: 'Asha Renamed', age: cur.age, gender: cur.gender, phone: cur.phone,
              history: cur.history)).then<Object?>((_) => null, onError: (Object e) => e);
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await w.finish();
          final err = await rename;
          await w.provider.addRecord('p1', visit('vX'));
          await w.provider.backgroundIdleForTesting();
          final s = await w.stored(), m = w.memory(), push = w.lastPush();
          final why = err != null ? 'rename failed ${err.runtimeType}'
              : _three(s, m, push, ['vX', 'vC', 'v1'], 'Asha Renamed');
          if (why != null) {
            bad.add('${order.name}#$i $why | stored=${s.name}${ids(s)} memory=${m.name}${ids(m)} push=${push?.name}${ids(push)}');
          }
        } finally {
          await w.dispose();
        }
      }
    }
    // ignore: avoid_print
    print('PULL-05 observed bad=${bad.length}/${loops * 2}${bad.isEmpty ? '' : '\n  ${bad.take(4).join('\n  ')}'}');
    expect(bad, isEmpty);
  }, skip: _ff ? null : _why);
}
