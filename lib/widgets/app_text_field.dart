import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// Text field in the app's style.
///
/// [private] is for clinical and personal text: it turns off keyboard
/// learning, autocorrect, suggestions and smart punctuation (security
/// review C12). Use it for every patient, visit and profile field.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.hint,
    required this.icon,
    this.label,
    this.keyboardType,
    this.maxLines = 1,
    this.minLines,
    this.enabled = true,
    this.validator,
    this.inputFormatters,
    this.textCapitalization = TextCapitalization.none,
    this.private = false,
    this.textColor,
    this.fillColor,
    this.textInputAction,
    this.onFieldSubmitted,
    this.suffixText,
    this.focusNode,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final String hint;
  final IconData? icon;
  /// Floating label. When null the field shows only its hint.
  final String? label;
  final TextInputType? keyboardType;
  final int maxLines;
  final int? minLines;
  final bool enabled;
  final FormFieldValidator<String>? validator;
  final List<TextInputFormatter>? inputFormatters;
  final TextCapitalization textCapitalization;
  final bool private;
  final Color? textColor;
  final Color? fillColor;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onFieldSubmitted;
  final String? suffixText;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      autofocus: autofocus,
      keyboardType: keyboardType,
      maxLines: maxLines,
      minLines: minLines,
      enabled: enabled,
      validator: validator,
      inputFormatters: inputFormatters,
      textCapitalization: textCapitalization,
      textInputAction: textInputAction,
      onFieldSubmitted: onFieldSubmitted,
      enableIMEPersonalizedLearning: !private,
      autocorrect: !private,
      enableSuggestions: !private,
      smartDashesType: private ? SmartDashesType.disabled : null,
      smartQuotesType: private ? SmartQuotesType.disabled : null,
      style: context.type.bodyLarge?.copyWith(color: textColor ?? (enabled ? c.ink : c.inkSecondary)),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        suffixText: suffixText,
        prefixIcon: icon == null ? null : Icon(icon, size: 20),
        fillColor: fillColor ?? (enabled ? c.surface : c.sunken),
        alignLabelWithHint: maxLines > 1,
      ),
    );
  }
}
