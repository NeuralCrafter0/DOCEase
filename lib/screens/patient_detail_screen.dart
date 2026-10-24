import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../providers/patient_provider.dart';
import '../providers/doctor_provider.dart';
import '../models/patient.dart';
import '../utils/pdf_export.dart';
import 'add_patient_screen.dart';
import 'add_record_screen.dart';

class PatientDetailScreen extends StatelessWidget {
  final String patientId;
  const PatientDetailScreen({super.key, required this.patientId});

  Future<void> _makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(launchUri)) await launchUrl(launchUri);
  }

  void _shareVisitSummary(BuildContext context, dynamic doctor, Patient patient, VisitRecord record) {
    final String docName = doctor != null ? "${doctor.title} ${doctor.name}" : "Doctor";
    final String message = "*Visit Summary - DOCEase*\n*Patient:* ${patient.name}\n*Date:* ${DateFormat('dd MMM yyyy').format(record.date)}\n*Type:* ${record.visitType}\n\n*Vitals:* BP: ${record.bp ?? 'N/A'}, Temp: ${record.temp ?? 'N/A'}\n*Diagnosis:* ${record.diagnosis}\n*Prescription:* ${record.prescription}\n\n*Dr. $docName*";
    Share.share(message);
  }

  void _showModernDeletePatientConfirm(BuildContext context, PatientProvider provider, Patient patient) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      backgroundColor: Colors.white,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.1), shape: BoxShape.circle), child: const Icon(Icons.delete_forever_rounded, color: Colors.redAccent, size: 40)),
            const SizedBox(height: 24),
            const Text('Delete Patient Profile?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
            const SizedBox(height: 12),
            Text('This will permanently remove ${patient.name} and all clinical history. This action is irreversible.', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF64748B))),
            const SizedBox(height: 32),
            Row(children: [
              Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF475569))))),
              const SizedBox(width: 16),
              Expanded(child: ElevatedButton(onPressed: () { provider.deletePatient(patient.id); Navigator.pop(ctx); Navigator.pop(context); }, style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))), child: const Text('Delete All', style: TextStyle(fontWeight: FontWeight.bold)))),
            ])
          ],
        ),
      ),
    );
  }

  void _showModernDeleteRecordConfirm(BuildContext context, PatientProvider provider, String pId, String rId) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(32))),
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 40),
            const SizedBox(height: 16),
            const Text('Delete Visit Record?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Are you sure you want to remove this specific clinical note?'),
            const SizedBox(height: 32),
            Row(children: [
              Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))),
              const SizedBox(width: 16),
              Expanded(child: ElevatedButton(onPressed: () { provider.deleteRecord(pId, rId); Navigator.pop(ctx); Navigator.pop(context); }, style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white), child: const Text('Delete'))),
            ])
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final doctor = Provider.of<DoctorProvider>(context).currentDoctor;
    return Consumer<PatientProvider>(
      builder: (ctx, provider, _) {
        final patient = provider.findById(patientId);
        final family = provider.patients.where((p) => p.phone == patient.phone && p.id != patient.id).toList();
        final lastVisit = patient.history.isNotEmpty ? patient.history.first : null;

        return Scaffold(
          backgroundColor: const Color(0xFFF8FAFC),
          appBar: AppBar(
            title: Text(patient.name, style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
            backgroundColor: Colors.transparent, elevation: 0,
            actions: [
              IconButton(icon: const Icon(Icons.edit_outlined, color: Color(0xFF6366F1)), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (c) => AddPatientScreen(existingPatient: patient)))),
              IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: () => _showModernDeletePatientConfirm(context, provider, patient)),
              IconButton(
                icon: const Icon(Icons.picture_as_pdf_outlined, color: Color(0xFF6366F1)), 
                // Passed the Doctor object to the PDF generator here:
                onPressed: () => PdfExport.generateAndPrintPatientReport(patient, doctor: doctor),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _buildProfessionalInfoCard(patient, lastVisit),
              if (family.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Row(children: [Icon(Icons.family_restroom_outlined, size: 18, color: Color(0xFF10B981)), SizedBox(width: 8), Text('Family Network', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569)))]),
                const SizedBox(height: 12),
                SizedBox(height: 50, child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: family.length, itemBuilder: (ctx, i) => _buildFamilyChip(context, family[i]))),
              ],
              const SizedBox(height: 32),
              const Row(children: [Icon(Icons.history_edu_outlined, size: 20, color: Color(0xFF6366F1)), SizedBox(width: 8), Text('Clinical Timeline', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))]),
              const SizedBox(height: 16),
              Expanded(child: patient.history.isEmpty ? const Center(child: Text('No Clinical Records Available')) : ListView.builder(padding: const EdgeInsets.only(bottom: 100), itemCount: patient.history.length, itemBuilder: (ctx, i) => _buildClinicalTimeline(context, doctor, patient, patient.history[i], i == 0, provider))),
            ]),
          ),
          floatingActionButton: FloatingActionButton.extended(backgroundColor: const Color(0xFF6366F1), foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)), icon: const Icon(Icons.add_moderator_outlined, size: 20), label: const Text('Add Clinical Note'), onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (ctx) => AddRecordScreen(patientId: patientId)))),
        );
      },
    );
  }

  Widget _buildFamilyChip(BuildContext context, Patient familyMember) {
    return GestureDetector(
      onTap: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (c) => PatientDetailScreen(patientId: familyMember.id))),
      child: Container(margin: const EdgeInsets.only(right: 12), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(30), border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.2))), child: Row(children: [Text(familyMember.name, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF065F46), fontSize: 13)), const SizedBox(width: 6), Text('(${familyMember.relation})', style: const TextStyle(color: Color(0xFF10B981), fontSize: 11))])),
    );
  }

  Widget _buildProfessionalInfoCard(Patient patient, VisitRecord? lastVisit) {
    return Container(padding: const EdgeInsets.all(24), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [_buildDataPoint('Age', '${patient.age} Yrs', Icons.cake_outlined), _buildDataPoint('Relation', patient.relation, Icons.people_outline), _buildDataPoint('Last Visit', lastVisit != null ? DateFormat('dd MMM').format(lastVisit.date) : 'N/A', Icons.history_outlined)]), const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Divider(color: Color(0xFFF1F5F9))), InkWell(onTap: () => _makePhoneCall(patient.phone), borderRadius: BorderRadius.circular(12), child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12)), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.call_outlined, color: Color(0xFF10B981), size: 18), const SizedBox(width: 12), Text(patient.phone, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF1E293B)))])))]));
  }

  Widget _buildDataPoint(String label, String value, IconData icon) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(icon, size: 14, color: const Color(0xFF94A3B8)), const SizedBox(width: 4), Text(label, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontWeight: FontWeight.bold))]), const SizedBox(height: 4), Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: Color(0xFF1E293B)))]);
  }

  Widget _buildClinicalTimeline(BuildContext context, dynamic doctor, Patient patient, VisitRecord record, bool isLatest, PatientProvider provider) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Column(children: [Container(width: 10, height: 10, decoration: BoxDecoration(color: isLatest ? const Color(0xFF6366F1) : const Color(0xFFE2E8F0), shape: BoxShape.circle)), Container(width: 2, height: (record.bp != null && record.bp!.isNotEmpty) ? 160 : 120, color: const Color(0xFFF1F5F9))]),
      const SizedBox(width: 16),
      Expanded(child: GestureDetector(
        onTap: () => _showRecordDetails(context, doctor, patient, record, provider),
        child: Container(
          padding: const EdgeInsets.all(16), margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFF1F5F9))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(DateFormat('MMM dd, yyyy').format(record.date), style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8), fontSize: 11)),
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: isLatest ? const Color(0xFFEEF2FF) : const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8)), child: Text(record.visitType, style: TextStyle(color: isLatest ? const Color(0xFF6366F1) : Colors.grey, fontSize: 10, fontWeight: FontWeight.bold))),
              ]),
              const SizedBox(height: 8),
              Text(record.diagnosis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF1E293B))),
              if (record.bp != null && record.bp!.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(children: [_buildSmallVitalChip('BP', record.bp!), const SizedBox(width: 8), if (record.temp != null && record.temp!.isNotEmpty) _buildSmallVitalChip('T', record.temp!)]),
              ],
              const SizedBox(height: 8),
              Text(record.symptoms, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF64748B), fontSize: 13)),
            ],
          ),
        ),
      )),
    ]);
  }

  Widget _buildSmallVitalChip(String label, String val) {
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFE2E8F0))), child: Text('$label: $val', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF475569))));
  }

  void _showRecordDetails(BuildContext context, dynamic doctor, Patient patient, VisitRecord record, PatientProvider provider) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (ctx) => Container(
      height: MediaQuery.of(context).size.height * 0.85, decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(24))), padding: const EdgeInsets.all(24.0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text("${DateFormat('EEEE, MMM dd, yyyy').format(record.date)} • ${record.visitType}", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF6366F1))), Text(record.diagnosis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 24, color: Color(0xFF1E293B)))])),
          Row(children: [
            IconButton(onPressed: () { Navigator.pop(ctx); Navigator.push(context, MaterialPageRoute(builder: (c) => AddRecordScreen(patientId: patient.id, existingRecord: record))); }, icon: const Icon(Icons.edit_outlined, color: Color(0xFF6366F1))),
            IconButton(onPressed: () => _showModernDeleteRecordConfirm(context, provider, patient.id, record.id), icon: const Icon(Icons.delete_outline, color: Colors.redAccent)),
            IconButton(onPressed: () => _shareVisitSummary(context, doctor, patient, record), icon: const Icon(Icons.share_outlined, color: Color(0xFF6366F1))),
          ]),
        ]),
        const Divider(height: 40),
        Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (record.bp != null && record.bp!.isNotEmpty) _buildProfessionalDetail('Patient Vitals', "BP: ${record.bp} | Temp: ${record.temp} | Pulse: ${record.pulse} | Weight: ${record.weight}", Icons.monitor_heart_outlined),
          _buildProfessionalDetail('Chief Symptoms', record.symptoms, Icons.subject_rounded),
          _buildProfessionalDetail('Clinical Prescription', record.prescription, Icons.medication_outlined, isSpecial: true),
          if (record.notes != null && record.notes!.isNotEmpty) _buildProfessionalDetail('Clinical Notes', record.notes!, Icons.edit_note_rounded),
          if (record.attachmentPaths.isNotEmpty) ...[
            const Text('Attachments', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1E293B), fontSize: 16)),
            const SizedBox(height: 16),
            SizedBox(
              height: 200,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: record.attachmentPaths.length,
                itemBuilder: (ctx, idx) {
                  final path = record.attachmentPaths[idx];
                  final isNetwork = path.startsWith('http');
                  return Padding(
                    padding: const EdgeInsets.only(right: 12.0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: isNetwork
                          ? Image.network(path, width: 150, height: 200, fit: BoxFit.cover)
                          : Image.file(File(path), width: 150, height: 200, fit: BoxFit.cover),
                    ),
                  );
                },
              ),
            ),
          ]
        ]))),
      ]),
    ));
  }

  Widget _buildProfessionalDetail(String label, String value, IconData icon, {bool isSpecial = false}) {
    return Padding(padding: const EdgeInsets.only(bottom: 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Icon(icon, size: 16, color: const Color(0xFF94A3B8)), const SizedBox(width: 8), Text(label, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF94A3B8), fontSize: 12))]), const SizedBox(height: 10), Container(width: double.infinity, padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: isSpecial ? const Color(0xFFF5F3FF) : const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(12), border: Border.all(color: isSpecial ? const Color(0xFFDDD6FE) : const Color(0xFFF1F5F9))), child: Text(value, style: TextStyle(fontSize: 15, height: 1.5, fontWeight: isSpecial ? FontWeight.w700 : FontWeight.normal, color: isSpecial ? const Color(0xFF6366F1) : const Color(0xFF1E293B))))]));
  }
}
