// ConfirmSheet (UI map step 2): result values and screen-reader output.
import 'package:docease/widgets/confirm_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Future<bool>> _open(WidgetTester t) async {
  late Future<bool> result;
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = ConfirmSheet.show(
            context,
            title: 'Delete Patient Profile?',
            message: 'This will permanently remove Asha.',
            confirmLabel: 'Delete All',
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('confirm gives true', (t) async {
    final result = await _open(t);
    expect(find.text('This will permanently remove Asha.'), findsOneWidget);
    await t.tap(find.text('Delete All'));
    await t.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.text('Delete All'), findsNothing);
  });

  testWidgets('cancel gives false', (t) async {
    final result = await _open(t);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('dismissing by tapping outside gives false, not null', (t) async {
    final result = await _open(t);
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    expect(await result, isFalse);
  });

  testWidgets('title is announced as a heading', (t) async {
    final handle = t.ensureSemantics();
    await _open(t);
    final data = t.getSemantics(find.text('Delete Patient Profile?')).getSemanticsData();
    expect(data.flagsCollection.isHeader, isTrue);
    handle.dispose();
  });
}
