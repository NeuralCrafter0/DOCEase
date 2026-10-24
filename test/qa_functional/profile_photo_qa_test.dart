// ignore_for_file: depend_on_referenced_packages
// QA: #18 profile photo picker (camera or gallery) on the real DoctorProvider,
// LocalPhotoStore and DoctorProfileScreen. Questions from the brief:
//   - valid and invalid input,
//   - does the photo land in the owner's profile/ folder,
//   - is the GPS original (image_picker's temp copy with EXIF) deleted.
//
// Failing-first cases (GPS EXIF kept / picker original left behind) are
// gated: run with --dart-define=QA_FAILING_FIRST=true to see them fail.
import 'dart:io';
import 'dart:typed_data';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/doctor.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/screens/doctor_profile_screen.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/utils/jpeg_encoder.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../backend/fakes.dart';

const bool _ff = bool.fromEnvironment('QA_FAILING_FIRST');
const String _ffWhy = 'SUSPECTED->CONFIRMED #18: profile photo is passed through raw '
    '(no AttachmentProcessor re-encode, no PickerHygiene); run with QA_FAILING_FIRST=true';

/// Text planted in the EXIF block; the GPS IFD pointer (0x8825) is the real marker.
const String _exifSentinel = 'QA-GPS-HOME-28.6139N-77.2090E';

/// A real, decodable 16x16 JPEG with an APP1 EXIF block carrying a GPS IFD.
Uint8List jpegWithGps() {
  final px = Uint8List(16 * 16 * 4);
  for (var i = 0; i < px.length; i += 4) {
    px[i] = 200; px[i + 1] = 80; px[i + 2] = 40; px[i + 3] = 255;
  }
  final jpg = JpegEncoder(quality: 90).encode(px, 16, 16);
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  void u32(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  final desc = [..._exifSentinel.codeUnits, 0];
  const ifd0 = 8, ifd0Size = 2 + 2 * 12 + 4;
  final descOff = ifd0 + ifd0Size;
  var gpsOff = descOff + desc.length;
  if (gpsOff.isOdd) gpsOff++;
  b.add('II'.codeUnits); u16(0x2A); u32(ifd0);
  u16(2);
  u16(0x010E); u16(2); u32(desc.length); u32(descOff); // ImageDescription
  u16(0x8825); u16(4); u32(1); u32(gpsOff); // GPSInfo IFD pointer
  u32(0);
  b.add(desc);
  while (b.length < gpsOff) {
    b.addByte(0);
  }
  u16(1);
  u16(0x0001); u16(2); u32(2); b.add([0x4E, 0, 0, 0]); // GPSLatitudeRef 'N'
  u32(0);
  final tiff = b.toBytes();
  final seg = [...'Exif'.codeUnits, 0, 0, ...tiff];
  final len = seg.length + 2;
  return Uint8List.fromList([
    jpg[0], jpg[1], // SOI
    0xFF, 0xE1, (len >> 8) & 0xFF, len & 0xFF, ...seg,
    ...jpg.sublist(2),
  ]);
}

/// True when [bytes] still carry an EXIF block with a GPS IFD pointer, or the
/// planted sentinel text.
bool carriesGps(List<int> bytes) {
  final s = String.fromCharCodes(bytes);
  if (s.contains(_exifSentinel)) return true;
  final exif = s.indexOf('Exif\u0000\u0000');
  if (exif < 0) return false;
  for (var i = exif; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0x25 && bytes[i + 1] == 0x88) return true; // II order
    if (bytes[i] == 0x88 && bytes[i + 1] == 0x25) return true; // MM order
  }
  return false;
}

class _Picker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  _Picker(this.next);
  String? Function() next;
  Object? throwOnPick;
  final List<ImageSource> asked = [];
  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    asked.add(source);
    if (throwOnPick != null) throw throwOnPick!;
    final path = next();
    return path == null ? null : XFile(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  late Directory root;
  late Directory support;
  late Directory pickDir; // Android gallery layout: cacheDir/<uuid>/<original name>
  late LocalPhotoStore photos;
  late FakeLocalDatabase db;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('qa_profile_photo');
    support = Directory(p.join(root.path, 'support'))..createSync();
    pickDir = Directory(p.join(Directory.systemTemp.path, const Uuid().v4()))..createSync();
    photos = LocalPhotoStore(supportDir: () async => support);
    await photos.init();
    db = FakeLocalDatabase();
  });
  tearDown(() {
    root.deleteSync(recursive: true);
    if (pickDir.existsSync()) pickDir.deleteSync(recursive: true);
  });

  String pick(String name, List<int> bytes) =>
      (File(p.join(pickDir.path, name))..writeAsBytesSync(bytes)).path;

  List<String> profileFiles(String owner) {
    final d = Directory(photos.profileFolderFor(owner)!);
    return d.existsSync() ? d.listSync().map((e) => e.path).toList() : <String>[];
  }

  List<String> allFilesUnder(Directory d) =>
      d.listSync(recursive: true).whereType<File>().map((f) => f.path).toList();

  Future<DoctorProvider> devDoctor() async {
    final d = DoctorProvider(cloudSync: false, localDb: db, photos: photos,
        auth: FakeAuth(), firestore: FakeFirestore(), storage: FakeStorage());
    await d.load(kLocalOwnerId);
    return d;
  }

  final avatarName = RegExp(r'^avatar_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$');

  group('PP provider: where the photo goes and what is accepted (dev mode)', () {
    test('PP-01 a gallery JPEG lands in the owner profile/ folder as avatar_<uuid>.jpg', () async {
      final d = await devDoctor();
      final kept = await d.uploadProfileImage(File(pick('IMG_20260101_home.jpg', jpegWithGps())));
      expect(kept, isNotNull);
      expect(p.dirname(kept!), photos.profileFolderFor(kLocalOwnerId));
      expect(p.basename(kept), matches(avatarName));
      expect(photos.isAppPhoto(kept, owner: kLocalOwnerId), isTrue);
      expect(p.isWithin(photos.visitFolderFor(kLocalOwnerId)!, kept), isFalse, reason: 'never in the visit folder');
      expect(kept.contains('IMG_20260101_home'), isFalse, reason: 'original file name not kept');
      expect(File(kept).readAsBytesSync().sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    });

    test('PP-02 PNG and WebP keep their own extension', () async {
      final d = await devDoctor();
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(64, 0)];
      final webp = [...'RIFF'.codeUnits, 64, 0, 0, 0, ...'WEBPVP8 '.codeUnits, ...List.filled(64, 0)];
      expect(p.extension((await d.uploadProfileImage(File(pick('a.png', png))))!), '.png');
      expect(p.extension((await d.uploadProfileImage(File(pick('b.webp', webp))))!), '.webp');
    });

    final invalid = <String, List<int> Function()>{
      'HEIC bytes named .heic': () => [0, 0, 0, 0x18, ...'ftypheic'.codeUnits, ...List.filled(64, 0)],
      'text renamed .jpg': () => 'not an image at all'.codeUnits,
      'empty .jpg': () => <int>[],
      '5 MiB + 1 JPEG': () => [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(5 * 1024 * 1024 - 3, 1)],
    };
    for (final e in invalid.entries) {
      test('PP-03 invalid input refused before anything is kept: ${e.key}', () async {
        final d = await devDoctor();
        final name = e.key.startsWith('HEIC') ? 'x.heic' : 'x.jpg';
        await expectLater(d.uploadProfileImage(File(pick(name, e.value()))),
            throwsA(isA<UnsupportedAttachmentException>()));
        expect(profileFiles(kLocalOwnerId), isEmpty);
      }, skip: e.key == 'text renamed .jpg' && !_ff
          ? 'CONFIRMED: validateLocalImage checks extension/size only, no content check (profile path is not re-encoded); QA_FAILING_FIRST=true'
          : null);
    }

    test('PP-03b exactly 5 MiB is accepted (boundary)', () async {
      final d = await devDoctor();
      final bytes = [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(5 * 1024 * 1024 - 4, 1)];
      expect(await d.uploadProfileImage(File(pick('max.jpg', bytes))), isNotNull);
    });

    test('PP-04 the kept avatar carries no GPS EXIF (dev mode)', () async {
      final d = await devDoctor();
      final kept = await d.uploadProfileImage(File(pick('IMG_home.jpg', jpegWithGps())));
      expect(carriesGps(File(kept!).readAsBytesSync()), isFalse,
          reason: 'avatar file under profile/ still has the EXIF GPS block');
    }, skip: _ff ? null : _ffWhy);

    test('PP-05 image_picker\'s original (temp copy with EXIF) is deleted once kept', () async {
      final d = await devDoctor();
      final src = pick('IMG_home.jpg', jpegWithGps());
      final kept = await d.uploadProfileImage(File(src));
      expect(kept, isNotNull);
      await d.saveDoctorProfile(_profile(kept));
      expect(File(src).existsSync(), isFalse, reason: 'picker temp original still on disk: $src');
    }, skip: _ff ? null : _ffWhy);

    test('PP-06 cloud: the uploaded avatar bytes carry no GPS EXIF', () async {
      final storage = FakeStorage();
      final d = DoctorProvider(localDb: db, photos: photos, auth: FakeAuth('doctorA'),
          firestore: FakeFirestore(), storage: storage);
      await d.load('doctorA');
      final url = await d.uploadProfileImage(File(pick('IMG_home.jpg', jpegWithGps())));
      expect(url, isNotNull);
      expect(storage.objects.keys.single, startsWith('doctor_profiles/doctorA/'));
      expect(carriesGps(storage.objects.values.single), isFalse,
          reason: 'GPS EXIF uploaded to Storage with the avatar');
    }, skip: _ff ? null : _ffWhy);

    test('PP-07 control: the GPS detector sees the fixture (detector works)', () {
      expect(carriesGps(jpegWithGps()), isTrue);
      final px = Uint8List(8 * 8 * 4);
      expect(carriesGps(JpegEncoder().encode(px, 8, 8)), isFalse);
    });
  });

  group('PW screen: DoctorProfileScreen with the real dev-mode provider', () {
    Future<DoctorProvider> pump(WidgetTester t) async {
      t.view.physicalSize = const Size(1200, 2800);
      t.view.devicePixelRatio = 2.0;
      addTearDown(t.view.reset);
      final prev = FlutterError.onError;
      FlutterError.onError = (d) {
        if (d.exceptionAsString().contains('overflowed by')) return; // test font
        prev?.call(d);
      };
      addTearDown(() => FlutterError.onError = prev);
      final d = await t.runAsync(devDoctor);
      await t.pumpWidget(ChangeNotifierProvider<DoctorProvider>.value(
          value: d!, child: const MaterialApp(home: DoctorProfileScreen())));
      await t.pumpAndSettle();
      return d;
    }

    Future<void> pickFromGallery(WidgetTester t) async {
      await t.tap(find.byIcon(Icons.camera_alt));
      await t.pumpAndSettle();
      await t.tap(find.text('Choose from gallery'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pumpAndSettle();
    }

    Future<void> fillAndSave(WidgetTester t) async {
      await t.enterText(find.widgetWithText(TextFormField, 'Full Name'), 'Asha Rao');
      await t.enterText(find.descendant(of: find.byType(IntlPhoneField), matching: find.byType(TextField)), '9812345678');
      await t.pump();
      await t.ensureVisible(find.text('Save and Lock Profile'));
      await t.tap(find.text('Save and Lock Profile'));
      for (var i = 0; i < 10; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
      await t.pumpAndSettle();
    }

    testWidgets('PW-01 gallery pick + save: profile photo is the kept avatar in profile/<owner>/', (t) async {
      String? src;
      ImagePickerPlatform.instance = _Picker(() => src = pick('IMG_home.jpg', jpegWithGps()));
      final d = await pump(t);
      await pickFromGallery(t);
      expect(find.byIcon(Icons.person_rounded), findsNothing, reason: 'placeholder hidden once a photo is chosen');
      await fillAndSave(t);
      expect(find.text('Profile Locked & Saved'), findsOneWidget);
      final saved = d.currentDoctor?.profileImageUrl;
      expect(saved, isNotNull);
      expect(p.dirname(saved!), photos.profileFolderFor(kLocalOwnerId));
      expect(p.basename(saved), matches(avatarName));
      expect(profileFiles(kLocalOwnerId), [saved], reason: 'exactly one avatar kept');
      expect(src, isNotNull);
    });

    testWidgets('PW-02 invalid pick (text named .jpg): message shown, nothing kept, nothing saved', (t) async {
      ImagePickerPlatform.instance = _Picker(() => pick('fake.jpg', 'hello'.codeUnits));
      final d = await pump(t);
      await pickFromGallery(t);
      await fillAndSave(t);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('Profile Locked & Saved'), findsNothing);
      expect(d.currentDoctor, isNull, reason: 'the profile must not be saved with a refused photo');
      expect(profileFiles(kLocalOwnerId), isEmpty);
      expect(allFilesUnder(support), isEmpty);
    }, skip: !_ff); // CONFIRMED: non-image named .jpg is kept and saved as the profile photo

    testWidgets('PW-03 picker permission error: no uncaught exception, form still usable', (t) async {
      final picker = _Picker(() => null)..throwOnPick = PlatformException(code: 'photo_access_denied', message: 'denied');
      ImagePickerPlatform.instance = picker;
      await pump(t);
      await pickFromGallery(t);
      expect(t.takeException(), isNull, reason: '_pickImage has no catch: a PlatformException escapes the tap handler');
      expect(find.text('Save and Lock Profile'), findsOneWidget);
    }, skip: !_ff); // SUSPECTED #18 (low): _pickImage has no try/catch around pickImage

    testWidgets('PW-04 Take photo asks the camera; backing out keeps the placeholder', (t) async {
      final picker = _Picker(() => null);
      ImagePickerPlatform.instance = picker;
      await pump(t);
      await t.tap(find.byIcon(Icons.camera_alt));
      await t.pumpAndSettle();
      await t.tap(find.text('Take photo'));
      await t.pumpAndSettle();
      expect(picker.asked, [ImageSource.camera]);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
      expect(find.bySemanticsLabel('No profile photo'), findsOneWidget);
      expect(profileFiles(kLocalOwnerId), isEmpty);
    });
  });
}

Doctor _profile(String? photo) => Doctor(
    id: kLocalOwnerId, title: 'DR', name: 'Asha Rao', email: '', age: '40',
    mobileNumber: '+919812345678', specialty: 'GP', clinicName: 'Clinic',
    practiceMode: 'Clinic', profileImageUrl: photo);
