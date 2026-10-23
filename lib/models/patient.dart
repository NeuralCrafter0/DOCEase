import 'package:uuid/uuid.dart';

/// Reads one JSON map field by field, recording (by field name only, never
/// the value, so nothing identifying is logged) every field that is present
/// but cannot be represented. Absent fields get their documented defaults
/// and are not errors.
class _FieldReader {
  _FieldReader(this.json);
  final Map<dynamic, dynamic> json;
  final List<String> errors = [];

  String str(String key, String fallback) => optStr(key) ?? fallback;

  String? optStr(String key) {
    final v = json[key];
    if (v == null || v is String) return v as String?;
    errors.add(key);
    return v.toString(); // shown for context only; the record is read-only
  }

  /// `null` when absent. A present but unparseable date is an error and
  /// falls back to [VisitRecord.epochFallback]; other fields stay intact.
  DateTime? optDate(String key) {
    final v = json[key];
    if (v == null) return null;
    final parsed = v is String ? DateTime.tryParse(v) : null;
    if (parsed == null) {
      errors.add(key);
      return VisitRecord.epochFallback;
    }
    return parsed;
  }

  List<String> strList(String key) {
    final v = json[key];
    if (v == null) return [];
    if (v is! List) {
      errors.add(key);
      return [];
    }
    if (v.any((e) => e is! String)) errors.add(key);
    return v.whereType<String>().toList();
  }
}

class VisitRecord {
  final String id;
  final DateTime date;
  final String visitType;
  final String symptoms;
  final String diagnosis;
  final String prescription;
  final String? notes;
  final List<String> attachmentPaths;

  // Vitals
  final String? bp;
  final String? temp;
  final String? pulse;
  final String? weight;
  final String? sugar;

  /// Names of fields that could not be parsed (empty for a clean record).
  final List<String> parseErrors;

  /// The original stored value, kept whenever parsing failed so nothing is
  /// lost. A record with [parseFailed] is never written back or synced.
  final Object? raw;

  /// Placeholder date shown for a visit whose stored date is unparseable.
  static final DateTime epochFallback =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  bool get parseFailed => parseErrors.isNotEmpty;

  /// The stored date was missing or unparseable; [date] is
  /// [epochFallback] and every other field is as stored.
  bool get dateInvalid => parseErrors.contains('date');

  VisitRecord({
    String? id,
    required this.date,
    required this.visitType,
    required this.symptoms,
    required this.diagnosis,
    required this.prescription,
    this.notes,
    List<String>? attachmentPaths,
    this.bp, this.temp, this.pulse, this.weight, this.sugar,
    this.parseErrors = const [],
    this.raw,
  })  : id = id ?? const Uuid().v4(),
        attachmentPaths = attachmentPaths ?? [];

  Map<String, dynamic> toJson() {
    // Defensive: if a failed record is ever serialised, emit what was stored,
    // never the placeholder values.
    final r = raw;
    if (parseFailed && r is Map) return Map<String, dynamic>.from(r);
    return {
      'id': id,
      'date': date.toIso8601String(),
      'visitType': visitType,
      'symptoms': symptoms,
      'diagnosis': diagnosis,
      'prescription': prescription,
      'notes': notes,
      'attachmentPaths': attachmentPaths,
      'bp': bp, 'temp': temp, 'pulse': pulse, 'weight': weight, 'sugar': sugar,
    };
  }

  /// Parses field by field. The original id and every readable field are
  /// kept; a bad field (for example the date) only affects that field.
  factory VisitRecord.fromJson(Map<String, dynamic> json) {
    final f = _FieldReader(json);
    final id = f.optStr('id');
    final hasId = id != null && id.isNotEmpty;
    // A missing id is flagged, never replaced by a newly invented one.
    if (!hasId) f.errors.add('id');
    final date = f.optDate('date');
    if (date == null) f.errors.add('date');
    return VisitRecord(
      id: hasId ? id : '',
      date: date ?? epochFallback,
      visitType: f.str('visitType', 'Regular Visit'),
      symptoms: f.str('symptoms', ''),
      diagnosis: f.str('diagnosis', ''),
      prescription: f.str('prescription', ''),
      notes: f.optStr('notes'),
      attachmentPaths: f.strList('attachmentPaths'),
      bp: f.optStr('bp'),
      temp: f.optStr('temp'),
      pulse: f.optStr('pulse'),
      weight: f.optStr('weight'),
      sugar: f.optStr('sugar'),
      parseErrors: List.unmodifiable(f.errors),
      raw: f.errors.isEmpty ? null : Map<String, dynamic>.from(json),
    );
  }

  /// A stored history entry that is not a JSON object at all.
  factory VisitRecord.unparseable(Object? raw) => VisitRecord(
        id: '',
        date: epochFallback,
        visitType: 'Unreadable record',
        symptoms: '',
        diagnosis: '',
        prescription: '',
        parseErrors: const ['record'],
        raw: raw,
      );
}

class Patient {
  final String id;
  final String name;
  final String age;
  final String gender;
  final String phone;
  final String relation;
  final List<VisitRecord> history;

  /// Names of patient-level fields that could not be parsed.
  final List<String> parseErrors;

  /// The original stored document, kept whenever parsing failed.
  final Object? raw;

  /// The local row's `updated_at` (decimal epoch milliseconds) when read
  /// from the local database; the compare-and-set token for
  /// `LocalDatabase.markSynced`. Not part of [toJson].
  final String? updatedAt;

  Patient({
    String? id,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    this.relation = 'Self',
    List<VisitRecord>? history,
    this.parseErrors = const [],
    this.raw,
    this.updatedAt,
  })  : id = id ?? const Uuid().v4(),
        history = history ?? [];

  /// True if this patient or any of its visits failed to parse. Such a
  /// patient is read-only: it must never be written locally or synced,
  /// because that would replace the stored data with placeholders.
  bool get hasParseErrors =>
      parseErrors.isNotEmpty || history.any((r) => r.parseFailed);

  Map<String, dynamic> toJson() {
    final r = raw;
    if (parseErrors.isNotEmpty && r is Map) return Map<String, dynamic>.from(r);
    return {
      'id': id,
      'name': name,
      'age': age,
      'gender': gender,
      'phone': phone,
      'relation': relation,
      'history': history.map((e) => e.toJson()).toList(),
    };
  }

  /// Parses field by field, keeping the original id (or [docId], the
  /// Firestore document id, when the body has none) and every readable field.
  /// Never invents a placeholder patient with a new id.
  factory Patient.fromJson(Map<String, dynamic> json,
      {String? docId, String? updatedAt}) {
    final f = _FieldReader(json);
    var id = f.optStr('id');
    if (id == null || id.isEmpty) {
      id = (docId != null && docId.isNotEmpty) ? docId : null;
      if (id == null) f.errors.add('id');
    }
    final history = <VisitRecord>[];
    final h = json['history'];
    if (h is List) {
      for (final e in h) {
        history.add(e is Map
            ? VisitRecord.fromJson(Map<String, dynamic>.from(e))
            : VisitRecord.unparseable(e));
      }
    } else if (h != null) {
      f.errors.add('history');
    }
    return Patient(
      id: id ?? '', // flagged above; never a newly invented id
      name: f.str('name', 'Unknown'),
      age: f.str('age', '0'),
      gender: f.str('gender', 'Other'),
      phone: f.str('phone', ''),
      relation: f.str('relation', 'Self'),
      history: history,
      parseErrors: List.unmodifiable(f.errors),
      raw: f.errors.isEmpty ? null : Map<String, dynamic>.from(json),
      updatedAt: updatedAt,
    );
  }
}

/// Thrown when the app tries to modify a patient that failed to parse.
/// Saving it would overwrite the stored data with placeholders.
class UnreadablePatientException implements Exception {
  UnreadablePatientException(this.patientId);
  final String patientId;
  @override
  String toString() =>
      'UnreadablePatientException($patientId): this patient has records that '
      'could not be read and cannot be modified.';
}
