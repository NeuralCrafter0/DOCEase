import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl_phone_field/countries.dart';
import 'package:intl_phone_field/country_picker_dialog.dart';
import 'package:intl_phone_field/phone_number.dart';

/// A patient phone number input that keeps the number out of the keyboard.
///
/// intl_phone_field's IntlPhoneField builds its own TextFormField and has no
/// option for suggestions, autocorrect or keyboard learning, so a patient's
/// number could be learned by the keyboard and offered later. This widget
/// mirrors the subset of IntlPhoneField's API that DOCEase uses (country
/// flag and dial code button, the package's own country picker and data,
/// per-country length check, [PhoneNumber] callbacks) and turns all of
/// that off. No new package: it reuses intl_phone_field's public pieces.
class PrivatePhoneField extends StatefulWidget {
  final TextEditingController? controller;
  final String? initialCountryCode;
  final TextStyle? style;
  final InputDecoration decoration;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String invalidNumberMessage;
  final AutovalidateMode? autovalidateMode;
  final bool disableLengthCheck;
  final bool enabled;
  final ValueChanged<PhoneNumber>? onChanged;
  final ValueChanged<Country>? onCountryChanged;
  final FutureOr<String?> Function(PhoneNumber?)? validator;

  const PrivatePhoneField({
    super.key,
    this.controller,
    this.initialCountryCode,
    this.style,
    this.decoration = const InputDecoration(),
    this.keyboardType = TextInputType.phone,
    this.inputFormatters,
    this.invalidNumberMessage = 'Invalid Mobile Number',
    this.autovalidateMode = AutovalidateMode.onUserInteraction,
    this.disableLengthCheck = false,
    this.enabled = true,
    this.onChanged,
    this.onCountryChanged,
    this.validator,
  });

  @override
  State<PrivatePhoneField> createState() => _PrivatePhoneFieldState();
}

class _PrivatePhoneFieldState extends State<PrivatePhoneField> {
  late Country _country;
  String? _validatorMessage;

  @override
  void initState() {
    super.initState();
    _country = countries.firstWhere((c) => c.code == (widget.initialCountryCode ?? 'IN'),
        orElse: () => countries.firstWhere((c) => c.code == 'IN'));
  }

  PhoneNumber _number(String value) => PhoneNumber(
        countryISOCode: _country.code,
        countryCode: '+${_country.fullCountryCode}',
        number: value,
      );

  Future<void> _changeCountry() async {
    var filtered = countries;
    await showDialog<void>(
      context: context,
      useRootNavigator: false,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => CountryPickerDialog(
          languageCode: 'en',
          searchText: 'Search country',
          countryList: countries,
          filteredCountries: filtered,
          selectedCountry: _country,
          onCountryChanged: (c) {
            _country = c;
            widget.onCountryChanged?.call(c);
            setDialogState(() => filtered = countries);
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      style: widget.style,
      enabled: widget.enabled,
      keyboardType: widget.keyboardType,
      inputFormatters: widget.inputFormatters,
      autovalidateMode: widget.autovalidateMode,
      maxLength: widget.disableLengthCheck ? null : _country.maxLength,
      // Keep the patient's number out of the keyboard's memory.
      enableSuggestions: false,
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      decoration: widget.decoration.copyWith(
        prefixIcon: InkWell(
          key: const ValueKey('phone-country-button'),
          onTap: widget.enabled ? _changeCountry : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            // Dial code only: flag emoji need an emoji font, which isn't
            // bundled (about 10 MB), so they'd render as boxes.
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('+${_country.dialCode}', style: widget.style),
              const Icon(Icons.arrow_drop_down),
            ]),
          ),
        ),
        counterText: widget.enabled ? null : '',
      ),
      onChanged: (value) async {
        final n = _number(value);
        if (widget.autovalidateMode != AutovalidateMode.disabled) {
          _validatorMessage = await widget.validator?.call(n);
        }
        widget.onChanged?.call(n);
      },
      validator: (value) {
        if (value == null || !RegExp(r'^\d+$').hasMatch(value)) return _validatorMessage;
        if (!widget.disableLengthCheck &&
            (value.length < _country.minLength || value.length > _country.maxLength)) {
          return widget.invalidNumberMessage;
        }
        return _validatorMessage;
      },
    );
  }
}
