// Regression tests for the PR #8 security review (F8-1, F8-2, F8-4, F8-5, F8-6):
// owner-scoped app-private storage with backup exclusion, deleting the
// picker's EXIF-carrying copies, size limits, and the startup clean-up.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:docease/utils/attachment_processor.dart';
import 'package:docease/utils/attachment_storage.dart';
import 'package:docease/utils/picker_hygiene.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

const fx = 'test/fixtures/attachments';

// sha256(owner) hex, first 32 characters, computed outside Dart. Same
// folder names as PR #13's LocalPhotoStore and the DB file hash.
const hashUidA = '395d6ec5c5b203811838c118290360ad';
const hashLocal = '25bf8e1a2393f1108d37029b3df55932';

class FakePicker extends ImagePickerPlatform {
  List<XFile> gallery = [];
  LostDataResponse lost = LostDataResponse.empty();
  final calls = <String>[];
  ImagePickerOptions? singleOptions;
  MultiImagePickerOptions? multiOptions;

  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    calls.add('single:${source.name}');
    singleOptions = options;
    return null;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async {
    calls.add('multi');
    multiOptions = options;
    return gallery;
  }

  @override
  Future<LostDataResponse> getLostData() async {
    calls.add('lost');
    return lost;
  }
}

class RecordingPatientProvider extends PatientProvider {
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
  @override
  Future<void> addRecord(String patientId, VisitRecord record) async {}
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

  late Directory sandbox;
  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('docease_sec_');
    AttachmentStorage.resetExclusionCache();
  });
  tearDown(() {
    AttachmentStorage.currentOwnerId = () => null;
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  Directory sub(String name) => Directory(p.join(sandbox.path, name))..createSync(recursive: true);
  File put(String path, [String body = 'x']) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(body);

  group('F8-1 owner-scoped, app-private storage', () {
    test('photos go to <base>/attachments/<sha256(owner)[:32]>/ (PR #13 layout), excluded from backup', () async {
      final base = sub('support');
      final excluded = <String>[];
      final s = AttachmentStorage(ownerId: 'uidA', baseDirectory: () async => base, excludeFromBackup: (d) async => excluded.add(d));
      final dir = await s.directory();
      expect(dir.path, p.join(base.path, 'attachments', hashUidA));
      expect(dir.path, isNot(contains('uidA')), reason: 'the uid itself is not on disk');
      expect(AttachmentStorage.ownerFolderName('local'), hashLocal);
      expect(dir.existsSync(), isTrue);
      await s.directory();
      expect(excluded, [p.join(base.path, 'attachments')], reason: 'asked once per run, for the whole attachments tree');
    });

    test('no default folder: the processor needs an owner storage or an explicit directory', () async {
      final base = sub('support');
      final s = AttachmentStorage(ownerId: 'uidA', baseDirectory: () async => base, excludeFromBackup: (_) async {});
      final proc = AttachmentProcessor.forStorage(s);
      final picked = File(p.join(sub('gallery').path, 'pic.png'))..writeAsBytesSync(File('$fx/alpha.png').readAsBytesSync());
      final out = await proc.toJpegFile(XFile(picked.path));
      expect(p.isWithin(p.join(base.path, 'attachments', hashUidA), out), isTrue);
      expect(out, endsWith('.jpg'));
    });

    test('a missing backup-exclusion channel does not block photos, and is retried', () async {
      var calls = 0;
      final s = AttachmentStorage(
        ownerId: 'uidA',
        baseDirectory: () async => sandbox,
        excludeFromBackup: (_) async {
          calls++;
          throw MissingPluginException();
        },
      );
      expect((await s.directory()).existsSync(), isTrue);
      await s.directory();
      expect(calls, 2);
    });

    test('an empty owner is rejected; any other owner stays inside attachments/', () async {
      expect(() => AttachmentStorage(ownerId: '', baseDirectory: () async => sandbox), throwsArgumentError);
      for (final odd in ['..', '../uidB', 'a/b', r'a\b', 'uid A']) {
        final dir = await AttachmentStorage(ownerId: odd, baseDirectory: () async => sandbox, excludeFromBackup: (_) async {}).directory();
        expect(p.dirname(dir.path), p.join(sandbox.path, 'attachments'), reason: odd);
        expect(p.basename(dir.path), matches(RegExp(r'^[0-9a-f]{32}$')), reason: odd);
      }
    });

    test('forCurrentOwner follows the owner hook and is null when signed out', () {
      AttachmentStorage.currentOwnerId = () => 'uidA';
      expect(AttachmentStorage.forCurrentOwner()?.ownerId, 'uidA');
      AttachmentStorage.currentOwnerId = () => null;
      expect(AttachmentStorage.forCurrentOwner(), isNull);
      AttachmentStorage.currentOwnerId = () => '';
      expect(AttachmentStorage.forCurrentOwner(), isNull);
      AttachmentStorage.currentOwnerId = () => throw StateError('no auth');
      expect(AttachmentStorage.forCurrentOwner(), isNull);
    });

    test("deleteOwned only deletes this owner's files", () async {
      final base = sub('support');
      final a = AttachmentStorage(ownerId: 'uidA', baseDirectory: () async => base, excludeFromBackup: (_) async {});
      final hashB = AttachmentStorage.ownerFolderName('uidB');
      final mine = put(p.join(base.path, 'attachments', hashUidA, 'one.jpg'));
      final other = put(p.join(base.path, 'attachments', hashB, 'two.jpg'));
      final outside = put(p.join(sandbox.path, 'gallery', 'three.jpg'));
      final escape = p.join(base.path, 'attachments', hashUidA, '..', hashB, 'two.jpg');
      final link = Link(p.join(base.path, 'attachments', hashUidA, 'link.jpg'))..createSync(outside.path);
      final n = await a.deleteOwned([
        mine.path, other.path, outside.path, escape, link.path,
        'clinical_attachments/uidA/p1/x.jpg', 'https://example.com/x.jpg', 'one.jpg',
      ]);
      expect(n, 1);
      expect(mine.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(outside.existsSync(), isTrue, reason: 'symlink target outside the folder is never deleted');
    });

    test('visit/patient delete removes local photos only after the delete succeeded', () async {
      final base = sub('support');
      final s = AttachmentStorage(ownerId: 'uidA', baseDirectory: () async => base, excludeFromBackup: (_) async {});
      final f1 = put(p.join(base.path, 'attachments', hashUidA, 'a.jpg'));
      final f2 = put(p.join(base.path, 'attachments', hashUidA, 'b.jpg'));
      final history = [f1.path, 'clinical_attachments/uidA/p1/c.jpg'];

      await expectLater(
        deleteWithLocalAttachments(history, () async => throw StateError('refused'), storage: s),
        throwsStateError,
      );
      expect(f1.existsSync(), isTrue, reason: 'refused delete keeps the photo');

      // The list is read before the delete runs (the provider mutates history).
      await deleteWithLocalAttachments(history, () async => history.clear(), storage: s);
      expect(f1.existsSync(), isFalse);
      expect(f2.existsSync(), isTrue, reason: 'photos of other visits stay');
    });
  });

  group("F8-2 the picker's original copies are deleted", () {
    test('the picked copy in a temp root is deleted after conversion, with its <uuid>/ folder', () async {
      final tmp = sub('cache');
      final h = PickerHygiene(temporaryRoots: () async => [tmp]);
      final copy = File(p.join(tmp.path, '0f8fad5b-d9cb-469f-a165-70867728950e', 'rahul_wound.png'))
        ..parent.createSync()
        ..writeAsBytesSync(File('$fx/alpha.png').readAsBytesSync());
      final proc = AttachmentProcessor(outputDirectory: () async => sub('out'), discardSource: h.discardPickedSource);
      final out = await proc.toJpegFile(XFile(copy.path));
      expect(File(out).existsSync(), isTrue);
      expect(copy.existsSync(), isFalse);
      expect(copy.parent.existsSync(), isFalse);
    });

    test('the picked copy is deleted even when the photo cannot be converted', () async {
      final tmp = sub('cache');
      final h = PickerHygiene(temporaryRoots: () async => [tmp]);
      final copy = put(p.join(tmp.path, 'image_picker_ABC.jpg'), 'not an image');
      final proc = AttachmentProcessor(outputDirectory: () async => sub('out'), discardSource: h.discardPickedSource);
      await expectLater(proc.toJpegFile(XFile(copy.path)), throwsA(isA<AttachmentException>()));
      expect(copy.existsSync(), isFalse);
    });

    test('a file outside the temp roots (a real gallery photo) is never deleted', () async {
      final tmp = sub('cache');
      final h = PickerHygiene(temporaryRoots: () async => [tmp]);
      final gallery = File(p.join(sub('DCIM').path, 'photo.png'))..writeAsBytesSync(File('$fx/alpha.png').readAsBytesSync());
      final link = Link(p.join(tmp.path, 'image_picker_link.png'))..createSync(gallery.path);
      expect(await h.discardPickedSource(gallery.path), isFalse);
      expect(await h.discardPickedSource(link.path), isFalse, reason: 'a link out of the temp folder is not followed');
      final proc = AttachmentProcessor(outputDirectory: () async => sub('out'), discardSource: h.discardPickedSource);
      await proc.toJpegFile(XFile(gallery.path));
      expect(gallery.existsSync(), isTrue);
    });

    test('startup sweep removes picker leftovers only', () async {
      final tmp = sub('cache');
      final keep = [
        put(p.join(tmp.path, 'notes.txt')),
        put(p.join(tmp.path, 'report_0f8fad5b_20261023.pdf')),
        put(p.join(tmp.path, 'flutter_engine', 'shader.bin')),
        put(p.join(tmp.path, 'not-a-uuid', 'x.jpg')),
      ];
      final gone = [
        put(p.join(tmp.path, '0f8fad5b-d9cb-469f-a165-70867728950e', 'IMG_1.jpg')),
        put(p.join(tmp.path, 'image_picker_6F2D.jpg')),
        put(p.join(tmp.path, 'scaled_IMG_2.jpg')),
        put(p.join(tmp.path, '1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed4211961238.jpg')),
      ];
      final n = await PickerHygiene(temporaryRoots: () async => [tmp]).sweepLeftovers();
      expect(n, 4);
      for (final f in keep) {
        expect(f.existsSync(), isTrue, reason: f.path);
      }
      for (final f in gone) {
        expect(f.existsSync(), isFalse, reason: f.path);
      }
      expect(Directory(p.join(tmp.path, '0f8fad5b-d9cb-469f-a165-70867728950e')).existsSync(), isFalse);
    });

    test('startup drops photos from an interrupted pick (retrieveLostData) and sweeps', () async {
      final tmp = sub('cache');
      final lostFile = put(p.join(tmp.path, 'lost', 'x.jpg'));
      final leftover = put(p.join(tmp.path, 'image_picker_OLD.jpg'));
      final picker = FakePicker()..lost = LostDataResponse(files: [XFile(lostFile.path)], type: RetrieveType.image);
      ImagePickerPlatform.instance = picker;
      await PickerHygiene.atStartup(hygiene: PickerHygiene(temporaryRoots: () async => [tmp]));
      expect(picker.calls, contains('lost'));
      expect(lostFile.existsSync(), isFalse);
      expect(leftover.existsSync(), isFalse);
    });
  });

  group('F8-4 / F8-5 size limits', () {
    test('an image declaring more than 100 megapixels is refused before decoding', () async {
      final out = sub('out');
      final proc = AttachmentProcessor(outputDirectory: () async => out, discardSource: (_) async {});
      final sw = Stopwatch()..start();
      await expectLater(
        proc.toJpegFile(XFile('$fx/huge_dimensions.png')),
        throwsA(isA<AttachmentException>().having((e) => e.error, 'error', AttachmentError.tooLarge)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(out.listSync(), isEmpty);
    });

    test('output over the upload limit is retried once at lower quality, then refused', () async {
      final bytes = File('$fx/noise.png').readAsBytesSync();
      final probe = AttachmentProcessor(outputDirectory: () async => sub('probe'), discardSource: (_) async {});
      final q85 = (await probe.encodeBytes(bytes)).length;
      final q60 = (await probe.encodeBytes(bytes, quality: 60)).length;
      expect(q60, lessThan(q85));

      final out = sub('out');
      final fits = AttachmentProcessor(outputDirectory: () async => out, maxOutputBytes: q60, discardSource: (_) async {});
      final path = await fits.toJpegFile(XFile('$fx/noise.png'));
      expect(File(path).lengthSync(), lessThanOrEqualTo(q60));

      final out2 = sub('out2');
      final tooBig = AttachmentProcessor(outputDirectory: () async => out2, maxOutputBytes: q60 - 1, discardSource: (_) async {});
      await expectLater(
        tooBig.toJpegFile(XFile('$fx/noise.png')),
        throwsA(isA<AttachmentException>().having((e) => e.error, 'error', AttachmentError.tooLarge)),
      );
      expect(out2.listSync(), isEmpty);
    });

    test('the default output limit matches the Storage rules (10 MiB)', () {
      expect(AttachmentProcessor.defaultMaxOutputBytes, 10 * 1024 * 1024);
    });
  });

  test('F8-6 Android uses the system Photo Picker', () {
    final android = ImagePickerAndroid();
    ImagePickerPlatform.instance = android;
    expect(android.useAndroidPhotoPicker, isFalse);
    PickerHygiene.useSystemPhotoPickerOnAndroid();
    expect(android.useAndroidPhotoPicker, isTrue);
  });

  group('Clinical Note screen', () {
    late FakePicker picker;
    setUp(() {
      picker = FakePicker();
      ImagePickerPlatform.instance = picker;
    });

    Future<void> open(WidgetTester t, {AttachmentProcessor? processor}) async {
      t.view.physicalSize = const Size(1080, 4400);
      t.view.devicePixelRatio = 2.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<PatientProvider>.value(value: RecordingPatientProvider()),
          ChangeNotifierProvider<MedicineProvider>.value(value: FakeMedicineProvider()),
        ],
        child: MaterialApp(home: AddRecordScreen(patientId: 'p1', attachmentProcessor: processor)),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('gallery asks for at most 10 photos and no plugin-side resize', (t) async {
      await open(t, processor: AttachmentProcessor(outputDirectory: () async => sandbox, discardSource: (_) async {}));
      await t.tap(find.text('Gallery'));
      await t.pumpAndSettle();
      expect(picker.calls, ['multi']);
      expect(picker.multiOptions!.limit, 10);
      expect(picker.multiOptions!.imageOptions.maxWidth, isNull);
      expect(picker.multiOptions!.imageOptions.maxHeight, isNull);
    });

    testWidgets('camera asks for no plugin-side resize', (t) async {
      await open(t, processor: AttachmentProcessor(outputDirectory: () async => sandbox, discardSource: (_) async {}));
      await t.tap(find.text('Camera'));
      await t.pumpAndSettle();
      expect(picker.calls, ['single:camera']);
      expect(picker.singleOptions!.maxWidth, isNull);
      expect(picker.singleOptions!.maxHeight, isNull);
    });

    testWidgets('signed out: no owner folder, so the picker does not open', (t) async {
      AttachmentStorage.currentOwnerId = () => null;
      await open(t);
      await t.tap(find.text('Gallery'));
      await t.pump();
      expect(picker.calls, isEmpty);
      expect(find.textContaining("you're signed out"), findsOneWidget);
    });
  });
}
