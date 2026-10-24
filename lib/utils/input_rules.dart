import 'package:flutter/services.dart';

/// Input formatters for free-text profile fields (UI map item 13). They only
/// stop obviously wrong input while typing; validation stays in the form.
class InputRules {
  InputRules._();

  /// A person's name: no digits, at most 60 characters.
  static final List<TextInputFormatter> personName = [
    FilteringTextInputFormatter.deny(RegExp(r'[0-9]')),
    LengthLimitingTextInputFormatter(60),
  ];

  /// An e-mail address: no spaces, at most 100 characters.
  static final List<TextInputFormatter> email = [
    FilteringTextInputFormatter.deny(RegExp(r'\s')),
    LengthLimitingTextInputFormatter(100),
  ];

  /// Short free text such as a specialty or clinic name: at most 80 characters.
  static final List<TextInputFormatter> shortText = [
    LengthLimitingTextInputFormatter(80),
  ];
}
