// F16-R4 (security, Medium, #16 a8eaf9e): AddPatientScreen saves
// `history: widget.existingPatient?.history` (the copy captured when the
// screen opened) through PatientProvider.updatePatient, outside
// _historyChain. Repro on the real screen with #16's fakes (MergeDb,
// FakeStorage, CloudFirestoreHelper), no Firebase.
//
// STALE-01/02/04 FAIL on today's code (failing-first): run with
//   flutter test --dart-define=QA_FAILING_FIRST=true test/qa_sweep/stale_details_save_test.dart
// They are skipped with a reason otherwise. Drop the gate when backend's
// fix lands (updatePatient applies only detail fields to the current row
// inside the per-patient lock; visits change only via add/update/
// deleteRecord). STALE-03 must pass before and after the fix.
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_patient_screen.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/utils/attachment_storage.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../backend/fakes.dart';

const doctorA = 'doctorA';
const _ff = bool.fromEnvironment('QA_FAILING_FIRST');
const Object? _ffSkip = _ff
    ? null
    : 'failing-first (F16-R4): run with --dart-define=QA_FAILING_FIRST=true '
        'until the updatePatient details-only fix lands';

const Object? _pending16 = _ff
    ? null
    : 'pending #16 next head: a8eaf9e never calls swapAttachmentPath, so no '
        'attachment_swaps mapping is recorded on a confirmed upload (security, '
        '#10 3227338 review). Run with --dart-define=QA_FAILING_FIRST=true';

class _NoMeds extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

class _GatedStorage extends FakeStorage {
  Completer<TaskSnapshot>? gate;
  @override
  Reference ref([String? path]) => _GatedRef(this, path ?? '');
}

class _GatedRef extends FakeRef {
  _GatedRef(_GatedStorage super.storage, super.fullPath);
  _GatedStorage get _s => storage as _GatedStorage;
  @override
  Reference child(String path) =>
      _GatedRef(_s, fullPath.isEmpty ? path : '$fullPath/$path');
  @override
  UploadTask putFile(File file, [SettableMetadata? metadata]) {
    final g = _s.gate;
    if (g == null) return super.putFile(file, metadata);
    final bytes = file.readAsBytesSync();
    return FakeUploadTask(g.future.then((snap) {
      storage.uploads[fullPath] = metadata?.contentType;
      storage.objects[fullPath] = bytes;
      return snap;
    }));
  }
}

VisitRecord _visit(String id, List<String> photos, {String dx = 'd'}) =>
    VisitRecord(
        id: id,
        date: DateTime(2026, 1, id == 'v1' ? 2 : 3),
        visitType: 'Consultation',
        symptoms: 's',
        diagnosis: dx,
        prescription: 'p',
        attachmentPaths: photos);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async {
    await Firebase.initializeApp();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('flutter_keyboard_visibility'),
            MockStreamHandler.inline(onListen: (_, _) {}));
  });

  late Directory root;
  late LocalPhotoStore photos;
  late MergeDb db;
  late _GatedStorage storage;
  late PatientProvider provider;

  Future<void> boot() async {
    root = Directory.systemTemp.createTempSync('qa_stale');
    final support = Directory(p.join(root.path, 'support'))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = MergeDb()..state = const DbReady(doctorA);
    db.rows['p1'] = testPatient('p1');
    storage = _GatedStorage();
    provider = PatientProvider(
        db: db,
        firestore: CloudFirestoreHelper(),
        auth: FakeAuth(doctorA),
        storage: storage,
        photos: photos,
        retryBaseDelay: const Duration(hours: 1),
        retryMaxDelay: const Duration(hours: 1));
    await provider.loadAndSync(doctorA);
  }

  Future<void> teardown() async {
    final g = storage.gate;
    if (g != null && !g.isCompleted) g.completeError(StateError('teardown'));
    provider.dispose();
    root.deleteSync(recursive: true);
  }

  String pick() {
    final dir = photos.visitFolderFor(doctorA)!;
    Directory(dir).createSync(recursive: true);
    return (File(p.join(dir, '00000001-0000-4000-8000-0000000016a4.jpg'))
          ..writeAsBytesSync(List.filled(64, 7)))
        .path;
  }

  String pickJpeg() {
    final path = pick();
    File(path).writeAsBytesSync(
        File('test/fixtures/attachments/rot6.jpg').readAsBytesSync());
    return path;
  }

  List<String> rowPaths() =>
      db.rows['p1']!.history.expand((r) => r.attachmentPaths).toList();

  /// Opens the details screen exactly as the detail screen's edit button
  /// does: with the Patient as it is in memory right now.
  Future<void> openDetails(WidgetTester t) async {
    t.view.physicalSize = const Size(1080, 4000);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    final snapshot = provider.findById('p1');
    await t.pumpWidget(ChangeNotifierProvider<PatientProvider>.value(
      value: provider,
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.push(
                  ctx,
                  MaterialPageRoute<void>(
                      builder: (_) => AddPatientScreen(existingPatient: snapshot))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  Future<void> saveDetails(WidgetTester t, {String name = 'Renamed Patient'}) async {
    await t.enterText(find.byType(TextField).at(0), name);
    await t.tap(find.text('Save Changes'));
    await t.runAsync(flushMicrotasks);
    await t.pumpAndSettle();
    await t.runAsync(flushMicrotasks);
    expect(find.text('Save Changes'), findsNothing, reason: 'form closed');
  }

  testWidgets(
      'STALE-01 a visit saved while the details screen is open survives the details save',
      (t) async {
    await t.runAsync(boot);
    addTearDown(() => t.runAsync(teardown));
    await openDetails(t);
    await t.runAsync(() async {
      await provider.addRecord('p1', _visit('v2', const [], dx: 'new visit'));
      await flushMicrotasks();
    });
    expect(db.rows['p1']!.history.map((v) => v.id), contains('v2'),
        reason: 'precondition: v2 stored');
    await saveDetails(t);
    expect(db.rows['p1']!.name, 'Renamed Patient');
    expect(db.rows['p1']!.history.map((v) => v.id), contains('v2'),
        reason: 'LOST UPDATE: the details save wrote back the open-time history');
    expect(provider.findById('p1').history.map((v) => v.id), contains('v2'));
  }, skip: !_ff); // reason: _ffSkip

  testWidgets(
      'STALE-02 photo: upload confirms + swaps + deletes local while details are open; '
      'the details save must not put the dead local path back', (t) async {
    await t.runAsync(boot);
    addTearDown(() => t.runAsync(teardown));
    late String local;
    await t.runAsync(() async {
      storage.gate = Completer<TaskSnapshot>();
      local = pick();
      await provider.addRecord('p1', _visit('v1', [local]));
      await flushMicrotasks();
    });
    await openDetails(t); // captured history names the local file
    await t.runAsync(() async {
      storage.gate!.complete(FakeTaskSnapshot());
      for (var i = 0; i < 4; i++) {
        await flushMicrotasks();
      }
    });
    final storagePaths =
        rowPaths().where((e) => e.startsWith('clinical_attachments/')).toList();
    expect(storagePaths, hasLength(1), reason: 'precondition: swapped to Storage');
    expect(await t.runAsync(() => File(local).exists()), isFalse,
        reason: 'precondition: F8-R1 deleted the local copy');
    await saveDetails(t);
    expect(db.rows['p1']!.name, 'Renamed Patient');
    expect(rowPaths(), contains(storagePaths.single),
        reason: 'PHOTO LOST: row no longer references the uploaded object (orphaned)');
    expect(rowPaths(), isNot(contains(local)),
        reason: 'row points at a deleted local file');
    expect(storage.objects.keys, contains(storagePaths.single));
  }, skip: !_ff); // reason: _ffSkip

  testWidgets(
      'STALE-03 a stale details save keeps the NEW detail fields (guard for the fix)',
      (t) async {
    await t.runAsync(boot);
    addTearDown(() => t.runAsync(teardown));
    await openDetails(t);
    await t.runAsync(() async {
      await provider.addRecord('p1', _visit('v2', const []));
      await flushMicrotasks();
    });
    await t.enterText(find.byType(TextField).at(1), '41');
    await saveDetails(t, name: 'Fresh Name');
    final r = db.rows['p1']!;
    expect(r.name, 'Fresh Name');
    expect(r.age, '41');
    expect(provider.findById('p1').name, 'Fresh Name');
  });

  test('STALE-04 contract: updatePatient never changes visits (only add/update/deleteRecord do)',
      () async {
    await boot();
    addTearDown(teardown);
    await provider.addRecord('p1', _visit('v2', const []));
    await flushMicrotasks();
    final current = provider.findById('p1');
    final stale = Patient(
        id: current.id,
        name: 'Details Only',
        age: current.age,
        gender: current.gender,
        phone: current.phone,
        history: const []); // a caller's (stale or empty) history
    await provider.updatePatient(stale);
    await flushMicrotasks();
    expect(db.rows['p1']!.name, 'Details Only');
    expect(db.rows['p1']!.history.map((v) => v.id), contains('v2'),
        reason: 'updatePatient must ignore the caller history');
  }, skip: _ffSkip);

  testWidgets(
      'STALE-05 visit edit form open while THAT visit\'s upload swaps + deletes local: '
      'saving the edit must keep the photo (Storage path) and the edit', (t) async {
    await t.runAsync(boot);
    addTearDown(() => t.runAsync(teardown));
    late String local;
    await t.runAsync(() async {
      storage.gate = Completer<TaskSnapshot>();
      local = pickJpeg();
      await provider.addRecord('p1', _visit('v1', [local], dx: 'dx-old'));
      await flushMicrotasks();
    });
    final captured =
        provider.findById('p1').history.singleWhere((v) => v.id == 'v1');
    final pickStore = AttachmentStorage(
        ownerId: doctorA,
        baseDirectory: () async => root,
        excludeFromBackup: (_) async {});
    t.view.physicalSize = const Size(1080, 4400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: provider),
        ChangeNotifierProvider<MedicineProvider>.value(value: _NoMeds()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.push(
                ctx,
                MaterialPageRoute<void>(
                    builder: (_) => AddRecordScreen(
                        patientId: 'p1',
                        existingRecord: captured,
                        attachmentStorage: pickStore))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await t.runAsync(() async {
      storage.gate!.complete(FakeTaskSnapshot());
      for (var i = 0; i < 4; i++) {
        await flushMicrotasks();
      }
    });
    final sp = rowPaths().where((e) => e.startsWith('clinical_attachments/')).toList();
    expect(sp, hasLength(1), reason: 'precondition: swapped');
    expect(await t.runAsync(() => File(local).exists()), isFalse,
        reason: 'precondition: local deleted');
    await t.enterText(
        find.ancestor(of: find.text('dx-old'), matching: find.byType(TextField)),
        'dx-new');
    await t.tap(find.text('Save Clinical Record'));
    for (var i = 0; i < 40; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    final v1 = db.rows['p1']!.history.singleWhere((v) => v.id == 'v1');
    final snack = find.byType(SnackBar).evaluate().isEmpty
        ? '-'
        : (find.descendant(of: find.byType(SnackBar), matching: find.byType(Text))
                .evaluate()
                .map((e) => (e.widget as Text).data)
                .join(' | '));
    // ignore: avoid_print
    print('STALE-05 observed: dx=${v1.diagnosis} paths=${v1.attachmentPaths.map((e) => e.startsWith('clinical_attachments/') ? 'STORAGE' : (e == local ? 'DEAD-LOCAL' : e))} '
        'formOpen=${find.byType(AddRecordScreen).evaluate().isNotEmpty} snack=$snack');
    expect(v1.attachmentPaths, isNot(contains(local)),
        reason: 'row points at a deleted local file');
    expect(v1.attachmentPaths, contains(sp.single),
        reason: 'PHOTO LOST from the visit (Storage object orphaned)');
    expect(v1.diagnosis, 'dx-new', reason: 'the doctor\'s visit edit was not saved');
  }, skip: !_ff); // reason: _ffSkip

  test('STALE-06 (pending #16) a confirmed upload records the swap through the DB '
      '(swapAttachmentPath), so a stale pre-upload whole-row save keeps S', () async {
    await boot();
    addTearDown(teardown);
    storage.gate = Completer<TaskSnapshot>();
    final local = pickJpeg();
    await provider.addRecord('p1', _visit('v1', [local]));
    await flushMicrotasks();
    final preUpload = provider.findById('p1'); // holds L
    storage.gate!.complete(FakeTaskSnapshot());
    for (var i = 0; i < 4; i++) {
      await flushMicrotasks();
    }
    // ignore: avoid_print
    print('STALE-06 observed: swapCalls=${db.log.where((l) => l.startsWith('swap:')).toList()} '
        'mappings=${db.swaps} row=${rowPaths()}');
    expect(db.log.where((l) => l == 'swap:p1'), isNotEmpty,
        reason: 'the provider never called swapAttachmentPath');
    expect(db.swaps['p1'], isNotNull, reason: 'no attachment_swaps mapping recorded');
    final s = rowPaths().singleWhere((e) => e.startsWith('clinical_attachments/'));
    await db.updatePatient(preUpload); // DB-level stale whole-row save
    expect(rowPaths(), [s], reason: 'stale pre-upload save put the local path back');
  }, skip: _pending16);
}
