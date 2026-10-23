import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import '../models/patient.dart';
import '../providers/patient_provider.dart';
import '../providers/medicine_provider.dart';

class AddRecordScreen extends StatefulWidget {
  final String patientId;
  final VisitRecord? existingRecord;
  const AddRecordScreen({super.key, required this.patientId, this.existingRecord});

  @override
  State<AddRecordScreen> createState() => _AddRecordScreenState();
}

class _AddRecordScreenState extends State<AddRecordScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _symptomsController;
  late TextEditingController _diagnosisController;
  late TextEditingController _prescriptionController;
  late TextEditingController _bpController;
  late TextEditingController _tempController;
  late TextEditingController _pulseController;
  late TextEditingController _weightController;
  late TextEditingController _sugarController;
  
  late DateTime _selectedDate;
  late String _selectedVisitType;
  late List<String> _attachmentPaths;
  final ImagePicker _picker = ImagePicker();
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final r = widget.existingRecord;
    _symptomsController = TextEditingController(text: r?.symptoms ?? '');
    _diagnosisController = TextEditingController(text: r?.diagnosis ?? '');
    _prescriptionController = TextEditingController(text: r?.prescription ?? '');
    _bpController = TextEditingController(text: r?.bp ?? '');
    _tempController = TextEditingController(text: r?.temp ?? '');
    _pulseController = TextEditingController(text: r?.pulse ?? '');
    _weightController = TextEditingController(text: r?.weight ?? '');
    _sugarController = TextEditingController(text: r?.sugar ?? '');
    _selectedDate = r?.date ?? DateTime.now();
    _selectedVisitType = r?.visitType ?? 'Initial Visit';
    _attachmentPaths = List.from(r?.attachmentPaths ?? []);
  }

  void _repeatLastVisit() {
    final patient = Provider.of<PatientProvider>(context, listen: false).findById(widget.patientId);
    if (patient.history.isNotEmpty) {
      final last = patient.history.first;
      setState(() {
        _symptomsController.text = last.symptoms;
        _diagnosisController.text = last.diagnosis;
        _prescriptionController.text = last.prescription;
        _bpController.text = last.bp ?? '';
        _tempController.text = last.temp ?? '';
        _pulseController.text = last.pulse ?? '';
        _weightController.text = last.weight ?? '';
        _sugarController.text = last.sugar ?? '';
        _selectedVisitType = 'Follow-up';
      });
    }
  }

  Future<void> _saveRecord() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isSaving = true);
      
      // Save frequent medicine to list
      final medProvider = Provider.of<MedicineProvider>(context, listen: false);
      if (_prescriptionController.text.isNotEmpty) {
        medProvider.addMedicineIfNew(_prescriptionController.text.split('\n').first);
      }

      final record = VisitRecord(
        id: widget.existingRecord?.id, date: _selectedDate, visitType: _selectedVisitType,
        symptoms: _symptomsController.text, diagnosis: _diagnosisController.text, prescription: _prescriptionController.text,
        bp: _bpController.text, temp: _tempController.text, pulse: _pulseController.text, weight: _weightController.text, sugar: _sugarController.text,
        attachmentPaths: _attachmentPaths,
      );
      
      final provider = Provider.of<PatientProvider>(context, listen: false);
      if (widget.existingRecord == null) await provider.addRecord(widget.patientId, record);
      else await provider.updateRecord(widget.patientId, record);
      
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final medProvider = Provider.of<MedicineProvider>(context);

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Clinical Note', style: TextStyle(fontWeight: FontWeight.w900)),
        backgroundColor: Colors.transparent, elevation: 0,
        actions: [
          if (widget.existingRecord == null)
            TextButton.icon(onPressed: _repeatLastVisit, icon: const Icon(Icons.history_rounded, size: 18), label: const Text('Repeat Last', style: TextStyle(fontWeight: FontWeight.bold))),
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildLabel('Visit Date'),
            _buildDatePicker(),
            const SizedBox(height: 24),
            _buildLabel('Visit Type'),
            _buildHighPerfSelector(['Initial Visit', 'Follow-up', 'Routine'], _selectedVisitType, (v) => setState(() => _selectedVisitType = v)),
            const SizedBox(height: 32),
            _buildLabel('Patient Vitals'),
            _buildVitalsGrid(),
            const SizedBox(height: 32),
            _buildLabel('Clinical Details'),
            _buildModernInput(_symptomsController, 'Chief Symptoms', Icons.sick_outlined, maxLines: 2),
            const SizedBox(height: 20),
            _buildModernInput(_diagnosisController, 'Diagnosis', Icons.biotech_outlined, maxLines: 2),
            const SizedBox(height: 32),
            _buildLabel('Prescription Builder'),
            _buildSmartPrescriptionField(medProvider),
            const SizedBox(height: 12),
            _buildDosageTemplates(medProvider),
            const SizedBox(height: 48),
            _isSaving ? const Center(child: CircularProgressIndicator()) : ElevatedButton(onPressed: _saveRecord, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), minimumSize: const Size(double.infinity, 64), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))), child: const Text('Save Clinical Record', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }

  Widget _buildDatePicker() {
    return GestureDetector(
      onTap: () async {
        final d = await showDatePicker(context: context, initialDate: _selectedDate, firstDate: DateTime(2000), lastDate: DateTime.now());
        if (d != null) setState(() => _selectedDate = d);
      },
      child: Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE2E8F0))), child: Row(children: [const Icon(Icons.calendar_month_outlined, color: Color(0xFF6366F1), size: 20), const SizedBox(width: 12), Text(DateFormat('EEEE, dd MMM yyyy').format(_selectedDate), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF1E293B)))]))
    );
  }

  Widget _buildSmartPrescriptionField(MedicineProvider medProvider) {
    return TypeAheadField<String>(
      controller: _prescriptionController,
      builder: (context, controller, focusNode) => TextField(
        controller: controller,
        focusNode: focusNode,
        enableIMEPersonalizedLearning: false,
        maxLines: 4,
        style: const TextStyle(fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          hintText: 'Type medicine name...',
          prefixIcon: const Icon(Icons.medication_outlined, color: Color(0xFF6366F1), size: 20),
          filled: true, fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200)),
        ),
      ),
      suggestionsCallback: (pattern) {
        if (pattern.isEmpty) return [];
        return medProvider.frequentMedicines.where((m) => m.toLowerCase().contains(pattern.toLowerCase())).toList();
      },
      itemBuilder: (context, suggestion) => ListTile(title: Text(suggestion), leading: const Icon(Icons.history, size: 16)),
      onSelected: (suggestion) {
        setState(() {
          final currentText = _prescriptionController.text;
          // Replace partial typing with full medicine name
          _prescriptionController.text = suggestion;
        });
      },
    );
  }

  Widget _buildDosageTemplates(MedicineProvider provider) {
    return Wrap(
      spacing: 8,
      children: provider.dosageTemplates.map((t) => ActionChip(
        label: Text(t, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFFEEF2FF),
        side: BorderSide.none,
        onPressed: () {
          setState(() {
            _prescriptionController.text = '${_prescriptionController.text} - $t\n';
          });
        },
      )).toList(),
    );
  }

  Widget _buildVitalsGrid() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24), border: Border.all(color: const Color(0xFFE2E8F0))),
      child: Column(children: [
        Row(children: [
          Expanded(child: _buildVitalInput(_bpController, 'BP', '120/80')),
          const SizedBox(width: 16),
          Expanded(child: _buildVitalInput(_tempController, 'Temp', '98.6 F')),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _buildVitalInput(_pulseController, 'Pulse', '72 bpm')),
          const SizedBox(width: 16),
          Expanded(child: _buildVitalInput(_weightController, 'Weight', 'kg')),
        ]),
      ]),
    );
  }

  Widget _buildVitalInput(TextEditingController controller, String label, String hint) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
      const SizedBox(height: 6),
      TextField(controller: controller, enableIMEPersonalizedLearning: false, decoration: InputDecoration(hintText: hint, hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade300), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade100)))),
    ]);
  }

  Widget _buildLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 10, left: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))));

  Widget _buildModernInput(TextEditingController controller, String hint, IconData icon, {int maxLines = 1}) {
    // Clinical text: no keyboard learning (security review C12).
    return TextFormField(controller: controller, maxLines: maxLines, enableIMEPersonalizedLearning: false, style: const TextStyle(fontWeight: FontWeight.w700), decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon, color: const Color(0xFF6366F1), size: 20), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))));
  }

  Widget _buildHighPerfSelector(List<String> options, String selectedValue, Function(String) onSelected) {
    final selectedIndex = options.indexOf(selectedValue);
    return Container(
      height: 54, padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(18)),
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth / options.length;
        return Stack(children: [
          AnimatedPositioned(duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic, left: selectedIndex * width, top: 0, bottom: 0, width: width, child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]))),
          Row(children: options.map((opt) {
            final isSelected = selectedValue == opt;
            return Expanded(child: GestureDetector(onTap: () => onSelected(opt), behavior: HitTestBehavior.opaque, child: Center(child: Text(opt, style: TextStyle(fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600, color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF64748B), fontSize: 12)))));
          }).toList()),
        ]);
      }),
    );
  }

  Widget _buildIconButton(IconData icon, String label, VoidCallback onTap) {
    return Expanded(child: GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(vertical: 16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(children: [Icon(icon, color: const Color(0xFF6366F1)), const SizedBox(height: 4), Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))]))));
  }

  Widget _buildThumbnail(String path) {
    final isNetwork = path.startsWith('http');
    return Padding(padding: const EdgeInsets.only(right: 12), child: Stack(children: [ClipRRect(borderRadius: BorderRadius.circular(16), child: isNetwork ? Image.network(path, width: 100, height: 120, fit: BoxFit.cover) : Image.file(File(path), width: 100, height: 120, fit: BoxFit.cover)), Positioned(right: 4, top: 4, child: GestureDetector(onTap: () => setState(() => _attachmentPaths.remove(path)), child: const CircleAvatar(radius: 12, backgroundColor: Colors.redAccent, child: Icon(Icons.close, size: 14, color: Colors.white))))]));
  }
}
