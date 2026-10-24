// QA: remove a learned medicine suggestion (#6 1bae23c, security Low),
// merged with #13/#16 per #6's merge notes (one load flag, reset in clear()).
// Real MedicineProvider with test/backend fakes (no Firebase).
//
// MR-13 is failing-first (QA_FAILING_FIRST=true): addMedicineIfNew has no
// load guard and writes the whole in-memory list, so an add before B's
// list loads overwrites B's stored list. Expected to pass once backend's
// loadFailed guard (one shared flag) lands.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/screens/add_record_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../backend/fakes.dart';
import '../support/db_fakes.dart';

const _ff = bool.fromEnvironment('QA_FAILING_FIRST');
const Object? _ffSkip = _ff
    ? null
    : 'failing-first: addMedicineIfNew has no load guard (pending backend '
        'loadFailed / shared flag); run with --dart-define=QA_FAILING_FIRST=true';

const medsA = 'doctors/a/settings/medicines';
const medsB = 'doctors/b/settings/medicines';
const key = MedicineProvider.localSettingKey;

class _GatedFs extends FakeFirestore {
  Completer<void>? writeGate;
  @override
  CollectionReference<Map<String, dynamic>> collection(String path) => _GatedCol(this, path);
}

class _GatedCol extends FakeCollection {
  _GatedCol(_GatedFs super.fs, super.path);
  @override
  DocumentReference<Map<String, dynamic>> doc([String? id]) =>
      _GatedDoc(fs as _GatedFs, '$path/$id');
}

class _GatedDoc extends FakeDoc {
  _GatedDoc(_GatedFs super.fs, super.path);
  @override
  CollectionReference<Map<String, dynamic>> collection(String p) =>
      _GatedCol(fs as _GatedFs, '$path/$p');
  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) async {
    final g = (fs as _GatedFs).writeGate;
    if (g != null) await g.future;
    return super.set(data, options);
  }
}

class _RefusingSettingsDb extends FakeLocalDatabase {
  bool refusePut = false;
  int puts = 0;
  @override
  Future<void> putSetting(String key, String value) async {
    puts++;
    if (refusePut) throw StateError('disk full');
    return super.putSetting(key, value);
  }
}

class _OnePatient extends PatientProvider {
  @override
  Patient findById(String id) =>
      Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
}

List<String> _cloudItems(FakeFirestore fs, String path) =>
    List<String>.from(fs.docs[path]?['items'] as List? ?? const []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async {
    await Firebase.initializeApp();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
        const EventChannel('flutter_keyboard_visibility'),
        MockStreamHandler.inline(onListen: (_, _) {}));
  });

  group('cloud mode', () {
    late _GatedFs fs;
    late FakeAuth auth;
    late MedicineProvider m;
    setUp(() async {
      fs = _GatedFs();
      auth = FakeAuth('a');
      fs.docs[medsA] = {'items': ['Para', 'Ravi Kumar', 'ravi kumar', ' Ravi Kumar x', 'Amox']};
      m = MedicineProvider(auth: auth, firestore: fs);
    });

    test('MR-01 removes only that entry with arrayRemove on settings/medicines (merge), '
        'legacy doc untouched', () async {
      await m.load('a');
      expect(m.learnedMedicinesLoaded, isTrue);
      fs.log.clear();
      Map<String, dynamic>? sent;
      fs.writeGate = null;
      await m.removeLearnedMedicine('Ravi Kumar');
      sent = fs.docs[medsA];
      expect(fs.log, ['set:$medsA:merge']);
      expect(sent!['items'], FieldValue.arrayRemove(['Ravi Kumar']),
          reason: 'must not write the whole list');
      expect(fs.docs.containsKey('doctors/a'), isFalse);
      expect(m.frequentMedicines, ['Para', 'ravi kumar', 'Ravi Kumar x', 'Amox'],
          reason: 'exact match only: case/whitespace variants untouched, order kept');
    });

    test('MR-02 an absent name is a no-op (no write, no notify)', () async {
      await m.load('a');
      fs.log.clear();
      var notified = 0;
      m.addListener(() => notified++);
      await m.removeLearnedMedicine('Nope');
      await m.removeLearnedMedicine('ravi KUMAR');
      expect(fs.log, isEmpty);
      expect(notified, 0);
    });

    test('MR-03 refused before load: throws, nothing written, list unchanged', () async {
      expect(m.learnedMedicinesLoaded, isFalse);
      await expectLater(m.removeLearnedMedicine('Para'), throwsStateError);
      expect(fs.log, isEmpty);
      expect(_cloudItems(fs, medsA), hasLength(5));
    });

    test('MR-04 refused after a FAILED load (flag not set in catch)', () async {
      fs.failReads = StateError('offline');
      await m.load('a');
      expect(m.learnedMedicinesLoaded, isFalse);
      fs.failReads = null;
      fs.log.clear();
      await expectLater(m.removeLearnedMedicine('Para'), throwsStateError);
      expect(fs.log, isEmpty);
    });

    test('MR-05 a failed cloud write restores the entry at the same position and rethrows',
        () async {
      await m.load('a');
      final before = [...m.frequentMedicines];
      fs.failWrites = StateError('permission-denied');
      await expectLater(m.removeLearnedMedicine('Ravi Kumar'), throwsStateError);
      expect(m.frequentMedicines, before);
    });

    test('MR-06 legacy profile path load also sets the flag', () async {
      fs.docs.remove(medsA);
      fs.docs['doctors/a'] = {'frequentMedicines': ['Para', 'Ravi Kumar']};
      await m.load('a');
      expect(m.learnedMedicinesLoaded, isTrue);
      await m.removeLearnedMedicine('Ravi Kumar');
      expect(m.frequentMedicines, ['Para']);
    });

    test('MR-07 doctor A then B: clear() resets the flag; a removal before B loads is refused',
        () async {
      fs.docs[medsB] = {'items': ['B1', 'B2']};
      await m.load('a');
      m.clear();
      expect(m.learnedMedicinesLoaded, isFalse);
      auth.signIn('b');
      fs.log.clear();
      await expectLater(m.removeLearnedMedicine('Para'), throwsStateError,
          reason: "next doctor's removal ran against the previous list");
      expect(fs.log, isEmpty);
      await m.load('b');
      expect(m.frequentMedicines, ['B1', 'B2']);
      expect(m.learnedMedicinesLoaded, isTrue);
    });

    test("MR-08 A's in-flight removal that fails after the switch does not restore A's list "
        "into B's", () async {
      fs.docs[medsB] = {'items': ['B1']};
      await m.load('a');
      fs.writeGate = Completer<void>();
      final pending = m.removeLearnedMedicine('Ravi Kumar');
      m.clear();
      auth.signIn('b');
      await m.load('b');
      fs.failWrites = StateError('permission-denied');
      fs.writeGate!.complete();
      await expectLater(pending, throwsStateError);
      expect(m.frequentMedicines, ['B1']);
      expect(_cloudItems(fs, medsB), ['B1']);
    });

    test('MR-09 the dev/local owner never writes to the cloud', () async {
      final local = FakeLocalDatabase()..state = const DbReady('local');
      local.settings[key] = jsonEncode(['Para', 'Ravi Kumar']);
      final dev = MedicineProvider(auth: FakeAuth('local'), firestore: fs, localDb: local);
      await dev.load('local');
      fs.log.clear();
      if (dev.learnedMedicinesLoaded) {
        await dev.removeLearnedMedicine('Ravi Kumar');
      }
      expect(fs.log.where((l) => l.startsWith('set:')), isEmpty);
    });

    test('MR-13 (failing-first) an add before B\'s list loads must not overwrite B\'s stored '
        'list', () async {
      fs.docs[medsB] = {'items': ['B1', 'B2']};
      await m.load('a');
      m.clear();
      auth.signIn('b');
      await m.addMedicineIfNew('Cetirizine 10mg');
      // ignore: avoid_print
      print('MR-13 observed: B stored=${_cloudItems(fs, medsB)} log=${fs.log}');
      expect(_cloudItems(fs, medsB), containsAll(['B1', 'B2']),
          reason: "B's stored suggestions were overwritten by an add before B's list loaded");
    }, skip: _ffSkip);
  });

  group('MR-14 add after a failed load', () {
    test('MR-14 (failing-first) an add after B\'s load FAILED must not overwrite B\'s stored list',
        () async {
      final fs = _GatedFs();
      fs.docs[medsB] = {'items': ['B1', 'B2']};
      final m = MedicineProvider(auth: FakeAuth('b'), firestore: fs);
      fs.failReads = StateError('unavailable');
      await m.load('b');
      expect(m.learnedMedicinesLoaded, isFalse);
      fs.failReads = null;
      await m.addMedicineIfNew('Cetirizine 10mg');
      // ignore: avoid_print
      print('MR-14 observed: B stored=${_cloudItems(fs, medsB)}');
      expect(_cloudItems(fs, medsB), containsAll(['B1', 'B2']),
          reason: 'add after a failed load replaced the stored list');
    }, skip: _ffSkip);
  });

  group('local (dev) mode', () {
    late _RefusingSettingsDb db;
    MedicineProvider make() => MedicineProvider(cloudSync: false, localDb: db);
    setUp(() {
      db = _RefusingSettingsDb()..state = const DbReady('a');
      db.settings[key] = jsonEncode(['Para', 'Ravi Kumar', 'Amox']);
    });

    test('MR-10 removal persists across a restart (new provider on the same DB)', () async {
      final m = make();
      await m.load('a');
      await m.removeLearnedMedicine('Ravi Kumar');
      expect(jsonDecode(db.settings[key]!), ['Para', 'Amox']);
      final again = make();
      await again.load('a');
      expect(again.frequentMedicines, ['Para', 'Amox']);
    });

    test('MR-11 a refused local write restores the entry and rethrows', () async {
      final m = make();
      await m.load('a');
      db.refusePut = true;
      await expectLater(m.removeLearnedMedicine('Ravi Kumar'), throwsStateError);
      expect(m.frequentMedicines, ['Para', 'Ravi Kumar', 'Amox']);
      expect(jsonDecode(db.settings[key]!), ['Para', 'Ravi Kumar', 'Amox']);
    });

    test('MR-12 refused while the DB read failed (not open): nothing written', () async {
      db.state = const DbClosed();
      final m = make();
      await m.load('a');
      expect(m.learnedMedicinesLoaded, isFalse);
      db.state = const DbReady('a');
      final puts = db.puts;
      await expectLater(m.removeLearnedMedicine('Para'), throwsStateError);
      expect(db.puts, puts);
    });
  });

  group('screen, real provider (local mode)', () {
    late _RefusingSettingsDb db;
    late MedicineProvider meds;
    const rxHint = 'Type medicine name...';
    Finder rx() => find.widgetWithText(TextField, rxHint);
    Finder sugg(String n) => find.widgetWithText(ListTile, n);

    Future<void> open(WidgetTester t) async {
      t.view.physicalSize = const Size(1080, 4000);
      t.view.devicePixelRatio = 2.0;
      addTearDown(t.view.reset);
      db = _RefusingSettingsDb()..state = const DbReady('a');
      db.settings[key] = jsonEncode(['Ravi Kumar', 'Rabeprazole 20mg']);
      meds = MedicineProvider(cloudSync: false, localDb: db);
      await t.runAsync(() => meds.load('a'));
      await t.pumpWidget(MultiProvider(providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: _OnePatient()),
        ChangeNotifierProvider<MedicineProvider>.value(value: meds),
      ], child: const MaterialApp(home: AddRecordScreen(patientId: 'p1'))));
      await t.pumpAndSettle();
      await t.tap(rx());
      await t.enterText(rx(), 'Ra');
      await t.pump(const Duration(milliseconds: 600));
      await t.pumpAndSettle();
      expect(sugg('Ravi Kumar'), findsOneWidget);
    }

    testWidgets('MR-W1 long-press + Remove: stored list updated, suggestion gone', (t) async {
      await open(t);
      await t.longPress(sugg('Ravi Kumar'));
      await t.pumpAndSettle();
      expect(find.text('Remove from suggestions?'), findsOneWidget);
      await t.tap(find.widgetWithText(TextButton, 'Remove'));
      await t.pumpAndSettle();
      expect(jsonDecode(db.settings[key]!), ['Rabeprazole 20mg']);
      expect(sugg('Ravi Kumar'), findsNothing);
      expect(t.widget<TextField>(rx()).controller!.text, 'Ra', reason: 'prescription untouched');
    });

    testWidgets('MR-W2 dismissing the dialog (barrier tap / back) removes nothing', (t) async {
      await open(t);
      await t.longPress(sugg('Ravi Kumar'));
      await t.pumpAndSettle();
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(find.text('Remove from suggestions?'), findsNothing);
      await t.longPress(sugg('Ravi Kumar'));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(jsonDecode(db.settings[key]!), ['Ravi Kumar', 'Rabeprazole 20mg']);
      expect(meds.frequentMedicines, contains('Ravi Kumar'));
    });

    testWidgets('MR-W3 a tap still selects and removes nothing', (t) async {
      await open(t);
      await t.tap(sugg('Ravi Kumar'));
      await t.pumpAndSettle();
      expect(t.widget<TextField>(rx()).controller!.text, contains('Ravi Kumar'));
      expect(find.text('Remove from suggestions?'), findsNothing);
      expect(meds.frequentMedicines, ['Ravi Kumar', 'Rabeprazole 20mg']);
    });

    testWidgets('MR-W4 a refused write shows the message and keeps the suggestion', (t) async {
      await open(t);
      db.refusePut = true;
      await t.longPress(sugg('Ravi Kumar'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(TextButton, 'Remove'));
      await t.pumpAndSettle();
      expect(find.text("Couldn't remove it from suggestions. Try again in a moment."),
          findsOneWidget);
      expect(meds.frequentMedicines, ['Ravi Kumar', 'Rabeprazole 20mg']);
      expect(t.takeException(), isNull);
    });
  });
}
