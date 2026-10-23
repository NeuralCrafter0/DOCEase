import 'package:intl/intl.dart';

import '../models/patient.dart';

/// Parts of a visit the doctor can choose to include when sharing outside
/// the app. Date and visit type are always included.
enum ShareField { patientName, vitals, diagnosis, prescription }

extension ShareFieldLabel on ShareField {
  String get label => switch (this) {
        ShareField.patientName => 'Patient name',
        ShareField.vitals => 'Vitals',
        ShareField.diagnosis => 'Diagnosis',
        ShareField.prescription => 'Prescription',
      };
}

class VisitShareText {
  VisitShareText._();

  /// Builds the WhatsApp-style summary with only the selected [fields].
  /// [signOff] (e.g. the doctor's name) is appended when not null/empty.
  static String build({
    required Patient patient,
    required VisitRecord record,
    required Set<ShareField> fields,
    String? signOff,
  }) {
    final b = StringBuffer('*Visit Summary - DOCEase*');
    if (fields.contains(ShareField.patientName)) b.write('\n*Patient:* ${patient.name}');
    b.write('\n*Date:* ${DateFormat('dd MMM yyyy').format(record.date)}');
    b.write('\n*Type:* ${record.visitType}');
    final details = <String>[
      if (fields.contains(ShareField.vitals)) '*Vitals:* BP: ${record.bp ?? 'N/A'}, Temp: ${record.temp ?? 'N/A'}',
      if (fields.contains(ShareField.diagnosis)) '*Diagnosis:* ${record.diagnosis}',
      if (fields.contains(ShareField.prescription)) '*Prescription:* ${record.prescription}',
    ];
    if (details.isNotEmpty) b.write('\n\n${details.join('\n')}');
    if (signOff != null && signOff.trim().isNotEmpty) b.write('\n\n*$signOff*');
    return b.toString();
  }
}
