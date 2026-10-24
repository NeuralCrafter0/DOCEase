import 'package:flutter/material.dart';

import '../utils/visit_share_text.dart';

/// Confirmation shown before visit details leave the app (security review
/// C6). Lets the doctor choose what to include. Every field starts unticked
/// (PR #7 review), so nothing identifying leaves the app without a deliberate
/// choice, and Share stays disabled until something is ticked. Pops with the
/// chosen fields, or null when cancelled.
class ShareConfirmSheet extends StatefulWidget {
  final String patientName;
  const ShareConfirmSheet({super.key, required this.patientName});

  /// Shows the sheet; returns the selected fields, or null if cancelled.
  static Future<Set<ShareField>?> show(BuildContext context, {required String patientName}) {
    return showModalBottomSheet<Set<ShareField>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      backgroundColor: Colors.white,
      builder: (_) => ShareConfirmSheet(patientName: patientName),
    );
  }

  @override
  State<ShareConfirmSheet> createState() => _ShareConfirmSheetState();
}

class _ShareConfirmSheetState extends State<ShareConfirmSheet> {
  final Set<ShareField> _fields = {};

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.privacy_tip_outlined, color: Color(0xFFF59E0B)),
              SizedBox(width: 12),
              Expanded(child: Text('Share outside DOCEase?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: Color(0xFF1E293B)))),
            ]),
            const SizedBox(height: 12),
            Text(
              "You are about to send ${widget.patientName}'s visit details outside DOCEase. "
              'The app you pick may keep a copy. Choose what to include:',
              style: const TextStyle(color: Color(0xFF64748B), height: 1.4),
            ),
            const SizedBox(height: 8),
            for (final f in ShareField.values)
              CheckboxListTile(
                key: ValueKey('share-field-${f.name}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(f.label, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: f.detail == null ? null : Text(f.detail!, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                value: _fields.contains(f),
                onChanged: (on) => setState(() => on == true ? _fields.add(f) : _fields.remove(f)),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold)))),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _fields.isEmpty ? null : () => Navigator.pop(context, {..._fields}),
                  icon: const Icon(Icons.share_outlined, size: 18),
                  label: const Text('Share', style: TextStyle(fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}
