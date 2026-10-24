import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../ui/components.dart';
import '../ui/qa_keys.dart';

/// Asked before the PDF report leaves the app (print service, share or save
/// from the system dialog). The text is fixed and lists what the report
/// holds; it never shows the data itself (security, 24 Oct). It must match
/// what `PdfExport` really puts in the file: patient details and every visit,
/// without photos or notes.
class ExportConfirmSheet extends StatelessWidget {
  const ExportConfirmSheet({super.key = QaKeys.pdfConfirmSheet});

  static const title = 'Export full report?';
  static const intro = 'The PDF holds the whole record, so treat it like the paper file:';
  static const contents = <(IconData, String)>[
    (Icons.badge_outlined, 'Name, phone number, age and gender'),
    (Icons.event_note_outlined, 'Every visit: diagnosis and symptoms'),
    (Icons.monitor_heart_outlined, 'Vitals and prescriptions'),
  ];
  static const notIncluded = 'Photos and clinical notes are not included.';
  static const after = 'Next, your phone asks where to send, save or print it. Anyone you give it to can read it.';

  /// True only when the doctor tapped Continue.
  static Future<bool> show(BuildContext context) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ExportConfirmSheet(),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.xxl, Space.sm, Space.xxl, Space.xxl),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Align(alignment: Alignment.centerLeft, child: IconMedallion(icon: Icons.picture_as_pdf_outlined, size: 48)),
        const SizedBox(height: Space.lg),
        Semantics(header: true, child: Text(title, style: context.type.titleLarge)),
        const SizedBox(height: Space.sm),
        Text(intro, style: context.type.bodyMedium),
        const SizedBox(height: Space.md),
        for (final (icon, text) in contents)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Row(children: [
              ExcludeSemantics(child: Icon(icon, size: 20, color: c.primary)),
              const SizedBox(width: Space.md),
              Expanded(child: Text(text, style: context.type.bodyLarge)),
            ]),
          ),
        const SizedBox(height: Space.sm),
        Text(notIncluded, style: context.type.bodySmall),
        const SizedBox(height: Space.lg),
        NoticeBanner(icon: Icons.ios_share_rounded, tone: Tone.info, message: after),
        const SizedBox(height: Space.xxl),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              key: QaKeys.pdfConfirmCancel,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: FilledButton(
              key: QaKeys.pdfConfirmConfirm,
              style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(64, 48))),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ),
        ]),
      ]),
    );
  }
}
