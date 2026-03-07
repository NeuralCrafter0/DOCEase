import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl_phone_field/intl_phone_field.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:intl_phone_field/countries.dart';
import '../models/patient.dart';
import '../providers/patient_provider.dart';

class AddPatientScreen extends StatefulWidget {
  final Patient? existingPatient;
  const AddPatientScreen({super.key, this.existingPatient});

  @override
  State<AddPatientScreen> createState() => _AddPatientScreenState();
}

class _AddPatientScreenState extends State<AddPatientScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _ageController;
  late TextEditingController _phoneController;
  String _selectedGender = 'Male';
  String _selectedRelation = 'Self';
  String _completePhoneNumber = '';
  String _initialCountryCode = 'IN';

  final List<String> _relations = ['Self', 'Son', 'Daughter', 'Spouse', 'Father', 'Mother'];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existingPatient?.name ?? '');
    _ageController = TextEditingController(text: widget.existingPatient?.age ?? '');
    _selectedRelation = widget.existingPatient?.relation ?? 'Self';
    
    String initialNumber = '';
    if (widget.existingPatient != null) {
      _completePhoneNumber = widget.existingPatient!.phone;
      for (var country in countries) {
        if (_completePhoneNumber.startsWith('+${country.dialCode}')) {
          _initialCountryCode = country.code;
          initialNumber = _completePhoneNumber.replaceFirst('+${country.dialCode}', '');
          break;
        }
      }
    }
    _phoneController = TextEditingController(text: initialNumber);
    _selectedGender = widget.existingPatient?.gender ?? 'Male';
  }

  void _saveForm() {
    if (_formKey.currentState!.validate()) {
      final patient = Patient(
        id: widget.existingPatient?.id,
        name: _nameController.text,
        age: _ageController.text,
        gender: _selectedGender,
        phone: _completePhoneNumber,
        relation: _selectedRelation,
        history: widget.existingPatient?.history,
      );
      final provider = Provider.of<PatientProvider>(context, listen: false);
      if (widget.existingPatient == null) {
        provider.addPatient(patient);
      } else {
        provider.updatePatient(patient);
      }
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(title: Text(widget.existingPatient == null ? 'Patient Registration' : 'Edit Profile', style: const TextStyle(fontWeight: FontWeight.w900)), backgroundColor: Colors.transparent, elevation: 0),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.all(24.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLabel('Full Name'),
              _buildModernInput(_nameController, 'Enter patient name', Icons.person_outline),
              const SizedBox(height: 24),
              _buildLabel('Age'),
              _buildModernInput(_ageController, 'Years', Icons.cake_outlined, keyboardType: TextInputType.number),
              const SizedBox(height: 24),
              _buildLabel('Relationship'),
              _buildHighPerfSelector(_relations, _selectedRelation, (val) => setState(() => _selectedRelation = val)),
              const SizedBox(height: 24),
              _buildLabel('Gender'),
              _buildHighPerfSelector(['Male', 'Female', 'Other'], _selectedGender, (val) => setState(() => _selectedGender = val)),
              const SizedBox(height: 32),
              _buildLabel('Mobile Number'),
              IntlPhoneField(
                controller: _phoneController,
                initialCountryCode: _initialCountryCode,
                style: const TextStyle(fontWeight: FontWeight.w700),
                decoration: InputDecoration(filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))),
                onChanged: (phone) => _completePhoneNumber = phone.completeNumber,
              ),
              const SizedBox(height: 48),
              ElevatedButton(onPressed: _saveForm, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), minimumSize: const Size(double.infinity, 64), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))), child: Text(widget.existingPatient == null ? 'Register Profile' : 'Save Changes', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 10, left: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))));

  Widget _buildModernInput(TextEditingController controller, String hint, IconData icon, {TextInputType? keyboardType}) {
    return TextFormField(controller: controller, keyboardType: keyboardType, style: const TextStyle(fontWeight: FontWeight.w700), decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon, color: const Color(0xFF6366F1), size: 20), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))));
  }

  Widget _buildHighPerfSelector(List<String> options, String selectedValue, Function(String) onSelected) {
    final selectedIndex = options.indexOf(selectedValue);
    return Container(
      height: 54,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(18)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth / options.length;
          return Stack(
            children: [
              // Moving Indicator - Single object, no shadow trail
              AnimatedPositioned(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                left: selectedIndex * width,
                top: 0, bottom: 0, width: width,
                child: Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 2))]),
                ),
              ),
              // Labels Layer
              Row(
                children: options.map((opt) {
                  final isSelected = selectedValue == opt;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () => onSelected(opt),
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Text(opt, style: TextStyle(fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600, color: isSelected ? const Color(0xFF6366F1) : const Color(0xFF64748B), fontSize: 13)),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          );
        },
      ),
    );
  }
}
