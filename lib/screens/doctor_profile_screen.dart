import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:flutter/services.dart';
import '../models/doctor.dart';
import '../providers/doctor_provider.dart';

class DoctorProfileScreen extends StatefulWidget {
  const DoctorProfileScreen({super.key});

  @override
  State<DoctorProfileScreen> createState() => _DoctorProfileScreenState();
}

class _DoctorProfileScreenState extends State<DoctorProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _ageController;
  late TextEditingController _mobileController;
  late TextEditingController _specialtyController;
  late TextEditingController _clinicController;
  
  String _selectedTitle = 'MR';
  String _selectedPracticeMode = 'Solo Practice';
  String? _profileImageUrl;
  File? _localImage;
  bool _isLoading = false;
  bool _isEditing = false; // New state for locking/unlocking profile
  
  String _completePhoneNumber = '';
  String _initialCountryCode = 'IN';

  @override
  void initState() {
    super.initState();
    final doc = Provider.of<DoctorProvider>(context, listen: false).currentDoctor;
    _nameController = TextEditingController(text: doc?.name ?? '');
    _emailController = TextEditingController(text: doc?.email ?? FirebaseAuth.instance.currentUser?.email ?? '');
    _ageController = TextEditingController(text: doc?.age ?? '');
    _specialtyController = TextEditingController(text: doc?.specialty ?? '');
    _clinicController = TextEditingController(text: doc?.clinicName ?? '');
    _selectedTitle = doc?.title ?? 'MR';
    _selectedPracticeMode = doc?.practiceMode ?? 'Solo Practice';
    _profileImageUrl = doc?.profileImageUrl;
    
    // Set editing false if profile exists
    if (doc != null) _isEditing = false; else _isEditing = true;

    String initialNumber = '';
    if (doc != null && doc.mobileNumber.isNotEmpty) {
      _completePhoneNumber = doc.mobileNumber;
      for (var country in countries) {
        if (_completePhoneNumber.startsWith('+${country.dialCode}')) {
          _initialCountryCode = country.code;
          initialNumber = _completePhoneNumber.replaceFirst('+${country.dialCode}', '');
          break;
        }
      }
    }
    _mobileController = TextEditingController(text: initialNumber);
  }

  Future<void> _pickImage(ImageSource source) async {
    if (!_isEditing) return;
    final picked = await ImagePicker().pickImage(source: source, imageQuality: 50);
    if (picked != null) setState(() => _localImage = File(picked.path));
  }

  Future<void> _saveProfile() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        String? finalImageUrl = _profileImageUrl;
        if (_localImage != null) finalImageUrl = await Provider.of<DoctorProvider>(context, listen: false).uploadProfileImage(_localImage!);
        
        final doctor = Doctor(
          id: user.uid, title: _selectedTitle, name: _nameController.text, email: _emailController.text, 
          age: _ageController.text, mobileNumber: _completePhoneNumber, specialty: _specialtyController.text, 
          clinicName: _clinicController.text, practiceMode: _selectedPracticeMode, profileImageUrl: finalImageUrl
        );
        await Provider.of<DoctorProvider>(context, listen: false).saveDoctorProfile(doctor);
        if (mounted) {
          setState(() => _isEditing = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profile Locked & Saved')));
        }
      }
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Professional Profile', style: TextStyle(fontWeight: FontWeight.w900)), 
        backgroundColor: Colors.transparent, elevation: 0,
        actions: [
          if (!_isEditing)
            IconButton(
              icon: const Icon(Icons.edit_note_rounded, color: Color(0xFF6366F1)),
              onPressed: () => setState(() => _isEditing = true),
              tooltip: 'Unlock Profile',
            )
        ],
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(
              child: Stack(children: [
                CircleAvatar(radius: 60, backgroundColor: const Color(0xFFEEF2FF), backgroundImage: _localImage != null ? FileImage(_localImage!) : (_profileImageUrl != null ? NetworkImage(_profileImageUrl!) : null) as ImageProvider?),
                if (_isEditing) Positioned(bottom: 0, right: 0, child: GestureDetector(onTap: () => _pickImage(ImageSource.camera), child: Container(padding: const EdgeInsets.all(8), decoration: const BoxDecoration(color: Color(0xFF1E293B), shape: BoxShape.circle), child: const Icon(Icons.camera_alt, color: Colors.white, size: 20)))),
              ]),
            ),
            const SizedBox(height: 40),
            _buildLabel('Title'),
            _buildHighPerfSelector(['MR', 'MRS', 'MS'], _selectedTitle, (v) => setState(() => _selectedTitle = v)),
            const SizedBox(height: 32),
            _buildLabel('Practice Mode'),
            _buildHighPerfSelector(['Solo Practice', 'Clinic Mode'], _selectedPracticeMode, (v) => setState(() => _selectedPracticeMode = v)),
            const SizedBox(height: 32),
            _buildLabel('Professional Details'),
            _buildModernInput(_nameController, 'Full Name', Icons.person_outline),
            const SizedBox(height: 24),
            _buildModernInput(_emailController, 'Clinical Email', Icons.alternate_email_rounded, keyboardType: TextInputType.emailAddress),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_buildLabel('Age'), _buildModernInput(_ageController, 'Yrs', Icons.cake_outlined, keyboardType: TextInputType.number, isAge: true)])),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildLabel('Mobile'),
                    AbsorbPointer(
                      absorbing: !_isEditing,
                      child: IntlPhoneField(
                        controller: _mobileController,
                        initialCountryCode: _initialCountryCode,
                        enabled: _isEditing,
                        style: TextStyle(fontWeight: FontWeight.w700, color: _isEditing ? const Color(0xFF1E293B) : Colors.grey),
                        decoration: InputDecoration(filled: true, fillColor: _isEditing ? Colors.white : const Color(0xFFF1F5F9), border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))),
                        onChanged: (phone) => _completePhoneNumber = phone.completeNumber,
                      ),
                    )
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 24),
            _buildModernInput(_specialtyController, 'Specialty', Icons.medical_services_outlined),
            const SizedBox(height: 24),
            _buildModernInput(_clinicController, 'Clinic / Hospital', Icons.local_hospital_outlined),
            const SizedBox(height: 48),
            if (_isEditing)
              _isLoading ? const Center(child: CircularProgressIndicator()) : ElevatedButton(onPressed: _saveProfile, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), minimumSize: const Size(double.infinity, 64), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))), child: const Text('Save and Lock Profile', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
            const SizedBox(height: 40),
          ]),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 10, left: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))));

  Widget _buildModernInput(TextEditingController controller, String hint, IconData icon, {TextInputType? keyboardType, bool isAge = false}) {
    return TextFormField(
      controller: controller, keyboardType: keyboardType,
      enabled: _isEditing,
      inputFormatters: isAge ? [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)] : null,
      style: TextStyle(fontWeight: FontWeight.w700, color: _isEditing ? const Color(0xFF1E293B) : Colors.grey),
      decoration: InputDecoration(
        hintText: hint, prefixIcon: Icon(icon, color: const Color(0xFF6366F1), size: 20),
        filled: true, fillColor: _isEditing ? Colors.white : const Color(0xFFF1F5F9),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200)),
      ),
    );
  }

  Widget _buildHighPerfSelector(List<String> options, String selectedValue, Function(String) onSelected) {
    final selectedIndex = options.indexOf(selectedValue);
    return AbsorbPointer(
      absorbing: !_isEditing,
      child: Container(
        height: 54, padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(18)),
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth / options.length;
          return Stack(children: [
            AnimatedPositioned(duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic, left: selectedIndex * width, top: 0, bottom: 0, width: width, child: Container(decoration: BoxDecoration(color: _isEditing ? Colors.white : Colors.grey.shade300, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8)]))),
            Row(children: options.map((opt) {
              final isSelected = selectedValue == opt;
              return Expanded(child: GestureDetector(onTap: () => onSelected(opt), behavior: HitTestBehavior.opaque, child: Center(child: Text(opt, style: TextStyle(fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600, color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF64748B), fontSize: 13)))));
            }).toList()),
          ]);
        }),
      ),
    );
  }
}
