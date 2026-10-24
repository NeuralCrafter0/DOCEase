// Widget tests for the clinical photo picker on the Clinical Note screen.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/utils/attachment_processor.dart';
import 'package:docease/utils/pick_registry.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:provider/provider.dart';

const fx = 'test/fixtures/attachments';

class FakePicker extends ImagePickerPlatform {
  List<XFile> gallery = [];
  XFile? camera;
  PlatformException? error;
  final calls = <String>[];

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    calls.add('single:${source.name}');
    if (error != null) throw error!;
    return camera;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async {
    calls.add('multi');
    if (error != null) throw error!;
    return gallery;
  }
}

class RecordingPatientProvider extends PatientProvider {
  VisitRecord? added;
  /// `patientId path` per registration. On a merge with #16 this overrides
  /// its real PatientProvider.registerPickedAttachment, so a signature
  /// change there breaks the build instead of silently skipping the call.
  final registered = <String>[];
  // ignore: annotate_overrides
  void registerPickedAttachment({required String patientId, required String localPath}) => registered.add('$patientId $localPath');
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
  @override
  Future<void> addRecord(String patientId, VisitRecord record) async => added = record;
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
    // flutter_typeahead listens for keyboard visibility.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(const EventChannel('flutter_keyboard_visibility'), MockStreamHandler.inline(onListen: (_, __) {}));
  });

  late FakePicker picker;
  late RecordingPatientProvider patients;
  late Directory out;

  setUp(() {
    picker = FakePicker();
    ImagePickerPlatform.instance = picker;
    patients = RecordingPatientProvider();
    out = Directory.systemTemp.createTempSync('docease_pick_');
  });
  tearDown(() => out.deleteSync(recursive: true));

  List<File> outFiles() => out.listSync().whereType<File>().toList();

  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pump();
  }

  Future<void> open(WidgetTester t) async {
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
              builder: (_) => AddRecordScreen(patientId: 'p1', attachmentProcessor: AttachmentProcessor(outputDirectory: () async => out)),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
  }

  Finder thumbnails() => find.descendant(of: find.byType(ListView), matching: find.byType(Image));

  Future<void> tapAndProcess(WidgetTester t, String label, {int expectFiles = 0}) async {
    await t.tap(find.text(label));
    await t.pump();
    await settle(t, () => find.text('Preparing photo...').evaluate().isEmpty && outFiles().length >= expectFiles);
  }

  Future<void> save(WidgetTester t) async {
    // fix/form-validation makes the diagnosis required; fill it so a save
    // goes through both alone and with that branch merged.
    final diagnosis = find.byWidgetPredicate((w) =>
        w is TextField && (w.decoration?.hintText == 'Diagnosis' || w.decoration?.labelText == 'Diagnosis'));
    await t.enterText(diagnosis, 'URTI');
    await t.tap(find.text('Save Clinical Record'));
    await t.pumpAndSettle();
  }

  testWidgets('gallery photos (PNG, GIF, WebP) are attached as .jpg JPEG files', (t) async {
    picker.gallery = [XFile('$fx/alpha.png'), XFile('$fx/img.gif'), XFile('$fx/img.webp')];
    await open(t);
    expect(find.text('Attachments'), findsOneWidget);
    await tapAndProcess(t, 'Gallery', expectFiles: 3);
    expect(picker.calls, ['multi']);
    expect(thumbnails(), findsNWidgets(3));
    await save(t);
    final paths = patients.added!.attachmentPaths;
    expect(paths, hasLength(3));
    for (final path in paths) {
      expect(path, endsWith('.jpg'));
      expect(File(path).parent.path, out.path);
      final b = File(path).readAsBytesSync();
      expect([b[0], b[1]], [0xFF, 0xD8]);
    }
  });

  testWidgets('camera photo is attached as .jpg', (t) async {
    picker.camera = XFile('$fx/rot6.jpg');
    await open(t);
    await tapAndProcess(t, 'Camera', expectFiles: 1);
    expect(picker.calls, ['single:camera']);
    await save(t);
    expect(patients.added!.attachmentPaths.single, endsWith('.jpg'));
    expect(patients.added!.attachmentPaths.single, isNot('$fx/rot6.jpg'));
  });

  testWidgets('an unsupported file shows a clear message and nothing is attached', (t) async {
    picker.gallery = [XFile('$fx/notes.pdf')];
    await open(t);
    await tapAndProcess(t, 'Gallery');
    expect(find.textContaining("isn't a photo DOCEase can read, so it wasn't added"), findsOneWidget);
    expect(thumbnails(), findsNothing);
    expect(outFiles(), isEmpty);
    await save(t);
    expect(patients.added!.attachmentPaths, isEmpty);
  });

  testWidgets('mixed pick keeps the good photo and reports the bad one', (t) async {
    picker.gallery = [XFile('$fx/alpha.png'), XFile('$fx/notes.pdf')];
    await open(t);
    await tapAndProcess(t, 'Gallery', expectFiles: 1);
    expect(find.textContaining("1 of 2 photos weren't added"), findsOneWidget);
    await save(t);
    expect(patients.added!.attachmentPaths, hasLength(1));
    expect(patients.added!.attachmentPaths.single, endsWith('.jpg'));
  });

  testWidgets('camera permission denied explains how to fix it', (t) async {
    picker.error = PlatformException(code: 'camera_access_denied');
    await open(t);
    await tapAndProcess(t, 'Camera');
    expect(find.textContaining('Camera access is off for DOCEase'), findsOneWidget);
    expect(thumbnails(), findsNothing);
  });

  testWidgets('cancelling the camera does nothing', (t) async {
    await open(t);
    await tapAndProcess(t, 'Camera');
    expect(find.byType(SnackBar), findsNothing);
    expect(thumbnails(), findsNothing);
  });

  testWidgets('removing a new photo deletes its file', (t) async {
    picker.gallery = [XFile('$fx/alpha.png')];
    await open(t);
    await tapAndProcess(t, 'Gallery', expectFiles: 1);
    await t.tap(find.byIcon(Icons.close));
    await settle(t, () => outFiles().isEmpty);
    expect(thumbnails(), findsNothing);
    expect(outFiles(), isEmpty);
  });

  testWidgets('leaving without saving deletes new photo files; saving keeps them', (t) async {
    picker.gallery = [XFile('$fx/alpha.png')];
    await open(t);
    await tapAndProcess(t, 'Gallery', expectFiles: 1);
    // Let the thumbnail finish loading before the file is deleted.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    final nav = t.state<NavigatorState>(find.byType(Navigator));
    nav.pop();
    await t.pumpAndSettle();
    await settle(t, () => outFiles().isEmpty);
    expect(outFiles(), isEmpty);
    expect(patients.added, isNull);

    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await tapAndProcess(t, 'Gallery', expectFiles: 1);
    await save(t);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(outFiles(), hasLength(1));
  });

  group('#16 L-1: every new photo is registered before it can be saved', () {
    testWidgets('gallery photos: each processed copy is registered for this patient, and those are what gets saved', (t) async {
      picker.gallery = [XFile('$fx/alpha.png'), XFile('$fx/img.gif')];
      await open(t);
      await tapAndProcess(t, 'Gallery', expectFiles: 2);
      final files = outFiles().map((f) => f.path).toList()..sort();
      expect(files, hasLength(2));
      expect([...patients.registered]..sort(), [for (final f in files) 'p1 $f']);
      await save(t);
      expect(patients.added, isNotNull);
      expect([...patients.added!.attachmentPaths]..sort(), files, reason: 'every saved new photo was registered');
    });
    testWidgets('camera photo is registered (the only copy of it)', (t) async {
      picker.camera = XFile('$fx/rot6.jpg');
      await open(t);
      await tapAndProcess(t, 'Camera', expectFiles: 1);
      expect(patients.registered, ['p1 ${outFiles().single.path}']);
    });
    testWidgets('a file that fails processing registers nothing', (t) async {
      picker.gallery = [XFile('$fx/notes.pdf')];
      await open(t);
      await tapAndProcess(t, 'Gallery');
      expect(patients.registered, isEmpty);
    });
    test('a provider without the registry (before #16) is a no-op, not an error', () {
      expect(() => registerPickedAttachment(PatientProvider(), patientId: 'p1', localPath: '/x/a.jpg'), returnsNormally);
    });
  });
}
