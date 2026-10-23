import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:intl_phone_field/countries.dart';
import '../models/patient.dart';
import '../providers/patient_provider.dart';
import '../widgets/private_phone_field.dart';

/// Validators for the patient form. Public so they can be unit-tested.
class PatientFormValidators {
  PatientFormValidators._();

  static final RegExp _letter = RegExp(r'\p{L}', unicode: true);
  static final RegExp _digit = RegExp(r'[0-9]');
  static final RegExp _digitsOnly = RegExp(r'^[0-9]+$');

  /// Collapses runs of whitespace and trims, e.g. "  Asha   Rao " -> "Asha Rao".
  static String normalizeName(String value) => value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String? name(String? value) {
    final v = normalizeName(value ?? '');
    if (v.isEmpty) return 'Enter the patient\'s name';
    if (v.length > 80) return 'Name must be 80 characters or fewer';
    if (_digit.hasMatch(v)) return 'Name cannot contain numbers';
    if (!_letter.hasMatch(v)) return 'Enter a valid name';
    return null;
  }

  static String? age(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter the age in years';
    final years = int.tryParse(v);
    if (years == null || !_digitsOnly.hasMatch(v)) return 'Age must be a whole number';
    if (years > 120) return 'Enter an age between 0 and 120';
    return null;
  }

  /// Required + digits only. The per-country length check is done by
  /// IntlPhoneField itself.
  static String? phone(String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'Enter the mobile number';
    if (!_digitsOnly.hasMatch(v)) return 'Use digits only';
    return null;
  }
}

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
  String _initialCountryCode = 'IN';
  late Country _selectedCountry;
  bool _submitted = false;

  final List<String> _relations = ['Self', 'Son', 'Daughter', 'Spouse', 'Father', 'Mother'];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.existingPatient?.name ?? '');
    _ageController = TextEditingController(text: widget.existingPatient?.age ?? '');
    _selectedRelation = widget.existingPatient?.relation ?? 'Self';
    
    String initialNumber = '';
    if (widget.existingPatient != null) {
      final existingPhone = widget.existingPatient!.phone;
      for (var country in countries) {
        if (existingPhone.startsWith('+${country.dialCode}')) {
          _initialCountryCode = country.code;
          initialNumber = existingPhone.replaceFirst('+${country.dialCode}', '');
          break;
        }
      }
    }
    _phoneController = TextEditingController(text: initialNumber);
    _selectedCountry = countries.firstWhere((c) => c.code == _initialCountryCode);
    _selectedGender = widget.existingPatient?.gender ?? 'Male';
  }

  /// True while the local save is running, so a second tap can't register
  /// the patient twice.
  bool _saving = false;

  Future<void> _saveForm() async {
    if (_saving) return;
    if (!_submitted) setState(() => _submitted = true);
    if (_formKey.currentState!.validate()) {
      final patient = Patient(
        id: widget.existingPatient?.id,
        name: PatientFormValidators.normalizeName(_nameController.text),
        age: _ageController.text.trim(),
        gender: _selectedGender,
        // Built from the country selected at save time, so changing the
        // country after typing the number does not keep the old dial code.
        phone: '+${_selectedCountry.fullCountryCode}${_phoneController.text.trim()}',
        relation: _selectedRelation,
        history: widget.existingPatient?.history,
      );
      final provider = Provider.of<PatientProvider>(context, listen: false);
      final isNew = widget.existingPatient == null;
      setState(() => _saving = true);
      try {
        if (isNew) {
          await provider.addPatient(patient);
        } else {
          await provider.updatePatient(patient);
        }
      } catch (_) {
        // The local database refused the save; the provider has already
        // dropped the new patient or restored the previous details. Close
        // the form, so the screen underneath shows what is really stored
        // (QA F-PAT-05/06), and say so there without any patient data in
        // the message. TODO(after #13 merges): narrow this to
        // `on SaveRefusedException`.
        if (!mounted) return;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(SnackBar(
          content: Text(isNew
              ? "Couldn't register this patient. Nothing was saved."
              : "Couldn't save these changes. The previous details were kept."),
        ));
        return;
      }
      if (!mounted) return;
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
          autovalidateMode: _submitted ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildLabel('Full Name'),
              _buildModernInput(_nameController, 'Enter patient name', Icons.person_outline,
                  validator: PatientFormValidators.name, textCapitalization: TextCapitalization.words),
              const SizedBox(height: 24),
              _buildLabel('Age'),
              _buildModernInput(_ageController, 'Years', Icons.cake_outlined,
                  keyboardType: TextInputType.number,
                  validator: PatientFormValidators.age,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)]),
              const SizedBox(height: 24),
              _buildLabel('Relationship'),
              _buildHighPerfSelector(_relations, _selectedRelation, (val) => setState(() => _selectedRelation = val)),
              const SizedBox(height: 24),
              _buildLabel('Gender'),
              _buildHighPerfSelector(['Male', 'Female', 'Other'], _selectedGender, (val) => setState(() => _selectedGender = val)),
              const SizedBox(height: 32),
              _buildLabel('Mobile Number'),
              // IntlPhoneField skips its own validation while the field is
              // empty, so this FormField makes the number required. The
              // per-country length check stays inside IntlPhoneField.
              FormField<String>(
                validator: (_) => PatientFormValidators.phone(_phoneController.text),
                builder: (field) => PrivatePhoneField(
                  controller: _phoneController,
                  initialCountryCode: _initialCountryCode,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  invalidNumberMessage: 'Enter a valid mobile number',
                  autovalidateMode: _submitted ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
                  decoration: InputDecoration(errorText: field.errorText, filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))),
                  onCountryChanged: (country) => _selectedCountry = country,
                  onChanged: (_) {
                    if (field.hasError) field.validate();
                  },
                ),
              ),
              const SizedBox(height: 48),
              ElevatedButton(onPressed: _saving ? null : _saveForm, style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E293B), minimumSize: const Size(double.infinity, 64), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))), child: Text(widget.existingPatient == null ? 'Register Profile' : 'Save Changes', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLabel(String text) => Padding(padding: const EdgeInsets.only(bottom: 10, left: 4), child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF475569))));

  Widget _buildModernInput(TextEditingController controller, String hint, IconData icon, {TextInputType? keyboardType, FormFieldValidator<String>? validator, List<TextInputFormatter>? inputFormatters, TextCapitalization textCapitalization = TextCapitalization.none}) {
    // Patient data: keep it out of the keyboard's learned words and
    // suggestion history (security review C12).
    return TextFormField(controller: controller, keyboardType: keyboardType, validator: validator, inputFormatters: inputFormatters, textCapitalization: textCapitalization, enableIMEPersonalizedLearning: false, autocorrect: false, enableSuggestions: false, smartDashesType: SmartDashesType.disabled, smartQuotesType: SmartQuotesType.disabled, style: const TextStyle(fontWeight: FontWeight.w700), decoration: InputDecoration(hintText: hint, prefixIcon: Icon(icon, color: const Color(0xFF6366F1), size: 20), filled: true, fillColor: Colors.white, border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide(color: Colors.grey.shade200))));
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
