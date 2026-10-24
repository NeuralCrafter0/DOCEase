// ignore_for_file: depend_on_referenced_packages (platform-interface fakes, as in the other widget tests)
// Profile photo and input rules (UI map item 13): a placeholder instead of a
// blank avatar, camera or gallery as the photo source, and input formatters
// on the free-text fields.
import 'package:docease/models/doctor.dart';
import 'package:docease/providers/doctor_provider.dart';
import 'package:docease/screens/doctor_profile_screen.dart';
import 'package:docease/utils/input_rules.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

class _FakePicker extends ImagePickerPlatform with MockPlatformInterfaceMixin {
  final List<ImageSource> asked = [];
  @override
  Future<XFile?> getImageFromSource({required ImageSource source, ImagePickerOptions options = const ImagePickerOptions()}) async {
    asked.add(source);
    return null; // the doctor backed out of the picker
  }
}

class _Doctor extends DoctorProvider {
  _Doctor(this.doc);
  final Doctor? doc;
  @override
  Doctor? get currentDoctor => doc;
  @override
  bool get isLoading => false;
  @override
  Future<void> fetchDoctorProfile() async {}
}

final _doc = Doctor(id: 'd1', title: 'MR', name: 'John', email: 'john@clinic.test', age: '45', mobileNumber: '+919812345678', specialty: 'General Medicine', clinicName: 'City Clinic', practiceMode: 'Solo Practice');

Future<void> _pump(WidgetTester t, {Doctor? doc}) async {
  t.view.physicalSize = const Size(1200, 2800);
  t.view.devicePixelRatio = 2.0;
  addTearDown(t.view.reset);
  final prev = FlutterError.onError;
  FlutterError.onError = (d) {
    // Test font overflow stripes, and the fake photo URL that never loads.
    if (d.exceptionAsString().contains('overflowed by') || d.exception is NetworkImageLoadException) return;
    prev?.call(d);
  };
  addTearDown(() => FlutterError.onError = prev);
  await t.pumpWidget(ChangeNotifierProvider<DoctorProvider>.value(
    value: _Doctor(doc),
    child: const MaterialApp(home: DoctorProfileScreen()),
  ));
  await t.pumpAndSettle();
}

String _apply(List<TextInputFormatter> rules, String typed) {
  var v = TextEditingValue.empty;
  for (final f in rules) {
    v = f.formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: typed, selection: TextSelection.collapsed(offset: typed.length)));
    typed = v.text;
  }
  return typed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  setUpAll(() async => Firebase.initializeApp());

  testWidgets('no photo: the avatar shows a person icon, not an empty circle', (t) async {
    await _pump(t, doc: _doc);
    expect(find.byIcon(Icons.person_rounded), findsOneWidget);
    expect(find.bySemanticsLabel('No profile photo'), findsOneWidget);
  });

  testWidgets('a saved photo hides the placeholder', (t) async {
    await _pump(t, doc: Doctor(id: 'd1', title: 'MR', name: 'John', email: 'j@c.test', age: '45', mobileNumber: '+919812345678', specialty: 'GP', clinicName: 'C', practiceMode: 'Solo Practice', profileImageUrl: 'https://example.invalid/p.jpg'));
    expect(find.byIcon(Icons.person_rounded), findsNothing);
  });

  testWidgets('camera button offers camera and gallery; gallery is used when picked', (t) async {
    final picker = _FakePicker();
    ImagePickerPlatform.instance = picker;
    await _pump(t); // no profile yet, so the form starts unlocked
    await t.tap(find.byIcon(Icons.camera_alt));
    await t.pumpAndSettle();
    expect(find.text('Take photo'), findsOneWidget);
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(t.getTopLeft(find.text('Take photo')).dy, lessThan(t.getTopLeft(find.text('Choose from gallery')).dy), reason: 'camera listed first');
    await t.tap(find.text('Choose from gallery'));
    await t.pumpAndSettle();
    expect(picker.asked, [ImageSource.gallery]);
  });

  testWidgets('closing the source sheet picks nothing', (t) async {
    final picker = _FakePicker();
    ImagePickerPlatform.instance = picker;
    await _pump(t);
    await t.tap(find.byIcon(Icons.camera_alt));
    await t.pumpAndSettle();
    await t.tapAt(const Offset(20, 20));
    await t.pumpAndSettle();
    expect(find.text('Take photo'), findsNothing);
    expect(picker.asked, isEmpty);
  });

  group('input rules', () {
    test('name: digits dropped, 60 chars max', () {
      expect(_apply(InputRules.personName, 'John 2 Smith'), 'John  Smith');
      expect(_apply(InputRules.personName, 'a' * 70).length, 60);
    });
    test('email: spaces dropped, 100 chars max', () {
      expect(_apply(InputRules.email, 'john @clinic.test '), 'john@clinic.test');
      expect(_apply(InputRules.email, 'a' * 120).length, 100);
    });
    test('short text: 80 chars max, punctuation kept', () {
      expect(_apply(InputRules.shortText, "St. Mary's / OPD-2"), "St. Mary's / OPD-2");
      expect(_apply(InputRules.shortText, 'a' * 90).length, 80);
    });

    testWidgets('profile fields use them', (t) async {
      await _pump(t);
      Future<String> typeInto(String hint, String text) async {
        final f = find.widgetWithText(TextFormField, hint);
        await t.enterText(f, text);
        await t.pump();
        return t.widget<TextFormField>(f).controller!.text;
      }
      expect(await typeInto('Full Name', 'John 2'), 'John ');
      expect(await typeInto('Clinical Email', 'j @c.test'), 'j@c.test');
      expect((await typeInto('Specialty', 'x' * 90)).length, 80);
      expect((await typeInto('Clinic / Hospital', 'y' * 90)).length, 80);
      expect(await typeInto('Yrs', '45a'), '45', reason: 'Age keeps its own rule');
    });
  });
}
