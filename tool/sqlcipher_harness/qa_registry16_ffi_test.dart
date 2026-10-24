// Real SQLCipher via FFI + the real PatientProvider: security L-1 on #16
// 3a695b0 - the "picked this session" registry (fix plan, user 10:06).
//
// Contract: a save accepts a local photo path only if it is (a) already on
// the stored row, (b) mapped via swappedPathsFor, or (c) registered as picked
// this session. Anything else is DROPPED from the save (the save itself
// succeeds) and the file is left on disk for the sweep.
// Security's registry guards:
//   - scoped per owner AND patient (a pick for patient A / doctor A is not
//     accepted in a save for B);
//   - cleared on session end or owner change;
//   - an entry is removed once its photo is removed or swapped, so a form
//     opened before the removal can't bring it back through the registry.
//
// PENDING: the registration hook's signature is not published yet. The only
// place that names it is _register() below; everything else is behaviour.
// Until then every REG case is skipped unless QA_PENDING=true (which also
// shows today's behaviour, e.g. REG-01 fails because an unregistered path is
// accepted and uploaded).
//
// Run: QA_FFI_TEST=qa_registry16_ffi_test.dart bash tool/sqlcipher_harness/run_qa.sh
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
const uidB = 'doctorB';
final bool _pending = Platform.environment['QA_PENDING'] != 'true';
const _why = 'PENDING L-1 registry: hook signature not published yet (#16 next head / #8 picker); '
    'QA_PENDING=true to run against the guessed hook';

/// THE ONLY GUESS: update this one line when backend publishes the hook.
void _register(PatientProvider pp, String patientId, String path) =>
    (pp as dynamic).registerPickedPhoto(patientId, path);

VisitRecord visit(String id, List<String> paths, {String dx = 'd'}) => VisitRecord(
    id: id, date: DateTime(2026, 3, 1), visitType: 'Follow-up',
    symptoms: 's', diagnosis: dx, prescription: 'rx', attachmentPaths: paths);

Patient pt(String id, List<VisitRecord> h) =>
    Patient(id: id, name: 'N $id', age: '30', gender: 'Female', phone: '', history: h);

class _World {
  late Directory tmp;
  late DatabaseHelper db;
  late LocalPhotoStore photos;
  late FakeStorage storage;
  late FakeAuth auth;
  late PatientProvider provider;
  int _n = 0;

  Future<void> boot({String owner = uidA}) async {
    tmp = Directory.systemTemp.createTempSync('qa_reg16_');
    Directory(p.join(tmp.path, 'db')).createSync();
    final support = Directory(p.join(tmp.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = DatabaseHelper(keyStore: MemKeys(), opener: RecOpener(), databasesPath: () async => p.join(tmp.path, 'db'));
    await db.openFor(owner);
    await db.insertPatient(pt('pA', [visit('v1', const [])]));
    await db.insertPatient(pt('pB', [visit('w1', const [])]));
    storage = FakeStorage();
    auth = FakeAuth(owner);
    provider = PatientProvider(
        db: db, firestore: CloudFirestoreHelper(), auth: auth, storage: storage, photos: photos,
        retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(owner);
  }

  /// An app-owned, validly named JPEG in [owner]'s visit folder - exactly
  /// what the picker/copy step produces (but NOT registered by itself).
  String file({String owner = uidA}) {
    final dir = photos.visitFolderFor(owner)!;
    Directory(dir).createSync(recursive: true);
    _n++;
    final name = '0000000$_n-0000-4000-8000-00000000016b.jpg';
    return (File(p.join(dir, name))..writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(64, 1), 0xFF, 0xD9])).path;
  }

  Future<List<String>> paths(String pid, String vid) async => (await db.fetchPatientsStrict())
      .singleWhere((x) => x.id == pid).history.singleWhere((v) => v.id == vid).attachmentPaths;

  Future<void> idle() async {
    await provider.backgroundIdleForTesting();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await provider.backgroundIdleForTesting();
  }

  Future<void> dispose() async {
    provider.dispose();
    try {
      await db.close();
    } catch (_) {}
    tmp.deleteSync(recursive: true);
  }
}

void main() {
  late _World w;
  setUp(() => w = _World());
  tearDown(() => w.dispose());

  test('REG-00 positive control: a registered pick for the same owner+patient is saved and uploaded', () async {
    await w.boot();
    final l = w.file();
    _register(w.provider, 'pA', l);
    await w.provider.addRecord('pA', visit('vNew', [l]));
    await w.idle();
    expect(await w.paths('pA', 'vNew'), hasLength(1));
    expect(w.storage.uploads, hasLength(1));
  }, skip: _pending ? _why : null);

  test('REG-01 an UNREGISTERED app-owned path is dropped from the save; the save succeeds; '
      'the file is left on disk for the sweep; nothing is uploaded', () async {
    await w.boot();
    final l = w.file(); // valid name, owner folder, but never registered
    await w.provider.addRecord('pA', visit('vNew', [l]));
    await w.idle();
    expect(await w.paths('pA', 'vNew'), isEmpty, reason: 'unregistered path must be dropped');
    expect(File(l).existsSync(), isTrue, reason: 'the save never deletes; the sweep does');
    expect(w.storage.uploads, isEmpty);
  }, skip: _pending ? _why : null);

  test('REG-02 scoped per patient: a pick registered for pA is dropped from a save for pB', () async {
    await w.boot();
    final l = w.file();
    _register(w.provider, 'pA', l);
    await w.provider.addRecord('pB', visit('wNew', [l]));
    await w.idle();
    expect(await w.paths('pB', 'wNew'), isEmpty);
    expect(File(l).existsSync(), isTrue);
    expect(w.storage.uploads.keys.where((k) => k.contains('/pB/')), isEmpty);
  }, skip: _pending ? _why : null);

  test('REG-03 scoped per owner + cleared on owner change: doctor A\'s pick is not accepted '
      'after the session switches to doctor B', () async {
    await w.boot();
    final l = w.file();
    _register(w.provider, 'pA', l);
    // Session end / owner change: provider cleared, DB reopened for B.
    w.provider.clear();
    await w.db.close();
    await w.db.openFor(uidB);
    await w.db.insertPatient(pt('pA', [visit('v1', const [])])); // same patient id under B
    await w.provider.loadAndSync(uidB);
    await w.provider.addRecord('pA', visit('vNew', [l]));
    await w.idle();
    expect(await w.paths('pA', 'vNew'), isEmpty, reason: 'A\'s registry entry must not survive into B');
    expect(w.storage.uploads.keys.where((k) => k.contains(uidB)), isEmpty);
  }, skip: _pending ? _why : null);

  test('REG-04 cleared on session end (same owner signs in again): an old pick is not accepted', () async {
    await w.boot();
    final l = w.file();
    _register(w.provider, 'pA', l);
    w.provider.clear();
    await w.provider.loadAndSync(uidA);
    await w.provider.addRecord('pA', visit('vNew', [l]));
    await w.idle();
    expect(await w.paths('pA', 'vNew'), isEmpty);
    expect(File(l).existsSync(), isTrue);
  }, skip: _pending ? _why : null);

  test('REG-05 entry removed on REMOVE: pick saved, upload held, photo removed, then a stale form '
      'still holding L is saved -> L dropped, no new Storage object', () async {
    await w.boot();
    final l = w.file();
    _register(w.provider, 'pA', l);
    final hold = Completer<void>();
    w.storage.beforeUploadCompletes = (_) => hold.future; // L stays on disk (security G4b)
    await w.provider.addRecord('pA', visit('vNew', [l]));
    await w.provider.updateRecord('pA', visit('vNew', const [])); // removal
    await w.provider.updateRecord('pA', visit('vNew', [l], dx: 'stale form'));
    hold.complete();
    await w.idle();
    final got = await w.paths('pA', 'vNew');
    expect(got, isEmpty, reason: 'registry must forget a removed pick');
    expect(w.storage.uploads.keys.where((k) => !w.storage.deleted.contains(k)), isEmpty,
        reason: 'no surviving Storage object for the removed photo');
  }, skip: _pending ? _why : null);

  test('REG-06 entry removed on SWAP: after the confirmed upload a stale form holding L maps to S '
      '(no re-upload); once S is removed, the stale form cannot bring L or S back', () async {
    await w.boot();
    final l = w.file();
    _register(w.provider, 'pA', l);
    await w.provider.addRecord('pA', visit('vNew', [l]));
    await w.idle();
    final s = (await w.paths('pA', 'vNew')).single;
    expect(s, startsWith('clinical_attachments/$uidA/pA/'));
    await w.provider.updateRecord('pA', visit('vNew', [l], dx: 'stale 1')); // maps L -> S
    await w.idle();
    expect(await w.paths('pA', 'vNew'), [s]);
    expect(w.storage.uploads, hasLength(1), reason: 'no second upload of the same pick');
    await w.provider.updateRecord('pA', visit('vNew', const [])); // removal
    if (!File(l).existsSync()) File(l).writeAsBytesSync([0xFF, 0xD8, 0xFF, 0xD9]); // copy kept (scan/offline)
    await w.provider.updateRecord('pA', visit('vNew', [l], dx: 'stale 2'));
    await w.idle();
    expect(await w.paths('pA', 'vNew'), isEmpty);
    expect(w.storage.uploads, hasLength(1));
  }, skip: _pending ? _why : null);
}
