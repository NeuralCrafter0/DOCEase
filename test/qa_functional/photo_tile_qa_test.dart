// QA checks for #8 ed77169 (STALE-05 screen side): the neutral "Photo saved"
// tile in AddRecordScreen's visit-form thumbnails.
//   TILE-01 no path / exception text anywhere in the SEMANTICS tree
//   TILE-02 remove (x) on the tile works; save keeps only the other photo
//   TILE-03 small screen + large text: no layout overflow (1.3x, 2.0x)
//   TILE-04 network thumbnail OFFLINE (SocketException, not the test 400)
//   TILE-05 a Storage path entry (what the form holds after backend's swap)
//   TILE-06 INFO: the remove (x) has no semantics label / button role
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
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _Editing extends PatientProvider {
  VisitRecord? updated;
  @override
  Patient findById(String id) => Patient(id: 'p1', name: 'A', age: '1', gender: 'Male', phone: '');
  @override
  Future<void> updateRecord(String patientId, VisitRecord record) async => updated = record;
}

class _NoMeds extends MedicineProvider {
  @override
  List<String> get frequentMedicines => const [];
  @override
  Future<void> addMedicineIfNew(String med) async {}
}

/// Offline: every connection fails like a phone with no network.
class _OfflineClient implements HttpClient {
  int attempts = 0;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    attempts++;
    throw SocketException('Failed host lookup: ${url.host}', osError: const OSError('No address', 7));
  }
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

const tileKey = ValueKey('photo-unavailable-tile');
const cloudKey = ValueKey('photo-cloud-tile');

/// Line of the tile's Column in add_record_screen.dart, found from source so
/// the test does not hard-code it.
final int? _tileLine = () {
  final lines = File('lib/screens/add_record_screen.dart').readAsLinesSync();
  // c9d4cd8: both stand-in tiles are built by _photoTile; its Column is the tile.
  var k = lines.indexWhere((l) => l.contains('Widget _photoTile('));
  if (k < 0) k = lines.indexWhere((l) => l.contains("ValueKey('photo-unavailable-tile')"));
  if (k < 0) return null;
  for (var i = k; i < k + 25 && i < lines.length; i++) {
    if (lines[i].contains('Column(')) return i + 1;
  }
  return null;
}();
const storagePath = 'clinical_attachments/u1/p1/0b7f6c2e-4d1a-4c3b-9e8f-2a1b3c4d5e6f.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async {
    await Firebase.initializeApp();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
        const EventChannel('flutter_keyboard_visibility'),
        MockStreamHandler.inline(onListen: (_, _) {}));
  });

  late Directory base;
  late AttachmentStorage storage;
  late _Editing patients;
  late String present, missing;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('qa_tile_');
    storage = AttachmentStorage(ownerId: 'u1', baseDirectory: () async => base, excludeFromBackup: (_) async {});
    final dir = await storage.directory();
    present = (File('${dir.path}/present.jpg')
          ..writeAsBytesSync(File('test/fixtures/attachments/rot6.jpg').readAsBytesSync()))
        .path;
    missing = '${dir.path}/2ef7bf08-dde4-4950-8a84-60172329aea7.jpg';
    patients = _Editing();
    imageCache.clear();
    imageCache.clearLiveImages();
  });
  tearDown(() {
    debugNetworkImageHttpClientProvider = null;
    base.deleteSync(recursive: true);
  });

  VisitRecord visitWith(List<String> paths) => VisitRecord(
      id: 'v1', date: DateTime(2026, 3, 1), visitType: 'Follow-up',
      symptoms: 's', diagnosis: 'URTI', prescription: 'rx', attachmentPaths: paths);

  Future<void> settle(WidgetTester t, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
  }

  Future<void> open(WidgetTester t, VisitRecord record,
      {required int tiles, Size size = const Size(1080, 4400), double dpr = 2.0, double scale = 1.0}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = dpr;
    addTearDown(t.view.reset);
    await t.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider<PatientProvider>.value(value: patients),
        ChangeNotifierProvider<MedicineProvider>.value(value: _NoMeds()),
      ],
      child: MaterialApp(
        builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => Navigator.push(ctx, MaterialPageRoute(
                builder: (_) => AddRecordScreen(
                    patientId: 'p1', existingRecord: record, attachmentStorage: storage))),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    await settle(t, () => find.byKey(tileKey).evaluate().length >= tiles);
  }

  /// Every label/value/hint/tooltip in the semantics tree.
  List<String> semanticsStrings(WidgetTester t) {
    final out = <String>[];
    void walk(SemanticsNode n) {
      final d = n.getSemanticsData();
      for (final s in [d.label, d.value, d.hint, d.tooltip, d.increasedValue, d.decreasedValue]) {
        if (s.isNotEmpty) out.add(s);
      }
      n.visitChildren((c) {
        walk(c);
        return true;
      });
    }
    walk(t.getSemantics(find.byType(AddRecordScreen)));
    return out;
  }

  void expectNothingLeaks(WidgetTester t, List<String> strings, {List<String> extra = const []}) {
    final forbidden = [
      base.path, '2ef7bf08', 'present.jpg', 'clinical_attachments', 'storage.invalid', 'http',
      'Exception', 'Error', 'errno', 'Failed host', 'No address', 'PathNotFound', 'OS Error', ...extra
    ];
    for (final s in strings) {
      for (final f in forbidden) {
        expect(s.contains(f), isFalse, reason: 'semantics string "$s" leaks "$f"');
      }
    }
  }

  Finder xOnTile() => find.descendant(
      of: find.ancestor(of: find.byKey(tileKey), matching: find.byType(Stack)).first,
      matching: find.byIcon(Icons.close));

  testWidgets('TILE-01 semantics tree: tile label is exactly "Photo saved"; no path or error '
      'text anywhere', (t) async {
    final h = t.ensureSemantics();
    await open(t, visitWith([missing, present]), tiles: 1);
    final strings = semanticsStrings(t);
    expect(strings.where((s) => s == 'Photo saved'), hasLength(1), reason: '$strings');
    expectNothingLeaks(t, strings);
    expect(t.takeException(), isNull);
    h.dispose();
  });

  testWidgets('TILE-02 remove on the tile: tile gone, other photo kept, save stores only it',
      (t) async {
    await open(t, visitWith([present, missing]), tiles: 1);
    expect(xOnTile(), findsOneWidget);
    await t.tap(xOnTile());
    await t.pump();
    expect(find.byKey(tileKey), findsNothing);
    await t.tap(find.text('Save Clinical Record'));
    await settle(t, () => patients.updated != null && find.byType(AddRecordScreen).evaluate().isEmpty);
    expect(patients.updated!.attachmentPaths, [present]);
    expect(t.takeException(), isNull);
  });

  // Overflow errors grouped by the widget that created them (file:line).
  Future<Map<String, List<String>>> overflowsAt(WidgetTester t, double scale) async {
    final errors = <FlutterErrorDetails>[];
    final prev = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await open(t, visitWith([missing, present]),
          tiles: 1, size: const Size(640, 1136), dpr: 2.0, scale: scale);
      await t.dragUntilVisible(find.byKey(tileKey), find.byType(Scrollable).first, const Offset(0, -200));
      await t.pumpAndSettle();
    } finally {
      FlutterError.onError = prev;
    }
    final out = <String, List<String>>{};
    for (final e in errors.where((e) => e.exceptionAsString().contains('overflowed'))) {
      final m = RegExp(r'(Row|Column|Flex):file://[^ ]*/lib/screens/(add_record_screen\.dart:\d+)')
          .firstMatch(e.toString());
      out.putIfAbsent(m == null ? 'unknown' : '${m.group(1)} ${m.group(2)}', () => [])
          .add(e.exceptionAsString().split('\n').first);
    }
    // ignore: avoid_print
    print('TILE-03 observed at ${scale}x: $out');
    return out;
  }

  bool isTile(String k) => k.startsWith('Column') &&
      (find.byKey(tileKey).evaluate().isNotEmpty || find.byKey(cloudKey).evaluate().isNotEmpty) &&
      _tileLine != null && k.endsWith(':$_tileLine');

  for (final scale in [1.3, 2.0]) {
    testWidgets('TILE-03a small screen (320x568) at ${scale}x text: the "Photo saved" tile '
        'itself does not overflow', (t) async {
      final o = await overflowsAt(t, scale);
      final tile = o.entries.where((e) => isTile(e.key)).toList();
      expect(tile, isEmpty, reason: 'tile overflow: $tile');
      expect(find.byKey(tileKey), findsOneWidget);
    }); // was CONFIRMED on ed77169 (50px at 2.0x); fixed claim on c9d4cd8
    testWidgets('TILE-03b small screen (320x568) at ${scale}x text: rest of the visit form '
        '(pre-existing, not #8) does not overflow', (t) async {
      final o = await overflowsAt(t, scale);
      final rest = o.entries.where((e) => !isTile(e.key)).toList();
      expect(rest, isEmpty, reason: 'form overflow: $rest');
    }); // was failing-first (date Row); #8 c9d4cd8 Expanded date text, merged under #17's Semantics wrapper
  }

  testWidgets('TILE-03c merged layout (#8 x #17) 320x568 at 2.0x: the "Saved to cloud" tile, its '
      'label and "Remove photo" fit; no overflow anywhere in the form', (t) async {
    final errors = <FlutterErrorDetails>[];
    final prev = FlutterError.onError;
    FlutterError.onError = errors.add;
    final h = t.ensureSemantics();
    try {
      await open(t, visitWith([storagePath, present]),
          tiles: 0, size: const Size(640, 1136), dpr: 2.0, scale: 2.0);
      await t.dragUntilVisible(find.byKey(cloudKey), find.byType(Scrollable).first, const Offset(0, -200));
      await t.pumpAndSettle();
    } finally {
      FlutterError.onError = prev;
    }
    final over = errors.where((e) => e.exceptionAsString().contains('overflowed')).map((e) => e.exceptionAsString().split('\n').first).toList();
    // ignore: avoid_print
    print('TILE-03c observed overflows=$over');
    expect(over, isEmpty);
    final tile = t.getRect(find.byKey(cloudKey));
    expect(tile.size, const Size(100, 120));
    final text = find.descendant(of: find.byKey(cloudKey), matching: find.byType(Text));
    final tr = t.getRect(text);
    expect(tile.contains(tr.topLeft) && tile.contains(tr.bottomRight - const Offset(0.01, 0.01)), isTrue,
        reason: 'label $tr inside tile $tile');
    // Visit date text stays inside its field (#8 Expanded under #17 Semantics).
    // Widget-level: the field is scrolled off (semantics-culled) by now.
    final dateSem = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'Visit date');
    expect(dateSem, findsOneWidget, reason: "#17's Semantics wrapper kept in the merge");
    final field = t.getRect(find.descendant(of: dateSem, matching: find.byType(Container)).first);
    final dateText = find.descendant(of: dateSem, matching: find.byWidgetPredicate(
        (w) => w is Text && RegExp(r'\d{4}').hasMatch(w.data ?? '')));
    expect(dateText, findsOneWidget);
    final dr = t.getRect(dateText);
    expect(dr.left >= field.left && dr.right <= field.right + 0.01, isTrue, reason: 'date $dr in field $field');
    expect(find.ancestor(of: dateText, matching: find.byType(Expanded)), findsOneWidget,
        reason: "#8's Expanded date text kept in the merge");
    h.dispose();
  });

  testWidgets('TILE-04 network thumbnail OFFLINE (SocketException) shows the tile, no '
      'error text in widgets or semantics', (t) async {
    final client = _OfflineClient();
    debugNetworkImageHttpClientProvider = () => client;
    final h = t.ensureSemantics();
    await open(t, visitWith(['https://storage.invalid/visit/photo.jpg', present]), tiles: 1);
    expect(client.attempts, greaterThan(0), reason: 'the offline client was used');
    expect(find.byKey(tileKey), findsOneWidget);
    expect(find.textContaining('Failed host'), findsNothing);
    expect(find.textContaining('SocketException'), findsNothing);
    expectNothingLeaks(t, semanticsStrings(t), extra: ['SocketException']);
    expect(find.byIcon(Icons.close), findsNWidgets(2));
    expect(t.takeException(), isNull);
    debugNetworkImageHttpClientProvider = null;
    h.dispose();
  });

  testWidgets('TILE-05 a Storage path entry (form after backend swap) shows the tile, '
      'no path; remove drops it from the save', (t) async {
    final h = t.ensureSemantics();
    await open(t, visitWith([storagePath, present]), tiles: 1);
    expect(find.byKey(cloudKey), findsOneWidget, reason: 'c9d4cd8: a Storage path shows "Saved to cloud"');
    final strings = semanticsStrings(t);
    expect(strings.where((x) => x == 'Saved to cloud'), hasLength(1), reason: '$strings');
    expectNothingLeaks(t, strings, extra: ['clinical_attachments', 'u1/p1', 'token=', 'alt=media', 'googleapis']);
    await t.tap(find.descendant(
        of: find.ancestor(of: find.byKey(cloudKey), matching: find.byType(Stack)).first,
        matching: find.byIcon(Icons.close)));
    await t.pump();
    expect(find.byKey(cloudKey), findsNothing);
    await t.tap(find.text('Save Clinical Record'));
    await settle(t, () => patients.updated != null && find.byType(AddRecordScreen).evaluate().isEmpty);
    expect(patients.updated!.attachmentPaths, [present]);
    expect(patients.updated!.attachmentPaths, isNot(contains(storagePath)));
    expect(t.takeException(), isNull);
    h.dispose();
  });

  testWidgets('TILE-05g download-URL guard (N/A today, recorded): a Storage path is never loaded '
      'in the form - no Image.network / Image.file for it, no HTTP attempt', (t) async {
    final client = _OfflineClient();
    debugNetworkImageHttpClientProvider = () => client;
    await open(t, visitWith([storagePath]), tiles: 0);
    await t.pumpAndSettle();
    expect(find.byKey(cloudKey), findsOneWidget);
    expect(find.byKey(const ValueKey(storagePath)), findsNothing, reason: 'no Image widget keyed by the Storage path');
    expect(find.byType(Image), findsNothing, reason: 'nothing tries to draw the Storage object');
    expect(client.attempts, 0, reason: 'no download URL / network fetch for a Storage path');
    debugNetworkImageHttpClientProvider = null;
    // ignore: avoid_print
    print('TILE-05g N/A: Storage image not loadable in the form until Firebase returns (AttachmentImage swap later)');
  });

  testWidgets('TILE-06 the remove (x) is a "Remove photo" button with a tap action and a '
      '>=48x48 target; a tap at the target corner (outside the circle) removes it', (t) async {
    final h = t.ensureSemantics();
    await open(t, visitWith([missing]), tiles: 1);
    final x = t.getSemantics(xOnTile());
    final d = x.getSemanticsData();
    // ignore: avoid_print
    print('TILE-06 observed: label="${d.label}" tooltip="${d.tooltip}" '
        'button=${d.hasFlag(SemanticsFlag.isButton)} tap=${d.hasAction(SemanticsAction.tap)} '
        'size=${t.getSize(xOnTile())}');
    final node = t.getSemantics(find.bySemanticsLabel('Remove photo'));
    final nd = node.getSemanticsData();
    expect(nd.label, 'Remove photo');
    expect(nd.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(nd.hasAction(SemanticsAction.tap), isTrue);
    final target = find.ancestor(of: xOnTile(), matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == 48 && w.height == 48)).first;
    final r = t.getRect(target);
    expect(r.width >= 48 && r.height >= 48, isTrue, reason: 'target $r');
    final circle = t.getRect(find.ancestor(of: xOnTile(), matching: find.byType(CircleAvatar)).first);
    final corner = r.bottomLeft + const Offset(3, -3);
    expect(circle.contains(corner), isFalse, reason: 'corner tap point must be outside the circle');
    await t.tapAt(corner);
    await t.pump();
    expect(find.byKey(tileKey), findsNothing, reason: 'tap at the 48x48 corner removed the photo');
    h.dispose();
  });
}
