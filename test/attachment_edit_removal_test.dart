// Regression tests: a saved photo the doctor removes while editing a visit
// is deleted from the owner's folder once the edit is saved, and only then
// (security re-review F8-R4).
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/utils/attachment_storage.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class EditingProvider extends PatientProvider {
  VisitRecord? updated;
  /// When set, the save waits for it (a slow local write).
  Completer<void>? pending;
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
  @override
  Future<void> updateRecord(String patientId, VisitRecord record) async {
    await pending?.future;
    updated = record;
  }
}

class FakeMedicineProvider extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async {
    await Firebase.initializeApp();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('flutter_keyboard_visibility'), MockStreamHandler.inline(onListen: (_, _) {}));
  });

  late Directory base;
  late AttachmentStorage storage;
  late EditingProvider patients;
  late String kept, removed, outside;
  late VisitRecord visit;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('docease_edit_');
    storage = AttachmentStorage(ownerId: 'u1', baseDirectory: () async => base, excludeFromBackup: (_) async {});
    final dir = await storage.directory();
    final jpeg = File('test/fixtures/attachments/rot6.jpg').readAsBytesSync();
    kept = (File('${dir.path}/kept.jpg')..writeAsBytesSync(jpeg)).path;
    removed = (File('${dir.path}/removed.jpg')..writeAsBytesSync(jpeg)).path;
    outside = (File('${base.path}/outside.jpg')..writeAsBytesSync(jpeg)).path;
    patients = EditingProvider();
    visit = VisitRecord(id: 'v1', date: DateTime(2026, 3, 1), visitType: 'Follow-up', symptoms: 's', diagnosis: 'URTI', prescription: 'rx',
        attachmentPaths: [removed, kept]);
  });
  tearDown(() => base.deleteSync(recursive: true));

  Future<void> open(WidgetTester t, VisitRecord record) async {
    t.view.physicalSize = const Size(1080, 4400);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: patients),
        ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.push(ctx, MaterialPageRoute(
              builder: (_) => AddRecordScreen(patientId: 'p1', existingRecord: record, attachmentStorage: storage),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  /// Removes the first thumbnail (the visit's first saved photo).
  Future<void> removeFirst(WidgetTester t) async {
    await t.tap(find.byIcon(Icons.close).first);
    await t.pump();
  }

  /// Real file IO only moves on when real time and pumps alternate.
  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
  }

  bool screenClosed() => find.text('open').evaluate().isNotEmpty && find.byType(AddRecordScreen).evaluate().isEmpty;

  Future<void> save(WidgetTester t) async {
    await t.tap(find.text('Save Clinical Record'));
    await settle(t, screenClosed);
  }

  testWidgets('F8-R4 removing a saved photo and saving deletes its file', (t) async {
    await open(t, visit);
    await removeFirst(t);
    await save(t);
    expect(patients.updated!.attachmentPaths, [kept]);
    expect(File(removed).existsSync(), isFalse, reason: 'removed photo deleted after save');
    expect(File(kept).existsSync(), isTrue);
  });

  testWidgets('removing a saved photo and leaving without saving keeps it', (t) async {
    await open(t, visit);
    await removeFirst(t);
    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(patients.updated, isNull);
    expect(File(removed).existsSync(), isTrue, reason: 'the stored visit still points at it');
  });

  testWidgets('the file stays until the save has finished', (t) async {
    patients.pending = Completer<void>();
    await open(t, visit);
    await removeFirst(t);
    await t.tap(find.text('Save Clinical Record'));
    for (var i = 0; i < 5; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    expect(File(removed).existsSync(), isTrue, reason: 'save still running; a refused save never gets past it');
    patients.pending!.complete();
    await settle(t, screenClosed);
    expect(File(removed).existsSync(), isFalse);
  });

  testWidgets('only files in the owner folder are deleted', (t) async {
    await open(t, VisitRecord(id: 'v1', date: DateTime(2026, 3, 1), visitType: 'Follow-up', symptoms: 's', diagnosis: 'URTI', prescription: 'rx',
        attachmentPaths: [outside, kept]));
    await removeFirst(t);
    await save(t);
    expect(patients.updated!.attachmentPaths, [kept]);
    expect(File(outside).existsSync(), isTrue, reason: 'outside the owner folder');
  });
}
