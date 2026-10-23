// QA final pass: the login screen's Google logo came from the web
// (upload.wikimedia.org) with no fallback, so it was missing offline. It is
// now a bundled asset. (That Wikimedia thumbnail size is also refused today:
// HTTP 400 "Use thumbnail sizes listed on https://w.wiki/GHai".)
import 'dart:convert';
import 'dart:io';

import 'package:docease/screens/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const logo = 'assets/images/google_g_logo.png';

void main() {
  testWidgets('the Google button shows the bundled logo, not a network image', (t) async {
    await t.pumpWidget(const MaterialApp(home: LoginScreen()));
    await t.pump();
    final images = t.widgetList<Image>(find.byType(Image)).toList();
    expect(images.where((i) => i.image is NetworkImage), isEmpty);
    final asset = images.map((i) => i.image).whereType<AssetImage>().map((a) => a.assetName);
    expect(asset, contains(logo));
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  test('the logo asset is bundled and is a PNG', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final data = await rootBundle.load(logo);
    expect(data.lengthInBytes, greaterThan(0));
    expect(data.buffer.asUint8List().sublist(1, 4), 'PNG'.codeUnits);
  });

  // allowMalformed: main still has #3's cp1252 bullet until #3 merges.
  test('no screen loads an image from a hard-coded web address', () {
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"Image\.network\(\s*'https?://").allMatches(utf8.decode(f.readAsBytesSync(), allowMalformed: true))) {
        hits.add('${f.path}: ${m.group(0)}');
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
