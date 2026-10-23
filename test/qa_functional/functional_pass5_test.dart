// QA functional pass, batch 5: visit photos in dev mode (#8 31cf312 + #13).
//
// F-ATT-01 attaching a gallery photo in dev mode works end to end.
// F-ATT-02 the dev-mode app sets the photo owner to the local owner.
// F-ATT-03 a dev-mode photo lands only in the local owner's folder.
//
// The app is built the way the phone builds it: buildDevModeApp() runs first
// (so a fix inside it is picked up), then the #13 dev-mode rig from harness.dart.
import 'dart:io';

import 'package:docease/config/dev_mode.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/dev/dev_mode_app.dart';
import 'package:docease/services/current_owner.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/utils/attachment_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'harness.dart';

class QaPicker extends ImagePickerPlatform {
  List<XFile> gallery = [];
  final calls = <String>[];
  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    calls.add('single:${source.name}');
    return null;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({MultiImagePickerOptions options = const MultiImagePickerOptions()}) async {
    calls.add('multi');
    return gallery;
  }

  @override
  Future<LostDataResponse> getLostData() async => LostDataResponse.empty();
}

class QaPaths extends PathProviderPlatform {
  QaPaths(this.root);
  final Directory root;
  String _d(String n) => (Directory('${root.path}/$n')..createSync(recursive: true)).path;
  @override
  Future<String?> getApplicationSupportPath() async => _d('support');
  @override
  Future<String?> getApplicationDocumentsPath() async => _d('documents');
  @override
  Future<String?> getTemporaryPath() async => _d('tmp');
  @override
  Future<String?> getApplicationCachePath() async => _d('cache');
}

void main() => group('[needs --dart-define=DOCEASE_DEV_MODE=true]', _main, skip: !kDevMode);

void _main() {
  late Directory root;
  late Directory support;
  late QaPicker picker;

  setUpAll(loadRealFonts);
  setUp(() {
    hits.clear();
    root = Directory.systemTemp.createTempSync('docease_fp5');
    support = Directory('${root.path}/support')..createSync();
    PathProviderPlatform.instance = QaPaths(root);
    picker = QaPicker();
    ImagePickerPlatform.instance = picker;
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<void> openPatient(WidgetTester t, String name) => tapText(t, name);
  Future<void> openNewVisit(WidgetTester t) => tapText(t, 'Add Clinical Note');

  /// The photo the picker hands back: a real JPEG copied to the picker's
  /// temp folder, as image_picker does.
  XFile pickedJpeg() {
    final tmp = Directory('${root.path}/tmp')..createSync(recursive: true);
    final f = File('test/fixtures/attachments/rot6.jpg').copySync('${tmp.path}/image_picker_123.jpg');
    return XFile(f.path);
  }

  /// Lets real async work (file IO, JPEG re-encode) run until no spinner is
  /// left, up to 60 s of wall time.
  Future<void> pumpReal(WidgetTester t) async {
    for (var i = 0; i < 200; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 100));
      if (i >= 3 && find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    }
  }

  List<String> filesUnder(Directory d) => d.existsSync()
      ? [for (final e in d.listSync(recursive: true)) if (e is File) e.path.substring(root.path.length)]
      : [];

  group('F-ATT dev-mode photos', () {
    testWidgets('F-ATT-01 attach a gallery photo to a new visit in dev mode and save it', (t) async {
      await t.runAsync(() => buildDevModeApp(const SizedBox()));
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      picker.gallery = [pickedJpeg()];
      await t.ensureVisible(find.text('Gallery'));
      await t.pump();
      await t.tap(find.text('Gallery'));
      await pumpReal(t);
      expect(find.textContaining('signed out'), findsNothing,
          reason: 'dev mode: picker refused with the signed-out message (no photo owner)');
      expect(picker.calls, contains('multi'), reason: 'the gallery picker never opened: ${picker.calls}');
      await type(t, 'Diagnosis', 'Skin rash');
      await t.ensureVisible(find.text('Save Clinical Record'));
      await t.tap(find.text('Save Clinical Record'));
      await pumpReal(t);
      final h = db.rows['p1']!.history;
      expect(h, hasLength(1));
      expect(h.single.attachmentPaths, hasLength(1), reason: 'photo not stored on the visit');
      expect(File(h.single.attachmentPaths.single).existsSync(), isTrue);
    });

    testWidgets('F-ATT-02 the dev-mode app owns photos as the local owner', (t) async {
      // (a) main() wires the owner before the start-mode switch (both paths).
      final m = File('lib/main.dart').readAsStringSync();
      final w = m.indexOf('AttachmentStorage.currentOwnerId = () => CurrentOwner.id;');
      expect(w, greaterThan(0), reason: 'main() does not wire AttachmentStorage.currentOwnerId to CurrentOwner.id');
      final first = m.indexOf('if (kDevBuildRefused)'); // #13 0d720a7: const branches replace the switch
      expect(first, greaterThan(0), reason: 'no start-mode branch in main()');
      expect(w, lessThan(first), reason: 'owner wiring is not before the start-mode branches');
      // (b) at runtime, after a dev boot, the owner is the local owner.
      await t.runAsync(() => buildDevModeApp(const SizedBox()));
      await boot(t, db: QaDb(), support: support);
      expect(CurrentOwner.id, kLocalOwnerId);
      expect(AttachmentStorage.currentOwnerId(), kLocalOwnerId);
      expect(AttachmentStorage.forCurrentOwner(), isNotNull);
    });

    testWidgets('F-ATT-03 a dev-mode photo is kept only in the local owner folder (not Documents, no picker copy)', (t) async {
      await t.runAsync(() => buildDevModeApp(const SizedBox()));
      AttachmentStorage.currentOwnerId = () => kLocalOwnerId; // isolate F-ATT-03 from the F-ATT-02 defect
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      picker.gallery = [pickedJpeg()];
      await t.ensureVisible(find.text('Gallery'));
      await t.pump();
      await t.tap(find.text('Gallery'));
      await pumpReal(t);
      await type(t, 'Diagnosis', 'Skin rash');
      await t.ensureVisible(find.text('Save Clinical Record'));
      await t.tap(find.text('Save Clinical Record'));
      await pumpReal(t);
      final h = db.rows['p1']!.history;
      expect(h.single.attachmentPaths, hasLength(1));
      final owner = LocalPhotoStore.ownerFolderName(kLocalOwnerId);
      final all = [...filesUnder(Directory('${root.path}/support')), ...filesUnder(Directory('${root.path}/documents')), ...filesUnder(Directory('${root.path}/tmp'))]
          .where((f) => f.toLowerCase().endsWith('.jpg'))
          .toList();
      expect(all, everyElement(startsWith('/support/attachments/$owner/')), reason: 'photo copies on disk: $all');
      expect(all, hasLength(1), reason: 'exactly one copy expected: $all');
      // security F8-R2 verify: sha256("local")[:32]
      expect(owner, '25bf8e1a2393f1108d37029b3df55932');
    });

    // Seam check for the frontend #8 wiring frontend still owes:
    // AttachmentStorage.currentOwnerId = () => CurrentOwner.id. Applied here in
    // the test; proves #13's CurrentOwner is 'local' in dev mode and the picker works.
    testWidgets('F-ATT-05 [seam] with currentOwnerId => CurrentOwner.id, dev-mode attach works', (t) async {
      await t.runAsync(() => buildDevModeApp(const SizedBox()));
      AttachmentStorage.currentOwnerId = () => CurrentOwner.id;
      final db = QaDb();
      seedPatient(db, 'p1', 'Asha Verma');
      await boot(t, db: db, support: support);
      expect(CurrentOwner.id, kLocalOwnerId, reason: 'CurrentOwner not set to the local owner in dev mode');
      await openPatient(t, 'Asha Verma');
      await openNewVisit(t);
      picker.gallery = [pickedJpeg()];
      await t.ensureVisible(find.text('Gallery'));
      await t.pump();
      await t.tap(find.text('Gallery'));
      await pumpReal(t);
      expect(find.textContaining('signed out'), findsNothing);
      await type(t, 'Diagnosis', 'Skin rash');
      await t.ensureVisible(find.text('Save Clinical Record'));
      await t.tap(find.text('Save Clinical Record'));
      await pumpReal(t);
      final h = db.rows['p1']!.history;
      expect(h.single.attachmentPaths, hasLength(1));
      expect(h.single.attachmentPaths.single, contains('/attachments/25bf8e1a2393f1108d37029b3df55932/'));
      expect(File(h.single.attachmentPaths.single).existsSync(), isTrue);
    });

    // security re-review F8-R4 (low, #8): removing a saved photo while editing
    // a visit, then saving, must delete the file (no orphaned plaintext photo).
    testWidgets('F-ATT-04 removing a saved photo in edit mode deletes the file after save (F8-R4)', (t) async {
      AttachmentStorage.currentOwnerId = () => kLocalOwnerId;
      final dir = Directory('${support.path}/attachments/${LocalPhotoStore.ownerFolderName(kLocalOwnerId)}')..createSync(recursive: true);
      final photo = File('test/fixtures/attachments/rot6.jpg').copySync('${dir.path}/0b6f3c1e-1111-4222-8333-444455556666.jpg');
      final db = QaDb();
      final v = visitOn('v1', DateTime(2026, 3, 1), diagnosis: 'Viral fever');
      seedPatient(db, 'p1', 'Asha Verma', history: [
        VisitRecord(id: v.id, date: v.date, visitType: v.visitType, symptoms: v.symptoms, diagnosis: v.diagnosis,
            prescription: v.prescription, attachmentPaths: [photo.path]),
      ]);
      await boot(t, db: db, support: support);
      await openPatient(t, 'Asha Verma');
      await tapText(t, 'Viral fever');
      await tapIconLast(t, Icons.edit_outlined);
      await pumpReal(t);
      final close = find.byIcon(Icons.close);
      expect(close, findsWidgets, reason: 'no remove control on the saved photo');
      await t.ensureVisible(close.first);
      await t.pump();
      await t.tap(close.first);
      await pumpReal(t);
      await t.ensureVisible(find.text('Save Clinical Record'));
      await t.tap(find.text('Save Clinical Record'));
      await pumpReal(t);
      expect(db.rows['p1']!.history.single.attachmentPaths, isEmpty, reason: 'photo still on the record');
      expect(photo.existsSync(), isFalse, reason: 'removed photo left on disk: ${photo.path}');
    });
  });
}
