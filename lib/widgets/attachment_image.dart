import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/patient_provider.dart';
import '../services/attachments.dart';

/// Shows one visit attachment, whatever form it is stored in:
/// a Storage path (`clinical_attachments/{uid}/{patientId}/...`, downloaded
/// through the Storage SDK so the security rules apply), a legacy download
/// URL in this doctor's folder, or a local file on this phone. Anything
/// else (foreign URLs, other doctors' paths, missing files) shows a
/// placeholder instead of being loaded.
class AttachmentImage extends StatefulWidget {
  const AttachmentImage({
    super.key,
    required this.entry,
    required this.patientId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String entry;
  final String patientId;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  Future<Uint8List?>? _bytes;
  String? _loadedFor;

  Widget _placeholder() => Container(
        width: widget.width,
        height: widget.height,
        color: const Color(0xFFF1F5F9),
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image_outlined, color: Color(0xFF94A3B8)),
      );

  Widget _error(BuildContext context, Object error, StackTrace? stack) => _placeholder();

  @override
  Widget build(BuildContext context) {
    final provider = context.read<PatientProvider>();
    final entry = widget.entry;
    switch (provider.attachmentKind(entry, widget.patientId)) {
      case AttachmentEntryKind.storagePath:
        if (_loadedFor != entry) {
          _loadedFor = entry;
          _bytes = provider.loadAttachmentBytes(entry);
        }
        return FutureBuilder<Uint8List?>(
          future: _bytes,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return SizedBox(
                width: widget.width,
                height: widget.height,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            final data = snap.data;
            if (data == null) return _placeholder();
            return Image.memory(data,
                width: widget.width, height: widget.height, fit: widget.fit, errorBuilder: _error);
          },
        );
      case AttachmentEntryKind.legacyDownloadUrl:
        return Image.network(entry,
            width: widget.width, height: widget.height, fit: widget.fit, errorBuilder: _error);
      case AttachmentEntryKind.localFile:
        return Image.file(File(entry),
            width: widget.width, height: widget.height, fit: widget.fit, errorBuilder: _error);
      case AttachmentEntryKind.invalid:
        return _placeholder();
    }
  }
}
