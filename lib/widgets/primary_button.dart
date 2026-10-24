import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Full-width dark call-to-action (64px tall, 24px corners, bold 18px label):
/// "Register", "Save Clinical Record", "Save and Lock Profile".
///
/// The profile form uses it now; the patient and clinical-note buttons switch
/// over once #5 and #8, which edit those lines, are merged.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.ink,
        minimumSize: const Size(double.infinity, 64),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.button)),
      ),
      child: Text(label, style: AppText.button),
    );
  }
}
