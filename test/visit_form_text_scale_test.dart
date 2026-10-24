// Regression tests (QA, #8 at ed77169): on a 320x568 screen with large
// text, the visit form's "Photo saved" tile overflowed by 50 px at 2.0x,
// and the visit date row (older than #8) overflowed at 1.3x and 2.0x.
// Widget tests use the Ahem font, which is wider than real fonts, so these
// sizes are a stricter check than a real phone.
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
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
}

class FakeMedicineProvider extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
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
  late String present;
  late String missing;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('docease_scale_');
    storage = AttachmentStorage(ownerId: 'u1', baseDirectory: () async => base, excludeFromBackup: (_) async {});
    final dir = await storage.directory();
    present = (File('${dir.path}/present.jpg')..writeAsBytesSync(File('test/fixtures/attachments/rot6.jpg').readAsBytesSync())).path;
    missing = '${dir.path}/uploaded-meanwhile.jpg';
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  tearDown(() => base.deleteSync(recursive: true));

  Future<void> openSmall(WidgetTester t, double scale) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1.0;
    t.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(t.view.reset);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final visit = VisitRecord(id: 'v1', date: DateTime(2026, 9, 30), visitType: 'Follow-up', symptoms: 's', diagnosis: 'URTI',
        prescription: 'rx', attachmentPaths: [missing, 'clinical_attachments/u1/p1/uploaded.jpg', present]);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: EditingProvider()),
        ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider()),
      ],
      child: MaterialApp(home: AddRecordScreen(patientId: 'p1', existingRecord: visit, attachmentStorage: storage)),
    ));
    for (var i = 0; i < 100 && find.text('Photo saved').evaluate().isEmpty; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    // Bounded pumps, not pumpAndSettle: the form may keep animating.
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('320x568 at ${scale}x text: no overflow in the date row or the photo tiles', (t) async {
      await openSmall(t, scale);
      // An overflow is reported as an exception from layout.
      expect(t.takeException(), isNull);

      expect(find.text('Wednesday, 30 Sep 2026'), findsOneWidget);
      // The date stays inside its field, with the calendar icon.
      final field = t.getRect(find.ancestor(of: find.text('Wednesday, 30 Sep 2026'), matching: find.byType(Container)).first);
      final date = t.getRect(find.text('Wednesday, 30 Sep 2026'));
      expect(date.right, lessThanOrEqualTo(field.right));
      expect(date.bottom, lessThanOrEqualTo(field.bottom));

      for (final label in ['Photo saved', 'Saved to cloud']) {
        // Each tile keeps its full label for screen readers, and its text
        // stays inside the 100x120 tile.
        expect(find.bySemanticsLabel(label), findsOneWidget);
        final tile = t.getRect(find.bySemanticsLabel(label));
        expect(tile.size, const Size(100, 120));
        final text = t.getRect(find.text(label));
        expect(tile.contains(text.topLeft) && tile.contains(text.bottomRight - const Offset(0.01, 0.01)), isTrue,
            reason: '"$label" text $text inside tile $tile');
      }
    });
  }
}
