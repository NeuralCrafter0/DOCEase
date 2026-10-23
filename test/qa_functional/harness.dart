import 'package:docease/services/current_owner.dart';
import 'package:docease/utils/attachment_storage.dart';
// QA functional pass harness (local only, not committed).
// Real providers + real screens + DOCEaseApp(devMode: true), over the #13
// in-memory LocalDatabase fake. Every Firebase entry point is a tripwire.
// ignore_for_file: subtype_of_sealed_class
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/config/dev_mode.dart';
import 'package:docease/main.dart';
import 'package:docease/models/patient.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:docease/services/local_photo_store.dart';
import 'package:docease/services/session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../backend/fakes.dart';

final hits = <String>[];

class TripAuth implements FirebaseAuth {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('auth.${i.memberName}');
    throw StateError('FirebaseAuth touched in dev mode');
  }
}

class TripFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('firestore.${i.memberName}');
    throw StateError('Firestore touched in dev mode');
  }
}

class TripStorage implements FirebaseStorage {
  @override
  dynamic noSuchMethod(Invocation i) {
    hits.add('storage.${i.memberName}');
    throw StateError('Storage touched in dev mode');
  }
}

class TripHelper extends FakeFirestoreHelper {
  @override
  Future<bool> syncPatient(Patient patient) async {
    hits.add('helper.sync');
    return false;
  }

  @override
  Future<bool> deletePatient(String patientId) async {
    hits.add('helper.delete');
    return false;
  }

  @override
  Future<List<Patient>> fetchAllPatients() async {
    hits.add('helper.fetch');
    return [];
  }
}

/// The "encrypted file on disk": survives restarts because the same instance
/// is reused. Writes can be refused like a full disk / counter failure.
class QaDb extends SessionDb {
  bool refuseUpdates = false;
  bool failPutSetting = false;

  @override
  Future<String?> updatePatient(Patient patient) async {
    if (refuseUpdates) throw UnsyncedCounterException(kLocalOwnerId);
    return super.updatePatient(patient);
  }

  @override
  Future<void> putSetting(String key, String value) async {
    if (failPutSetting) throw StateError('disk full');
    settings[key] = value;
  }

  @override
  Future<String?> getSetting(String key) async => settings[key];
}

class Rig {
  Rig(this.db, this.photos);
  final QaDb db;
  final LocalPhotoStore photos;
  late PatientProvider patients;
  late DoctorProvider doctor;
  late MedicineProvider medicines;
  late SessionController session;
}

/// Pumps frames without waiting for infinite animations to stop.
Future<void> settle(WidgetTester t, [int frames = 30]) async {
  for (var i = 0; i < frames; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// Loads Roboto (Android's Material font) and the Material icon font, so
/// text widths match a phone; the default test font has wider glyphs and
/// would report overflows that do not happen on a device.
Future<void> loadRealFonts() async {
  const dir = '/opt/flutter-3.41.2/bin/cache/artifacts/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black', 'Light', 'Italic', 'BoldItalic', 'MediumItalic']) {
    final f = File('$dir/Roboto-$w.ttf');
    if (f.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(File('$dir/MaterialIcons-Regular.otf').readAsBytesSync())));
  await icons.load();
}

/// Logical phone size used by every test (360x780 dp at 3x: the most common
/// Android width). Override per test for small-phone checks.
Size phoneSize = const Size(360, 780);

Future<Rig> boot(WidgetTester t, {QaDb? db, required Directory support}) async {
  // #8 merge wiring, same line as main() on qa-merged3 (tests do not run main()).
  AttachmentStorage.currentOwnerId = () => CurrentOwner.id;
  t.view.devicePixelRatio = 3.0;
  t.view.physicalSize = phoneSize * 3.0;
  addTearDown(t.view.reset);
  // flutter_typeahead listens to keyboard visibility; no platform in tests.
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(const MethodChannel('flutter_keyboard_visibility'), (_) async => null);
  final photos = LocalPhotoStore(supportDir: () async => support);
  await t.runAsync(photos.init);
  final rig = Rig(db ?? QaDb(), photos);
  rig.patients = PatientProvider(
      db: rig.db,
      cloudSync: false,
      photos: photos,
      firestore: TripHelper(),
      auth: TripAuth(),
      storage: TripStorage(),
      retryBaseDelay: const Duration(milliseconds: 5),
      retryMaxDelay: const Duration(milliseconds: 10));
  rig.doctor = DoctorProvider(
      cloudSync: false, localDb: rig.db, photos: photos,
      auth: TripAuth(), firestore: TripFirestore(), storage: TripStorage());
  rig.medicines = MedicineProvider(
      cloudSync: false, localDb: rig.db, auth: TripAuth(), firestore: TripFirestore());
  rig.session = SessionController.localOnly(
      db: rig.db,
      patients: rig.patients,
      doctor: rig.doctor,
      medicines: rig.medicines,
      observeAppLifecycle: false);
  await t.runAsync(() => rig.session.idle);
  await t.pumpWidget(MultiProvider(providers: [
    ChangeNotifierProvider<PatientProvider>.value(value: rig.patients),
    ChangeNotifierProvider<DoctorProvider>.value(value: rig.doctor),
    ChangeNotifierProvider<MedicineProvider>.value(value: rig.medicines),
    ChangeNotifierProvider<SessionController>.value(value: rig.session),
  ], child: const DevMode(enabled: true, child: DOCEaseApp(ready: true, devMode: true))));
  await settle(t);
  return rig;
}

/// App restart: unmount, close the DB, start fresh providers on the same DB.
Future<Rig> restart(WidgetTester t, Rig rig, Directory support) async {
  await t.pumpWidget(const SizedBox());
  await t.runAsync(() => rig.db.close());
  return boot(t, db: rig.db, support: support);
}

Finder field(String hintOrLabel) => find.byWidgetPredicate((w) =>
    w is TextField &&
    (w.decoration?.hintText == hintOrLabel || w.decoration?.labelText == hintOrLabel));

Future<void> type(WidgetTester t, String hint, String text) async {
  final f = field(hint);
  expect(f, findsWidgets, reason: 'no TextField with hint/label "$hint"');
  await t.enterText(f.first, text);
  await t.pump();
}

Future<void> tapText(WidgetTester t, String text) async {
  final f = find.text(text);
  expect(f, findsWidgets, reason: 'no "$text" on screen');
  await t.ensureVisible(f.first);
  await t.pump();
  await t.tap(f.first);
  await settle(t);
}

/// Taps the top-most (last built) icon, e.g. inside an open bottom sheet.
Future<void> tapIconLast(WidgetTester t, IconData icon) async {
  final f = find.byIcon(icon);
  expect(f, findsWidgets, reason: 'no icon $icon on screen');
  await t.tap(f.last);
  await settle(t);
}

Future<void> tapIcon(WidgetTester t, IconData icon) async {
  final f = find.byIcon(icon);
  expect(f, findsWidgets, reason: 'no icon $icon on screen');
  await t.tap(f.first);
  await settle(t);
}

/// Seeds a patient straight into the DB (as if saved earlier), then restarts
/// so the app loads it the normal way.
Patient seedPatient(QaDb db, String id, String name,
    {String phone = '+919876543210', String age = '40', String gender = 'Male',
    String relation = 'Self', List<VisitRecord>? history}) {
  final p = Patient(id: id, name: name, age: age, gender: gender, phone: phone,
      relation: relation, history: history ?? []);
  db.rows[id] = p;
  db.dirty[id] = true;
  db.versions[id] = '1';
  return p;
}

VisitRecord visitOn(String id, DateTime date,
        {String diagnosis = 'Viral fever', String symptoms = 'fever',
        String prescription = 'Paracetamol 500mg', String type = 'Consultation',
        String? bp, String? pulse, String? temp, String? weight, String? sugar}) =>
    VisitRecord(
        id: id, date: date, visitType: type, symptoms: symptoms,
        diagnosis: diagnosis, prescription: prescription, bp: bp, pulse: pulse,
        temp: temp, weight: weight, sugar: sugar, attachmentPaths: const []);

/// Captures every debugPrint line for the log-privacy checks.
final logLines = <String>[];
DebugPrintCallback? _origPrint;
void captureLogs() {
  logLines.clear();
  _origPrint = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) {
    if (m != null) logLines.add(m);
  };
}

void restoreLogs() {
  if (_origPrint != null) debugPrint = _origPrint!;
}

/// Fake 'net.nfet.printing' platform: records printPdf, then asks the Dart
/// side for the bytes via onLayout (like the real plugin) and completes.
class FakePrinter {
  final calls = <Map<Object?, Object?>>[];
  Uint8List? lastPdf;
  static const _ch = MethodChannel('net.nfet.printing');

  void install() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_ch, (call) async {
      if (call.method == 'printingInfo') {
        return {'canPrint': true, 'canShare': true, 'canRaster': true,
          'canListPrinters': false, 'directPrint': false, 'dynamicLayout': true};
      }
      if (call.method != 'printPdf') return null;
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      calls.add(args);
      final job = args['job'];
      scheduleMicrotask(() async {
        final codec = const StandardMethodCodec();
        final reply = Completer<ByteData?>();
        await m.handlePlatformMessage(
            'net.nfet.printing',
            codec.encodeMethodCall(MethodCall('onLayout', {
              'job': job, 'width': 595.0, 'height': 842.0,
              'marginLeft': 0.0, 'marginTop': 0.0, 'marginRight': 0.0, 'marginBottom': 0.0,
            })),
            reply.complete);
        final data = await reply.future;
        if (data != null) {
          final bytes = codec.decodeEnvelope(data);
          if (bytes is Uint8List) lastPdf = bytes;
        }
        await m.handlePlatformMessage(
            'net.nfet.printing',
            codec.encodeMethodCall(MethodCall('onCompleted', {'job': job, 'completed': true, 'error': null})),
            (_) {});
      });
      return 1;
    });
  }
}

/// Fake share_plus platform channel: records what would be shared.
class FakeShare {
  final calls = <MethodCall>[];
  static const _ch = MethodChannel('dev.fluttercommunity.plus/share');
  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, (call) async {
      calls.add(call);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
  }

  String get lastText {
    final a = calls.last.arguments;
    if (a is Map) return '${a['text'] ?? a['uri'] ?? a}';
    return '$a';
  }
}
