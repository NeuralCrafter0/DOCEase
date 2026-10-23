// PR #13 follow-ups: startup hooks, SaveRefusedException, iOS backup
// exclusion of the photo folders, PDF file name / share-text TEST DATA
// markers and the Android build guard. Fakes only, no Firebase.
import 'dart:io';

import 'package:docease/models/patient.dart';
import 'package:docease/providers/database_helper.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/attachments.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/startup_hooks.dart';
import 'package:docease/utils/pdf_export.dart';
import 'package:docease/utils/test_data_marker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/db_fakes.dart';

class RecordingExcluder implements BackupExcluder {
  final List<String> paths = [];
  bool fail = false;
  @override
  Future<void> exclude(String path) async {
    paths.add(path);
    if (fail) throw PlatformException(code: 'exclude_failed', message: '/secret/path Asha');
  }
}

Future<List<String>> captureLogs(Future<void> Function() body) async {
  final logs = <String>[];
  final old = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
  try {
    await body();
  } finally {
    debugPrint = old;
  }
  return logs;
}

void main() {
  group('StartupHooks', () {
    setUp(StartupHooks.resetForTesting);

    test('runs registered hooks once, after runAll', () async {
      final ran = <String>[];
      StartupHooks.register('a', () async => ran.add('a'));
      StartupHooks.register('b', () async => ran.add('b'));
      StartupHooks.register('a', () async => ran.add('a-again'));
      await pumpEventQueue();
      expect(ran, isEmpty, reason: 'nothing runs before the app has started');
      StartupHooks.runAll();
      StartupHooks.runAll();
      await pumpEventQueue();
      expect(ran, ['a', 'b']);
      expect(StartupHooks.names, ['a', 'b']);
    });

    test('a hook registered after start runs at once', () async {
      StartupHooks.runAll();
      var ran = false;
      StartupHooks.register('late', () async => ran = true);
      await pumpEventQueue();
      expect(ran, isTrue);
    });

    test('a failing hook (sync or async) logs only a code and does not stop the others', () async {
      var ran = false;
      final logs = await captureLogs(() async {
        StartupHooks.register('sync', () => throw StateError('patient Asha /data/x.jpg'));
        StartupHooks.register('async', () async => throw const FileSystemException('x', '/data/Asha.jpg'));
        StartupHooks.register('ok', () async => ran = true);
        StartupHooks.runAll();
        await pumpEventQueue();
      });
      expect(ran, isTrue);
      expect(logs, ['Startup: hook sync failed (StateError)', 'Startup: hook async failed (FileSystemException)']);
    });

    test('main.dart runs the hooks after runApp on both start paths, never on the refused screen', () {
      final src = File('lib/main.dart').readAsStringSync();
      expect('StartupHooks.runAll();'.allMatches(src), hasLength(2));
      final refused = src.substring(src.indexOf('case StartMode.refused:'), src.indexOf('case StartMode.dev:'));
      expect(refused, isNot(contains('StartupHooks')));
      final dev = src.substring(src.indexOf('case StartMode.dev:'), src.indexOf('case StartMode.normal:'));
      expect(dev.indexOf('StartupHooks.runAll()'), greaterThan(dev.indexOf('runApp(')));
      final normal = src.substring(src.indexOf('case StartMode.normal:'), src.indexOf('class DOCEaseApp'));
      expect(normal.lastIndexOf('StartupHooks.runAll()'), greaterThan(normal.lastIndexOf('runApp(')));
    });
  });

  group('SaveRefusedException', () {
    late FakeLocalDatabase db;
    late PatientProvider provider;
    setUp(() {
      db = FakeLocalDatabase();
      provider = PatientProvider(db: db, firestore: FakeFirestoreHelper());
    });

    test('refused add: thrown with the cause, patient not shown, nothing synced', () async {
      db.refuseWrites = true;
      Object? error;
      try {
        await provider.addPatient(testPatient('p1', name: 'Asha Rao'));
      } catch (e) {
        error = e;
      }
      expect(error, isA<SaveRefusedException>());
      final e = error! as SaveRefusedException;
      expect(e.operation, PatientSaveOperation.add);
      expect(e.error, isA<UnsyncedCounterException>());
      expect(e, isA<UnsyncedCounterException>(), reason: 'old catches keep working');
      expect(e.causeCode, 'UnsyncedCounterException');
      expect(provider.patients, isEmpty);
      expect(db.log, isNot(contains(startsWith('markSynced'))));
    });

    test('refused update: previous version shown again', () async {
      await provider.addPatient(testPatient('p1', name: 'Asha'));
      await flushMicrotasks();
      db.refuseWrites = true;
      await expectLater(provider.updatePatient(testPatient('p1', name: 'Changed')),
          throwsA(isA<SaveRefusedException>().having((e) => e.operation, 'operation', PatientSaveOperation.update)));
      expect(provider.patients.single.name, 'Asha');
    });

    test('unreadable patient: SaveRefusedException and still an UnreadablePatientException', () async {
      final broken = Patient.fromJson({
        'id': 'p9', 'name': 'Ravi', 'age': '40', 'gender': 'Male', 'phone': '+91',
        'history': [
          {'id': 'r1', 'date': 'not-a-date', 'diagnosis': 'Dx'}
        ],
      });
      expect(broken.hasParseErrors, isTrue);
      await expectLater(provider.addPatient(broken),
          throwsA(allOf(isA<SaveRefusedException>(), isA<UnreadablePatientException>())));
      expect(provider.patients, isEmpty);
    });

    test('toString carries no patient data, ids or raw messages', () {
      final e = SaveRefusedException(
          PatientSaveOperation.add, StateError('Asha Rao +919999999999 doctorA p1'));
      expect(e.toString(), 'SaveRefusedException(add, cause: StateError)');
      final wrapped = SaveRefusedException(PatientSaveOperation.update, UnsyncedCounterException('doctorA'));
      expect(wrapped.toString(), 'SaveRefusedException(update, cause: UnsyncedCounterException)');
    });
  });

  group('iOS backup exclusion of photo folders', () {
    late Directory tmp;
    late Directory support;
    late File picked;
    late RecordingExcluder excluder;
    late LocalPhotoStore store;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('backup_excl');
      support = await Directory(p.join(tmp.path, 'support')).create();
      picked = File(p.join(tmp.path, 'picked.jpg'))..writeAsBytesSync([0xFF, 0xD8, 0xFF, 1, 2, 3]);
      excluder = RecordingExcluder();
      store = LocalPhotoStore(supportDir: () async => support, backupExcluder: excluder);
    });
    tearDown(() => tmp.delete(recursive: true));

    test('each owner folder is excluded when first used, once per run', () async {
      await store.keepVisitPhoto('local', picked.path, UploadImageType.jpeg);
      await store.keepVisitPhoto('local', picked.path, UploadImageType.jpeg);
      await store.keepAvatar('local', picked.path, UploadImageType.jpeg);
      await store.keepVisitPhoto('doctorA', picked.path, UploadImageType.jpeg);
      expect(excluder.paths, [
        store.visitFolderFor('local'),
        store.profileFolderFor('local'),
        store.visitFolderFor('doctorA'),
      ]);
      for (final d in excluder.paths) {
        expect(Directory(d).existsSync(), isTrue, reason: 'folder exists before it is excluded');
      }
    });

    test('a photo already in the owner folder still gets the folder excluded', () async {
      await store.init();
      final dir = await Directory(store.visitFolderFor('local')!).create(recursive: true);
      final inside = File(p.join(dir.path, 'x.jpg'))..writeAsBytesSync([0xFF, 0xD8, 0xFF]);
      final kept = await store.keepVisitPhoto('local', inside.path, UploadImageType.jpeg);
      expect(kept, inside.path);
      expect(excluder.paths, [dir.path]);
    });

    test('a failure keeps the photo, logs only the code, and is retried next time', () async {
      excluder.fail = true;
      late String kept;
      final logs = await captureLogs(() async {
        kept = await store.keepVisitPhoto('local', picked.path, UploadImageType.jpeg);
      });
      expect(File(kept).existsSync(), isTrue);
      expect(logs, ['Photos: backup exclusion failed (PlatformException)']);
      excluder.fail = false;
      await store.keepVisitPhoto('local', picked.path, UploadImageType.jpeg);
      expect(excluder.paths, [store.visitFolderFor('local'), store.visitFolderFor('local')]);
    });

    test('the default excluder is #10\'s PlatformBackupExcluder; AppDelegate is untouched', () {
      final src = File('lib/services/local_photo_store.dart').readAsStringSync();
      expect(src, contains('backupExcluder ?? const PlatformBackupExcluder()'));
      final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      expect('FlutterMethodChannel('.allMatches(swift), hasLength(1));
    });
  });

  group('TEST DATA markers: PDF file name and share text', () {
    final day = DateTime(2026, 10, 23, 21, 5);
    final asha = Patient(id: '3f2a9c1e-77b0-4d1e-9a52-0c1d2e3f4a5b', name: 'Asha Rao', age: '34', gender: 'Female', phone: '1');

    test('file name follows #7 (no patient name), TEST_DATA_ prefix in dev mode', () {
      expect(PdfExport.reportFileName(asha, day), 'report_3f2a9c1e_20261023.pdf');
      expect(PdfExport.printFileName(asha, day, testData: false), 'report_3f2a9c1e_20261023.pdf');
      expect(PdfExport.printFileName(asha, day, testData: true), 'TEST_DATA_report_3f2a9c1e_20261023.pdf');
      for (final testData in [true, false]) {
        final n = PdfExport.printFileName(asha, day, testData: testData).toLowerCase();
        expect(n, isNot(contains('asha')));
        expect(n, isNot(contains('rao')));
      }
      final src = File('lib/utils/pdf_export.dart').readAsStringSync();
      expect(src, isNot(contains('patient.name.replaceAll')));
    });

    test('share text starts with the marker in dev mode only', () {
      expect(markShareText('*Visit Summary - DOCEase*', testData: true),
          '*TEST DATA - NOT A MEDICAL RECORD*\n*Visit Summary - DOCEase*');
      expect(markShareText('*Visit Summary - DOCEase*', testData: false), '*Visit Summary - DOCEase*');
      final src = String.fromCharCodes(File('lib/screens/patient_detail_screen.dart').readAsBytesSync());
      expect(src, contains('Share.share(markShareText(message, testData: DevMode.of(context)))'));
    });
  });

  test('Android: devRelease is not a variant; the guard reads the task graph', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('beforeVariants(selector().withFlavor("env" to "dev").withBuildType("release"))'));
    expect(gradle, contains('it.enable = false'));
    expect(gradle, contains('gradle.taskGraph.whenReady'));
    expect(gradle, isNot(contains('startParameter.taskNames')));
  });
}
