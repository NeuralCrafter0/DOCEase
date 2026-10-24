import 'dart:io';
import '../services/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import '../models/patient.dart';
import '../providers/patient_provider.dart';
import '../providers/medicine_provider.dart';
import '../utils/prescription_lines.dart';
import '../utils/visit_order.dart';
import '../utils/attachment_processor.dart';
import '../utils/attachment_storage.dart';

class AddRecordScreen extends StatefulWidget {
  final String patientId;
  final VisitRecord? existingRecord;
  /// Converts picked photos to JPEG files. Injectable for tests.
  final AttachmentProcessor? attachmentProcessor;
  /// Owner folder used to delete saved photos the doctor removed. Defaults
  /// to the current owner's. Injectable for tests.
  final AttachmentStorage? attachmentStorage;
  const AddRecordScreen({super.key, required this.patientId, this.existingRecord, this.attachmentProcessor, this.attachmentStorage});

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
  /// Null when nobody is signed in (photos have no owner folder then).
  late final AttachmentProcessor? _processor = widget.attachmentProcessor ?? _ownerProcessor();

  static AttachmentProcessor? _ownerProcessor() {
    final storage = AttachmentStorage.forCurrentOwner();
    return storage == null ? null : AttachmentProcessor.forStorage(storage);
  }

  /// Most photos added to one visit in a single gallery pick.
  static const int maxPhotosPerPick = 10;
  /// JPEGs created on this screen that are not saved yet; deleted if the
  /// doctor removes them or leaves without saving.
  final Set<String> _newAttachmentPaths = {};
  /// Photos saved with the visit that the doctor removed while editing.
  /// Their files are deleted only once the edited visit is saved.
  final Set<String> _removedSavedPaths = {};
  int _processingPhotos = 0;
  bool _picking = false;
  bool _saved = false;
  bool _isSaving = false;
  bool _submitted = false;

  /// A clinical note must at least record a diagnosis.
  static String? validateDiagnosis(String? value) =>
      (value ?? '').trim().isEmpty ? 'Enter a diagnosis' : null;

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

  @override
  void dispose() {
    if (!_saved) {
      for (final path in _newAttachmentPaths) {
        _deleteQuietly(path);
      }
    }
    super.dispose();
  }

  static void _deleteQuietly(String path) {
    File(path).delete().catchError((_) => File(path));
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  static String _pickerErrorMessage(PlatformException e, ImageSource source) {
    switch (e.code) {
      case 'camera_access_denied':
        return 'Camera access is off for DOCEase. Turn it on in Settings to take photos.';
      case 'photo_access_denied':
        return 'Photo access is off for DOCEase. Turn it on in Settings to add photos.';
      case 'no_available_camera':
        return 'No camera is available on this device.';
      default:
        return source == ImageSource.camera
            ? "Couldn't open the camera. Please try again."
            : "Couldn't open your photos. Please try again.";
    }
  }

  /// Picks photos, re-encodes each to a .jpg file and adds it to the visit.
  /// Anything that can't be converted is not attached; the doctor is told.
  Future<void> _addPhotos(ImageSource source) async {
    if (_picking) return;
    final processor = _processor;
    if (processor == null) {
      _showMessage("Couldn't add photos because you're signed out. Sign in again and retry.");
      return;
    }
    _picking = true;
    List<XFile> picked;
    try {
      if (source == ImageSource.camera) {
        // No maxWidth/maxHeight: the plugin's resize keeps a second,
        // untracked copy with the original EXIF. AttachmentProcessor scales.
        final shot = await _picker.pickImage(source: ImageSource.camera);
        picked = shot == null ? const [] : [shot];
      } else {
        picked = await _picker.pickMultiImage(limit: maxPhotosPerPick);
      }
    } on PlatformException catch (e) {
      _showMessage(_pickerErrorMessage(e, source));
      return;
    } finally {
      _picking = false;
    }
    if (picked.isEmpty || !mounted) return;

    setState(() => _processingPhotos += picked.length);
    final failures = <String>[];
    for (final file in picked) {
      try {
        final path = await processor.toJpegFile(file);
        if (!mounted) {
          _deleteQuietly(path);
          continue;
        }
        setState(() {
          _attachmentPaths.add(path);
          _newAttachmentPaths.add(path);
        });
      } on AttachmentException catch (e) {
        failures.add(e.message);
      } catch (_) {
        failures.add(const AttachmentException(AttachmentError.unreadable).message);
      } finally {
        if (mounted) setState(() => _processingPhotos--);
      }
    }
    if (failures.isNotEmpty) {
      _showMessage(picked.length == 1 ? failures.first : '${failures.length} of ${picked.length} photos weren\'t added. ${failures.first}');
    }
  }

  void _removeAttachment(String path) {
    setState(() => _attachmentPaths.remove(path));
    if (_newAttachmentPaths.remove(path)) {
      _deleteQuietly(path);
    } else if (widget.existingRecord?.attachmentPaths.contains(path) ?? false) {
      _removedSavedPaths.add(path);
    }
  }

  void _repeatLastVisit() {
    final patient = Provider.of<PatientProvider>(context, listen: false).findById(widget.patientId);
    // Latest by visit date, not the most recently inserted note.
    final last = patient.history.latestVisit;
    if (last != null) {
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
    if (_isSaving || _processingPhotos > 0) return;
    if (!_submitted) setState(() => _submitted = true);
    if (_formKey.currentState!.validate()) {
      setState(() => _isSaving = true);
      
      // Medicines to remember: drug-name lines, without their dosage. Learned only
      // once the visit is saved, so a refused save teaches nothing.
      final medProvider = Provider.of<MedicineProvider>(context, listen: false);
      final medicines = PrescriptionLines.medicineNames(_prescriptionController.text, dosages: medProvider.dosageTemplates, known: medProvider.frequentMedicines);

      final record = VisitRecord(
        id: widget.existingRecord?.id, date: _selectedDate, visitType: _selectedVisitType,
        symptoms: _symptomsController.text, diagnosis: _diagnosisController.text.trim(), prescription: _prescriptionController.text,
        bp: _bpController.text, temp: _tempController.text, pulse: _pulseController.text, weight: _weightController.text, sugar: _sugarController.text,
        attachmentPaths: _attachmentPaths,
      );
      
      final provider = Provider.of<PatientProvider>(context, listen: false);
      try {
        if (widget.existingRecord == null) {
          await provider.addRecord(widget.patientId, record);
        } else {
          await provider.updateRecord(widget.patientId, record);
        }
      } catch (e) {
        // Nothing was uploaded or saved: say why and stay on the form.
        if (mounted) {
          setState(() => _isSaving = false);
          final text = e is UnsupportedAttachmentException ? e.message : 'Could not save this visit. Please try again.';
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
        }
        return;
      }
      
      for (final m in medicines) { medProvider.addMedicineIfNew(m); }
      _saved = true;
      // The saved visit no longer points at these, so delete their files
      // (security re-review F8-R4). Only files in this owner's folder; cloud
      // paths and URLs are left to sync. Not reached if the save threw.
      final removed = localAttachmentPaths(_removedSavedPaths).toList();
      if (removed.isNotEmpty) {
        await (widget.attachmentStorage ?? AttachmentStorage.forCurrentOwner())?.deleteOwned(removed);
      }
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
          autovalidateMode: _submitted ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
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
            _buildModernInput(_diagnosisController, 'Diagnosis', Icons.biotech_outlined, maxLines: 2, validator: validateDiagnosis),
            const SizedBox(height: 32),
            _buildLabel('Prescription Builder'),
            _buildSmartPrescriptionField(medProvider),
            const SizedBox(height: 12),
            _buildDosageTemplates(medProvider),
            const SizedBox(height: 32),
            _buildAttachmentsSection(),
            const SizedBox(height: 48),
            _isSaving ? const Center(child: CircularProgressIndicator()) : ElevatedButton(onPressed: _processingPhotos > 0 ? null : _saveRecord, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), minimumSize: const Size(double.infinity, 64), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))), child: const Text('Save Clinical Record', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
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
        autocorrect: false, enableSuggestions: false, smartDashesType: SmartDashesType.disabled, smartQuotesType: SmartQuotesType.disabled,
        maxLines: 4,
        style: const TextStyle(fontWeight: FontWeight.w700),
        decoration: InputDecoration(
          hintText: 'Type medicine name...',
          prefixIcon: const Icon(Icons.medication_outlined, color: Color(0xFF6366F1), size: 20),
          filled: true, fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200)),
        ),
      ),
      // Match and complete only the line being typed, so every medicine line
      // gets suggestions and picking one keeps the other lines.
      suggestionsCallback: (_) => PrescriptionLines.suggestionsFor(_prescriptionController.value, medProvider.frequentMedicines),
      // Long-press removes a wrongly learned entry (security review #6). A
      // long-press-only detector, so the type-ahead's own tap still selects.
      itemBuilder: (context, suggestion) => GestureDetector(
        onLongPress: () => _confirmRemoveSuggestion(SuggestionsController.of<String>(context), medProvider, suggestion),
        child: ListTile(title: Text(suggestion), leading: const Icon(Icons.history, size: 16)),
      ),
      onSelected: (suggestion) {
        setState(() {
          _prescriptionController.value = PrescriptionLines.applySuggestion(_prescriptionController.value, suggestion);
        });
      },
    );
  }

  /// Asks before removing [name] from the learned suggestions, then removes
  /// it from the stored list. Saved records keep their prescriptions.
  Future<void> _confirmRemoveSuggestion(SuggestionsController<String> box, MedicineProvider medProvider, String name) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from suggestions?'),
        content: Text('"$name" will no longer be suggested. Saved records are not changed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (remove != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await medProvider.removeLearnedMedicine(name);
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text("Couldn't remove it from suggestions. Try again in a moment.")));
      return;
    }
    if (mounted) box.refresh();
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
            _prescriptionController.value = PrescriptionLines.applyDosage(_prescriptionController.text, t);
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
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _buildVitalInput(_sugarController, 'Blood Sugar', 'mg/dL')),
          const SizedBox(width: 16),
          const Expanded(child: SizedBox.shrink()),
        ]),
      ]),
    );
  }

  Widget _buildVitalInput(TextEditingController controller, String label, String hint) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF64748B))),
      const SizedBox(height: 6),
      TextField(controller: controller, enableIMEPersonalizedLearning: false, autocorrect: false, enableSuggestions: false, smartDashesType: SmartDashesType.disabled, smartQuotesType: SmartQuotesType.disabled, decoration: InputDecoration(hintText: hint, hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade300), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade100)))),
    ]);
  }

  Widget _buildLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 10, left: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))));

  Widget _buildModernInput(TextEditingController controller, String hint, IconData icon, {int maxLines = 1, FormFieldValidator<String>? validator}) {
    // Clinical text: no keyboard learning, autocorrect, suggestions or smart
    // punctuation (security review C12, PR #7 review).
    return TextFormField(controller: controller, maxLines: maxLines, validator: validator, enableIMEPersonalizedLearning: false, autocorrect: false, enableSuggestions: false, smartDashesType: SmartDashesType.disabled, smartQuotesType: SmartQuotesType.disabled, style: const TextStyle(fontWeight: FontWeight.w700), decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon, color: const Color(0xFF6366F1), size: 20), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))));
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

  Widget _buildAttachmentsSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildLabel('Attachments'),
      Row(children: [
        _buildIconButton(Icons.photo_camera_outlined, 'Camera', () => _addPhotos(ImageSource.camera)),
        const SizedBox(width: 12),
        _buildIconButton(Icons.photo_library_outlined, 'Gallery', () => _addPhotos(ImageSource.gallery)),
      ]),
      if (_processingPhotos > 0)
        const Padding(
          padding: EdgeInsets.only(top: 12, left: 4),
          child: Row(children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('Preparing photo...', style: TextStyle(color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
          ]),
        ),
      if (_attachmentPaths.isNotEmpty) ...[
        const SizedBox(height: 16),
        SizedBox(height: 120, child: ListView(scrollDirection: Axis.horizontal, children: _attachmentPaths.map(_buildThumbnail).toList())),
      ],
    ]);
  }

  Widget _buildIconButton(IconData icon, String label, VoidCallback onTap) {
    return Expanded(child: GestureDetector(onTap: onTap, child: Container(padding: const EdgeInsets.symmetric(vertical: 16), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE2E8F0))), child: Column(children: [Icon(icon, color: const Color(0xFF6366F1)), const SizedBox(height: 4), Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))]))));
  }

  Widget _buildThumbnail(String path) {
    final isNetwork = path.startsWith('http');
    return Padding(padding: const EdgeInsets.only(right: 12), child: Stack(children: [ClipRRect(borderRadius: BorderRadius.circular(16), child: isNetwork ? Image.network(path, width: 100, height: 120, fit: BoxFit.cover) : Image.file(File(path), width: 100, height: 120, fit: BoxFit.cover)), Positioned(right: 4, top: 4, child: GestureDetector(onTap: () => _removeAttachment(path), child: const CircleAvatar(radius: 12, backgroundColor: Colors.redAccent, child: Icon(Icons.close, size: 14, color: Colors.white))))]));
  }
}
