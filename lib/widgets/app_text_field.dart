import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Filled white text field with an indigo prefix icon and 20px corners.
///
/// Extracted from the `_buildModernInput` helpers. The profile form uses it
/// now; the patient and clinical-note copies switch over once the PRs that
/// edit them (#5 validation, #7 keyboard privacy) are merged, which is why the
/// widget already takes [validator], [inputFormatters], [textCapitalization]
/// and [private].
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType,
    this.maxLines = 1,
    this.enabled = true,
    this.validator,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
    this.private = false,
    this.textColor,
    this.fillColor = Colors.white,
  });

  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final TextInputType? keyboardType;
  final int maxLines;
  final bool enabled;
  final FormFieldValidator<String>? validator;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;

  /// Patient or clinical text: no keyboard learning, autocorrect, suggestions
  /// or smart punctuation (security review C12).
  final bool private;

  /// Text colour; null keeps the theme default.
  final Color? textColor;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      maxLines: maxLines,
      enabled: enabled,
      validator: validator,
      inputFormatters: inputFormatters,
      textCapitalization: textCapitalization,
      enableIMEPersonalizedLearning: !private,
      autocorrect: !private,
      enableSuggestions: !private,
      smartDashesType: private ? SmartDashesType.disabled : null,
      smartQuotesType: private ? SmartQuotesType.disabled : null,
      style: TextStyle(fontWeight: FontWeight.w700, color: textColor),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
        filled: true,
        fillColor: fillColor,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.field), borderSide: BorderSide(color: Colors.grey.shade200)),
      ),
    );
  }
}
