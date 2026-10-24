import 'package:firebase_core/firebase_core.dart';

import '../providers/local_database.dart';
import 'attachments.dart';

/// A short, sanitized description of [e] for logs: an error code or type
/// name, never the exception's message. Raw DB errors can contain SQL,
/// bound arguments (keys) or patient data; Firebase messages can contain
/// document paths.
String errorCode(Object e) => switch (e) {
      DbOpenException(:final error) => 'DbOpenException(${error.name})',
      FirebaseException(:final plugin, :final code) => '$plugin/$code',
      UnsupportedAttachmentException(:final reason) => 'UnsupportedAttachment(${reason.name})',
      _ => e.runtimeType.toString(),
    };
