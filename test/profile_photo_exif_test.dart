// ignore_for_file: depend_on_referenced_packages (platform-interface fakes, as in the other widget tests)
// L-18: the doctor's profile photo is re-encoded by #8's AttachmentProcessor
// before it can be uploaded, so GPS, camera make/model and capture time are
// gone, the result is a real JPEG, and the picker's own copy is deleted.
import 'dart:io';
import 'dart:typed_data';

import 'package:docease/models/doctor.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/screens/doctor_profile_screen.dart';
import 'package:docease/utils/attachment_processor.dart';
import 'package:docease/utils/picker_hygiene.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

const _gpsPhoto = 'test/fixtures/profile/gps_camera.jpg';
const _png = 'test/fixtures/attachments/alpha.png';
const _pdf = 'test/fixtures/attachments/notes.pdf';

/// Hands out a fresh picker-style copy per pick: `<root>/<uuid>/<name>`, like
/// the Android gallery picker, so PickerHygiene recognises it.
class _FakePicker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  _FakePicker(this.root);
  final Directory root;
  final queue = <String>[];
  final copies = <String>[];
  final options = <ImagePickerOptions>[];
  var _n = 0;

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    this.options.add(options);
    if (queue.isEmpty) return null;
    final src = queue.removeAt(0);
    final dir = Directory(p.join(root.path, '0f8fad5b-d9cb-469f-a165-70867728950${_n++}'))..createSync();
    final copy = File(src).copySync(p.join(dir.path, p.basename(src)));
    copies.add(copy.path);
    return XFile(copy.path);
  }
}

class _Doctor extends DoctorProvider {
  // A saved profile without a photo, so the screen never reaches for
  // FirebaseAuth (it only does that to prefill the email of a new profile).
  @override
  Doctor? get currentDoctor => Doctor(id: 'd1', title: 'MR', name: 'John', email: 'john@clinic.test', age: '45', mobileNumber: '+919812345678', specialty: 'General Medicine', clinicName: 'City Clinic', practiceMode: 'Solo Practice');
  @override
  bool get isLoading => false;
  @override
  Future<void> fetchDoctorProfile() async {}
}

/// JPEG segment markers before the image data (APP1 = 0xE1 holds EXIF/XMP).
List<int> _markers(Uint8List b) {
  final out = <int>[];
  var i = 2;
  while (i + 4 <= b.length && b[i] == 0xFF) {
    final m = b[i + 1];
    out.add(m);
    if (m == 0xDA) break; // start of scan
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return out;
}

bool _has(Uint8List b, String s) => String.fromCharCodes(b).contains(s);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  late Directory tmp, root, out;
  late _FakePicker picker;
  late AttachmentProcessor processor;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('docease_profile_');
    root = Directory(p.join(tmp.path, 'cache'))..createSync();
    out = Directory(p.join(tmp.path, 'profile_photo'))..createSync();
    picker = _FakePicker(root);
    ImagePickerPlatform.instance = picker;
    final hygiene = PickerHygiene(temporaryRoots: () async => [root]);
    processor = AttachmentProcessor(outputDirectory: () async => out, maxEdge: 1024, discardSource: hygiene.discardPickedSource);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<File> outFiles() => out.listSync().whereType<File>().toList();

  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 150 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pump();
  }

  bool idle() => find.byType(CircularProgressIndicator).evaluate().isEmpty;

  Future<void> open(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 2800);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('overflowed by')) return; // test font
      prev?.call(d);
    };
    addTearDown(() => FlutterError.onError = prev);
    await t.pumpWidget(ChangeNotifierProvider<DoctorProvider>.value(
      value: _Doctor(),
      child: MaterialApp(home: DoctorProfileScreen(photoProcessor: processor)),
    ));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Unlock Profile'));
    await t.pumpAndSettle();
  }

  Future<void> pickFromGallery(WidgetTester t, String fixture, {int expectFiles = 1}) async {
    picker.queue.add(fixture);
    await t.tap(find.byIcon(Icons.camera_alt));
    await t.pumpAndSettle();
    await t.tap(find.text('Choose from gallery'));
    await t.pump();
    await settle(t, () => idle() && outFiles().length == expectFiles && picker.copies.every((c) => !File(c).existsSync()));
  }

  File? avatarFile(WidgetTester t) {
    final img = t.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundImage;
    return img is FileImage ? img.file : null;
  }

  test('the fixture really carries EXIF, GPS, camera model and capture time', () {
    final b = File(_gpsPhoto).readAsBytesSync();
    expect(_markers(b), contains(0xE1));
    expect(_has(b, 'Exif'), isTrue);
    expect(_has(b, 'DOCEaseCam X1'), isTrue);
    expect(_has(b, 'TestCamMaker'), isTrue);
    expect(_has(b, '2024:05:06'), isTrue);
  });

  testWidgets('a geotagged gallery photo is re-encoded without metadata and the picker copy is deleted', (t) async {
    await open(t);
    await pickFromGallery(t, _gpsPhoto);

    final f = avatarFile(t);
    expect(f, isNotNull, reason: 'the avatar shows the picked photo');
    expect(p.dirname(f!.path), out.path, reason: 'the avatar and upload use the re-encoded file, not the picker copy');
    expect(f.path, endsWith('.jpg'));
    final b = f.readAsBytesSync();
    expect([b[0], b[1]], [0xFF, 0xD8]);
    expect(_markers(b), isNot(contains(0xE1)), reason: 'no APP1 (EXIF/XMP) segment');
    expect(_has(b, 'Exif'), isFalse);
    expect(_has(b, 'DOCEaseCam'), isFalse);
    expect(_has(b, 'TestCamMaker'), isFalse);
    expect(_has(b, '2024:05:06'), isFalse);

    expect(picker.copies, hasLength(1));
    expect(File(picker.copies.single).existsSync(), isFalse, reason: "the picker's copy with the original EXIF is deleted");
    expect(Directory(p.dirname(picker.copies.single)).existsSync(), isFalse, reason: 'and its <uuid>/ folder');
    expect(picker.options.single.imageQuality, isNull, reason: "no plugin re-compression, which copies EXIF into another temp file");
  });

  testWidgets('a PNG pick becomes a real JPEG, not a PNG with a .jpg name', (t) async {
    await open(t);
    await pickFromGallery(t, _png);
    final b = avatarFile(t)!.readAsBytesSync();
    expect([b[0], b[1]], [0xFF, 0xD8]);
    expect(avatarFile(t)!.path, endsWith('.jpg'));
  });

  testWidgets('a file that is not a photo shows the message, sets no photo, and its copy is still deleted', (t) async {
    await open(t);
    await pickFromGallery(t, _pdf, expectFiles: 0);
    await t.pump();
    expect(find.text(const AttachmentException(AttachmentError.unsupported).message), findsOneWidget);
    expect(avatarFile(t), isNull);
    expect(find.bySemanticsLabel('No profile photo'), findsOneWidget);
    expect(File(picker.copies.single).existsSync(), isFalse);
    expect(outFiles(), isEmpty);
  });

  testWidgets('picking again deletes the previous photo; closing the screen deletes the current one', (t) async {
    await open(t);
    await pickFromGallery(t, _gpsPhoto);
    final first = avatarFile(t)!;
    await pickFromGallery(t, _png);
    final second = avatarFile(t)!;
    expect(second.path, isNot(first.path));
    await settle(t, () => !first.existsSync());
    expect(first.existsSync(), isFalse, reason: 'replaced photo removed');
    expect(outFiles().map((f) => f.path), [second.path]);

    await t.pumpWidget(const SizedBox());
    await settle(t, () => !second.existsSync());
    expect(outFiles(), isEmpty, reason: 'nothing is left once the screen closes');
  });
}
