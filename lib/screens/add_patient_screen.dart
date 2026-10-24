import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:provider/provider.dart';

import '../models/patient.dart';
import '../providers/patient_provider.dart';
import '../theme/app_theme.dart';
import '../ui/components.dart';
import '../ui/qa_keys.dart';
import '../utils/patient_load.dart';
import '../utils/patient_search.dart';
import '../widgets/app_text_field.dart';
import '../widgets/confirm_sheet.dart';
import '../widgets/private_phone_field.dart';
import '../widgets/segmented_selector.dart';
import 'patient_detail_screen.dart';

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

/// Register a patient, or edit one ([existingPatient]).
class AddPatientScreen extends StatefulWidget {
  final Patient? existingPatient;
  const AddPatientScreen({super.key, this.existingPatient});

  @override
  State<AddPatientScreen> createState() => _AddPatientScreenState();
}

class _AddPatientScreenState extends State<AddPatientScreen> {
  static const _relations = ['Self', 'Son', 'Daughter', 'Spouse', 'Father', 'Mother'];
  static const _genders = ['Male', 'Female', 'Other'];

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _age;
  late final TextEditingController _phone;
  late String _gender;
  late String _relation;
  String _initialCountryCode = 'IN';
  late Country _country;
  bool _submitted = false;

  /// True from a valid tap until the save (or the duplicate warning) is
  /// over, so a second tap can't register the patient twice (DATA-DUP-05).
  bool _saving = false;

  /// True only while the provider is writing; drives the button spinner.
  bool _writing = false;

  /// Shown above the save button after a refused save. The form stays open
  /// with everything typed (PAT-REFUSED-01/02).
  String? _refusal;

  late final String _initialSignature;

  bool get _isNew => widget.existingPatient == null;

  @override
  void initState() {
    super.initState();
    final p = widget.existingPatient;
    _name = TextEditingController(text: p?.name ?? '');
    _age = TextEditingController(text: p?.age ?? '');
    _relation = p?.relation ?? 'Self';
    _gender = p?.gender ?? 'Male';
    var initialNumber = '';
    if (p != null) {
      for (final country in countries) {
        if (p.phone.startsWith('+${country.dialCode}')) {
          _initialCountryCode = country.code;
          initialNumber = p.phone.replaceFirst('+${country.dialCode}', '');
          break;
        }
      }
    }
    _phone = TextEditingController(text: initialNumber);
    _country = countries.firstWhere((c) => c.code == _initialCountryCode);
    _initialSignature = _signature();
  }

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _phone.dispose();
    super.dispose();
  }

  String _signature() => [_name.text, _age.text, _phone.text, _gender, _relation, _country.code].join('\u0000');
  bool get _dirty => _signature() != _initialSignature;

  // Built from the country selected at save time, so changing the country
  // after typing the number does not keep the old dial code.
  String get _fullPhone => '+${_country.fullCountryCode}${_phone.text.trim()}';

  /// Same number and same name (normalized, any case) as a patient already
  /// registered. Checked against every patient, not the search results, and
  /// never from a list that failed to load (DATA-DUP-03/04). Same number
  /// with another name is a family member and is not a duplicate.
  Patient? _duplicate(PatientProvider provider) {
    if (!_isNew || PatientLoad.failed(provider)) return null;
    final name = PatientFormValidators.normalizeName(_name.text).toLowerCase();
    for (final p in provider.allPatients) {
      if (samePhone(p.phone, _fullPhone) && PatientFormValidators.normalizeName(p.name).toLowerCase() == name) return p;
    }
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_submitted) setState(() => _submitted = true);
    if (!_formKey.currentState!.validate()) return;
    final provider = context.read<PatientProvider>();
    setState(() {
      _saving = true;
      _refusal = null;
    });

    final dup = _duplicate(provider);
    if (dup != null) {
      final choice = await _DuplicateSheet.show(context, name: PatientFormValidators.normalizeName(_name.text));
      if (!mounted) return;
      if (choice == _DupChoice.openExisting) {
        // Saves nothing; the existing record takes this form's place.
        Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => PatientDetailScreen(patientId: dup.id)));
        return;
      }
      if (choice != _DupChoice.registerAnyway) {
        setState(() => _saving = false);
        return;
      }
    }

    final name = PatientFormValidators.normalizeName(_name.text);
    final age = _age.text.trim();
    setState(() => _writing = true);
    try {
      if (_isNew) {
        await provider.addPatient(Patient(name: name, age: age, gender: _gender, phone: _fullPhone, relation: _relation));
      } else {
        await provider.updatePatientDetails(widget.existingPatient!.id, name: name, age: age, gender: _gender, phone: _fullPhone, relation: _relation);
      }
    } on SaveRefusedException {
      // Nothing was stored, or the previous details were kept. Any other
      // error is a bug and is not caught here.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _writing = false;
        _refusal = _isNew ? "Couldn't register this patient. Nothing was saved." : "Couldn't save these changes. The previous details were kept.";
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop();
    AppSnack.show(context, _isNew ? 'Patient registered' : 'Changes saved', tone: Tone.primary);
  }

  Future<void> _confirmLeave() async {
    final leave = await ConfirmSheet.show(
      context,
      title: _isNew ? 'Discard this patient?' : 'Discard changes?',
      message: _isNew ? "What you've typed will not be saved." : 'Your edits will not be saved. The stored details stay as they were.',
      confirmLabel: 'Discard',
      icon: Icons.undo_rounded,
    );
    if (leave && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.ds;
    return PopScope(
      canPop: !_dirty || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.of(context).maybePop()),
          title: Text(_isNew ? 'New patient' : 'Edit patient'),
        ),
        body: Form(
          key: _formKey,
          autovalidateMode: _submitted ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(0, Space.sm, 0, Space.xxl),
            children: [
              ContentWidth(
                maxWidth: Layout.formMax + Space.xxxl * 2,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FormSection(
                        title: 'About the patient',
                        icon: Icons.person_outline_rounded,
                        children: [
                          AppTextField(
                            key: QaKeys.patientFormName,
                            controller: _name,
                            label: 'Full name',
                            hint: 'e.g. Asha Verma',
                            icon: null,
                            private: true,
                            validator: PatientFormValidators.name,
                            textCapitalization: TextCapitalization.words,
                            textInputAction: TextInputAction.next,
                            inputFormatters: [LengthLimitingTextInputFormatter(80)],
                          ),
                          const SizedBox(height: Space.lg),
                          // Grows with the text size so "years" never clips.
                          LayoutBuilder(
                            builder: (context, box) => Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: SizedBox(
                                width: MediaQuery.textScalerOf(context).scale(176).clamp(0.0, box.maxWidth),
                                child: AppTextField(
                                  key: QaKeys.patientFormAge,
                                  controller: _age,
                                  label: 'Age',
                                  hint: '0–120',
                                  icon: null,
                                  suffixText: 'years',
                                  private: true,
                                  keyboardType: TextInputType.number,
                                  validator: PatientFormValidators.age,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: Space.xl),
                          _Label('Gender'),
                          SegmentedSelector(
                            options: _genders,
                            selected: _genders.contains(_gender) ? _gender : 'Other',
                            keyFor: QaKeys.patientFormGender,
                            onSelected: (v) => setState(() => _gender = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.lg),
                      FormSection(
                        title: 'Contact and family',
                        icon: Icons.call_outlined,
                        subtitle: 'Patients who share a number appear together as a family.',
                        children: [
                          // IntlPhoneField skips its own validation while the
                          // field is empty, so this FormField makes the number
                          // required. The per-country length check stays inside.
                          FormField<String>(
                            validator: (_) => PatientFormValidators.phone(_phone.text),
                            builder: (field) => PrivatePhoneField(
                              key: QaKeys.patientFormPhone,
                              controller: _phone,
                              initialCountryCode: _initialCountryCode,
                              style: AppText.tabular(context.type.bodyLarge),
                              keyboardType: TextInputType.phone,
                              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                              invalidNumberMessage: 'Enter a valid mobile number',
                              autovalidateMode: _submitted ? AutovalidateMode.onUserInteraction : AutovalidateMode.disabled,
                              decoration: InputDecoration(labelText: 'Mobile number', errorText: field.errorText),
                              onCountryChanged: (country) => setState(() => _country = country),
                              onChanged: (_) {
                                if (field.hasError) field.validate();
                                setState(() {}); // dirty state
                              },
                            ),
                          ),
                          const SizedBox(height: Space.lg),
                          _Label('Relationship to the number’s owner'),
                          Wrap(
                            spacing: Space.sm,
                            runSpacing: Space.sm,
                            children: [
                              for (final r in {..._relations, _relation})
                                ChoiceChip(
                                  key: QaKeys.patientFormRelation(r),
                                  label: Text(r),
                                  selected: r == _relation,
                                  showCheckmark: false,
                                  onSelected: (_) => setState(() => _relation = r),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: BottomActionBar(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSize(
                duration: Motion.of(context, Motion.standard),
                curve: Motion.move,
                child: _refusal == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(bottom: Space.md),
                        child: NoticeBanner(
                          key: QaKeys.patientFormRefused,
                          icon: Icons.error_outline_rounded,
                          tone: Tone.danger,
                          message: _refusal!,
                          liveRegion: true,
                        ),
                      ),
              ),
              FilledButton(
                key: QaKeys.patientFormSave,
                onPressed: _saving ? null : _save,
                child: _writing
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.4, color: c.inkMuted, semanticsLabel: 'Saving'),
                      )
                    : Text(_isNew ? 'Register patient' : 'Save changes'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.sm),
    child: Text(text, style: context.type.labelLarge?.copyWith(color: context.ds.inkSecondary)),
  );
}

enum _DupChoice { openExisting, registerAnyway }

/// "Already registered?" Holds only the name the doctor just typed (S7).
class _DuplicateSheet extends StatelessWidget {
  const _DuplicateSheet({required this.name});

  final String name;

  static Future<_DupChoice?> show(BuildContext context, {required String name}) => showModalBottomSheet<_DupChoice>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _DuplicateSheet(name: name),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        key: QaKeys.patientFormDuplicate,
        padding: const EdgeInsets.fromLTRB(Space.xl, Space.sm, Space.xl, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: IconMedallion(icon: Icons.people_alt_outlined, tone: Tone.warn, size: 44),
            ),
            const SizedBox(height: Space.lg),
            Semantics(header: true, child: Text('Already registered?', style: context.type.titleLarge)),
            const SizedBox(height: Space.sm),
            Text(
              '$name with this mobile number is already in your patients. Open their record to add a visit, or register a second patient anyway.',
              style: context.type.bodyLarge?.copyWith(color: context.ds.inkSecondary),
            ),
            const SizedBox(height: Space.xl),
            FilledButton(
              key: QaKeys.patientFormOpenExisting,
              onPressed: () => Navigator.of(context).pop(_DupChoice.openExisting),
              child: const Text('Open existing record'),
            ),
            const SizedBox(height: Space.sm),
            OutlinedButton(
              key: QaKeys.patientFormRegisterAnyway,
              onPressed: () => Navigator.of(context).pop(_DupChoice.registerAnyway),
              child: const Text('Register anyway'),
            ),
          ],
        ),
      ),
    );
  }
}
