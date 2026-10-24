import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Bold label above a form field or selector.
///
/// Extracted from the identical `_buildLabel` helpers in the patient, clinical
/// note and profile forms.
class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 4),
      child: Semantics(header: true, child: Text(text, style: AppText.label)),
    );
  }
}
