import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';
import '../models/patient.dart';
import '../models/doctor.dart';
import 'test_data_marker.dart';
import 'doctor_name.dart';
import 'visit_order.dart';

class PdfExport {
  /// Marker printed at the top and bottom of every page in dev mode.
  static const testDataMarker = kTestDataMarker;

  /// [testData] (dev mode) puts [testDataMarker] on every page and in the
  /// file name, so a dev-build letter can never pass as a real record.
  static Future<void> generateAndPrintPatientReport(Patient patient,
      {Doctor? doctor, bool testData = false}) async {
    final pdf = buildPatientReport(patient, doctor: doctor, testData: testData);
    // Dev mode only adds the TEST_DATA_ prefix; the rest is #7's neutral
    // reportFileName scheme, which wins on merge.
    await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
        name: printFileName(patient, DateTime.now(), testData: testData));
  }

  /// The name offered by the print dialog: [reportFileName], with
  /// `TEST_DATA_` in front in dev mode.
  static String printFileName(Patient patient, DateTime now, {required bool testData}) {
    final name = reportFileName(patient, now);
    return testData ? '$kTestDataFilePrefix$name' : name;
  }

  /// Non-identifying file name for the print / "Save as PDF" dialog
  /// (security review C6): `report_<first 8 id chars>_<yyyymmdd>.pdf`.
  /// Never contains the patient's name.
  // Same code as #7 (PdfExport.reportFileName); #7's version wins on merge.
  static String reportFileName(Patient patient, DateTime now) {
    final cleanId = patient.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    final shortId = cleanId.isEmpty ? 'patient' : cleanId.substring(0, cleanId.length < 8 ? cleanId.length : 8);
    return 'report_${shortId}_${DateFormat('yyyyMMdd').format(now)}.pdf';
  }

  static pw.Widget _testDataBand() => pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.symmetric(vertical: 4),
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        color: PdfColors.red700,
        child: pw.Center(
            child: pw.Text(testDataMarker,
                style: pw.TextStyle(color: PdfColors.white, fontSize: 12, fontWeight: pw.FontWeight.bold))),
      );

  /// The report document ([compress] false only for tests that read it).
  static pw.Document buildPatientReport(Patient patient,
      {Doctor? doctor, bool testData = false, bool compress = true}) {
    final pdf = pw.Document(compress: compress);

    final String docName = doctorDisplayName(doctor) ?? "Clinical Practitioner";
    final String clinicName = doctor?.clinicName ?? "DOCEase Medical Center";
    final String docSpecialty = doctor?.specialty ?? "General Medicine";
    final String docContact = doctor?.mobileNumber ?? "";
    final String docEmail = doctor?.email ?? "";

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: testData ? (pw.Context context) => _testDataBand() : null,
        footer: testData ? (pw.Context context) => _testDataBand() : null,
        build: (pw.Context context) {
          return [
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(clinicName, style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
                    pw.SizedBox(height: 4),
                    pw.Text(docName, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
                    pw.Text(docSpecialty, style: const pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
                    if (docContact.isNotEmpty) pw.Text('Mob: $docContact', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
                    if (docEmail.isNotEmpty) pw.Text('Email: $docEmail', style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text('CLINICAL REPORT', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, letterSpacing: 1.5, color: PdfColors.grey500)),
                    pw.SizedBox(height: 4),
                    pw.Text('Date: ${DateFormat('dd MMM yyyy').format(DateTime.now())}'),
                  ],
                ),
              ],
            ),
            pw.SizedBox(height: 24),
            pw.Divider(color: PdfColors.grey300, thickness: 1.5),
            pw.SizedBox(height: 24),
            pw.Container(
              padding: const pw.EdgeInsets.all(12),
              decoration: pw.BoxDecoration(color: PdfColors.grey100, borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8))),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text('PATIENT DETAILS', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.grey600)),
                      pw.SizedBox(height: 4),
                      pw.Text(patient.name, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
                      pw.Text('Contact: ${patient.phone} (${patient.relation})'),
                    ],
                  ),
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.end,
                    children: [
                      pw.Text('Age: ${patient.age} Yrs', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                      pw.Text('Gender: ${patient.gender}'),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 32),
            pw.Text('CLINICAL TIMELINE', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColors.blue900)),
            pw.SizedBox(height: 16),
            if (patient.history.isEmpty) pw.Center(child: pw.Text('No clinical records available.'))
            else ...patient.history.newestFirst().map((record) => _buildPdfVisitCard(record)),
            pw.Spacer(),
            pw.Divider(color: PdfColors.grey300),
            pw.SizedBox(height: 8),
            pw.Center(child: pw.Text('Confidential Medical Record - Generated by DOCEase', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey500))),
          ];
        },
      ),
    );

    return pdf;
  }

  static pw.Widget _buildPdfVisitCard(VisitRecord record) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 20),
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8))),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(DateFormat('EEEE, dd MMM yyyy').format(record.date), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.grey700)),
              pw.Container(padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: const pw.BoxDecoration(color: PdfColors.blue50, borderRadius: pw.BorderRadius.all(pw.Radius.circular(4))), child: pw.Text(record.visitType, style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.blue800))),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Text('Diagnosis:', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600, fontWeight: pw.FontWeight.bold)),
          pw.Text(record.diagnosis, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          if (_hasVitals(record)) ...[
            pw.SizedBox(height: 12),
            pw.Text('Vitals:', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Row(children: [
              if (record.bp != null && record.bp!.isNotEmpty) _buildVitalPdfChip('BP', record.bp!),
              if (record.temp != null && record.temp!.isNotEmpty) _buildVitalPdfChip('Temp', record.temp!),
              if (record.pulse != null && record.pulse!.isNotEmpty) _buildVitalPdfChip('Pulse', record.pulse!),
              if (record.weight != null && record.weight!.isNotEmpty) _buildVitalPdfChip('Weight', record.weight!),
            ]),
          ],
          pw.SizedBox(height: 12),
          pw.Text('Symptoms:', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600, fontWeight: pw.FontWeight.bold)),
          pw.Text(record.symptoms),
          pw.SizedBox(height: 12),
          pw.Text('Prescription & Treatment:', style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600, fontWeight: pw.FontWeight.bold)),
          pw.Container(width: double.infinity, padding: const pw.EdgeInsets.all(8), margin: const pw.EdgeInsets.only(top: 4), decoration: pw.BoxDecoration(color: PdfColors.grey50, border: pw.Border.all(color: PdfColors.grey200)), child: pw.Text(record.prescription, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.blue900))),
        ],
      ),
    );
  }

  static bool _hasVitals(VisitRecord record) => (record.bp != null && record.bp!.isNotEmpty) || (record.temp != null && record.temp!.isNotEmpty) || (record.pulse != null && record.pulse!.isNotEmpty) || (record.weight != null && record.weight!.isNotEmpty);
  static pw.Widget _buildVitalPdfChip(String label, String val) => pw.Container(margin: const pw.EdgeInsets.only(right: 8), padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey400), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4))), child: pw.Text('$label: $val', style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)));
}
