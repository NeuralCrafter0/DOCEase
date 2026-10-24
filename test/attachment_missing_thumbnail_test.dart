// Regression tests for QA STALE-05: the visit's upload can finish while the
// visit form is open, which swaps the row to a Storage path and deletes the
// local file. The form still holds the local path, so its thumbnail must
// show a neutral "Photo saved" tile instead of a broken image or a raw
// error, never the path, and the remove (x) button must still work on it.
// ignore_for_file: depend_on_referenced_packages
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
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
  @override
  Future<void> updateRecord(String patientId, VisitRecord record) async => updated = record;
}

class FakeMedicineProvider extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

const tileKey = ValueKey('photo-unavailable-tile');

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
  late String present, missing;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('docease_stale_');
    storage = AttachmentStorage(ownerId: 'u1', baseDirectory: () async => base, excludeFromBackup: (_) async {});
    final dir = await storage.directory();
    final jpeg = File('test/fixtures/attachments/rot6.jpg').readAsBytesSync();
    present = (File('${dir.path}/present.jpg')..writeAsBytesSync(jpeg)).path;
    // The upload finished and deleted this local copy after the form
    // captured its path.
    missing = '${dir.path}/uploaded-meanwhile.jpg';
    patients = EditingProvider();
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  tearDown(() => base.deleteSync(recursive: true));

  VisitRecord visitWith(List<String> paths) => VisitRecord(id: 'v1', date: DateTime(2026, 3, 1), visitType: 'Follow-up',
      symptoms: 's', diagnosis: 'URTI', prescription: 'rx', attachmentPaths: paths);

  /// Image loads use real IO, which only moves on when real time and pumps
  /// alternate.
  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t, VisitRecord record, {required int tiles}) async {
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
    await settle(t, () => find.byKey(tileKey).evaluate().length >= tiles);
  }

  void expectNoPathOrRawError(WidgetTester t) {
    expect(t.takeException(), isNull, reason: 'the image error is handled, not reported');
    expect(find.textContaining(base.path), findsNothing, reason: 'the file path is never shown');
    expect(find.textContaining('uploaded-meanwhile'), findsNothing);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('Error'), findsNothing);
    expect(find.textContaining('http'), findsNothing);
  }

  testWidgets('STALE-05 a missing local photo shows the neutral "Photo saved" tile', (t) async {
    await open(t, visitWith([missing, present]), tiles: 1);

    expect(find.byKey(tileKey), findsOneWidget, reason: 'only the missing photo gets the tile');
    expect(find.text('Photo saved'), findsOneWidget);
    expect(find.descendant(of: find.byKey(tileKey), matching: find.byIcon(Icons.photo_outlined)), findsOneWidget);
    expect(find.bySemanticsLabel('Photo saved'), findsOneWidget);
    // The photo that is still on disk draws normally, and both keep their (x).
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expectNoPathOrRawError(t);
  });

  testWidgets('STALE-05 the remove (x) button still works on the "Photo saved" tile', (t) async {
    await open(t, visitWith([missing, present]), tiles: 1);

    // The (x) on the first thumbnail, which is the tile.
    final tileX = find.descendant(
      of: find.ancestor(of: find.byKey(tileKey), matching: find.byType(Stack)).first,
      matching: find.byIcon(Icons.close),
    );
    expect(tileX, findsOneWidget);
    await t.tap(tileX);
    await t.pump();

    expect(find.byKey(tileKey), findsNothing);
    expect(find.text('Photo saved'), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget, reason: 'the other photo stays');

    await t.tap(find.text('Save Clinical Record'));
    await settle(t, () => patients.updated != null && find.byType(AddRecordScreen).evaluate().isEmpty);
    expect(patients.updated!.attachmentPaths, [present]);
    expect(File(present).existsSync(), isTrue);
    expectNoPathOrRawError(t);
  });

  testWidgets('a thumbnail that fails to load from the network shows the same tile', (t) async {
    // Widget tests answer every HTTP request with 400, so this load fails.
    await open(t, visitWith(['https://storage.invalid/visit/photo.jpg']), tiles: 1);

    expect(find.byKey(tileKey), findsOneWidget);
    expect(find.text('Photo saved'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expectNoPathOrRawError(t);
  });
}
