// PrivatePhoneField keeps IntlPhoneField's behaviour for the patient form
// while turning keyboard learning off (QA feature pass F-PRIV-02).
// ignore_for_file: depend_on_referenced_packages
import 'package:docease/widgets/private_phone_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';

void main() {
  Future<GlobalKey<FormState>> pump(WidgetTester t, {ValueChanged<String>? onNumber}) async {
    final form = GlobalKey<FormState>();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Form(
          key: form,
          child: PrivatePhoneField(
            initialCountryCode: 'IN',
            invalidNumberMessage: 'Enter a valid mobile number',
            onChanged: (p) => onNumber?.call(p.completeNumber),
          ),
        ),
      ),
    ));
    return form;
  }

  testWidgets('reports the full number with the country code and checks the length', (t) async {
    String? number;
    final form = await pump(t, onNumber: (n) => number = n);
    expect(find.text('+91'), findsOneWidget);
    await t.enterText(find.byType(TextFormField), '98111');
    await t.pump();
    expect(number, '+9198111');
    expect(form.currentState!.validate(), isFalse);
    await t.pump();
    expect(find.text('Enter a valid mobile number'), findsOneWidget);
    await t.enterText(find.byType(TextFormField), '9811111111');
    await t.pump();
    expect(number, '+919811111111');
    expect(form.currentState!.validate(), isTrue);
  });

  testWidgets('keyboard learning, suggestions and autocorrect are off', (t) async {
    await pump(t);
    final e = t.widget<EditableText>(find.byType(EditableText));
    expect(e.enableSuggestions, isFalse);
    expect(e.autocorrect, isFalse);
    expect(e.enableIMEPersonalizedLearning, isFalse);
    expect(e.keyboardType, TextInputType.phone);
  });

  testWidgets('the flag button opens the country picker', (t) async {
    await pump(t);
    await t.tap(find.byKey(const ValueKey('phone-country-button')));
    await t.pumpAndSettle();
    expect(find.byType(CountryPickerDialog), findsOneWidget);
  });
}
