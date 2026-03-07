import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

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
  })  : id = id ?? const Uuid().v4(),
        attachmentPaths = attachmentPaths ?? [];

  Map<String, dynamic> toJson() => {
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

  factory VisitRecord.fromJson(Map<String, dynamic> json) {
    try {
      return VisitRecord(
        id: json['id'] as String? ?? const Uuid().v4(),
        date: json['date'] != null ? DateTime.parse(json['date'] as String) : DateTime.now(),
        visitType: json['visitType'] as String? ?? 'Regular Visit',
        symptoms: json['symptoms'] as String? ?? '',
        diagnosis: json['diagnosis'] as String? ?? '',
        prescription: json['prescription'] as String? ?? '',
        notes: json['notes'] as String?,
        attachmentPaths: (json['attachmentPaths'] as List?)?.map((e) => e as String).toList() ?? [],
        bp: json['bp'] as String?,
        temp: json['temp'] as String?,
        pulse: json['pulse'] as String?,
        weight: json['weight'] as String?,
        sugar: json['sugar'] as String?,
      );
    } catch (e) {
      return VisitRecord(date: DateTime.now(), visitType: 'Error', symptoms: 'Error parsing', diagnosis: '', prescription: '');
    }
  }
}

class Patient {
  final String id;
  final String name;
  final String age;
  final String gender;
  final String phone;
  final String relation;
  final List<VisitRecord> history;

  Patient({
    String? id,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    this.relation = 'Self',
    List<VisitRecord>? history,
  })  : id = id ?? const Uuid().v4(),
        history = history ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'age': age,
        'gender': gender,
        'phone': phone,
        'relation': relation,
        'history': history.map((e) => e.toJson()).toList(),
      };

  factory Patient.fromJson(Map<String, dynamic> json) {
    try {
      return Patient(
        id: json['id'] as String? ?? const Uuid().v4(),
        name: json['name'] as String? ?? 'Unknown',
        age: json['age'] as String? ?? '0',
        gender: json['gender'] as String? ?? 'Other',
        phone: json['phone'] as String? ?? '',
        relation: json['relation'] as String? ?? 'Self',
        history: (json['history'] as List?)?.map((e) => VisitRecord.fromJson(e as Map<String, dynamic>)).toList() ?? [],
      );
    } catch (e) {
      return Patient(name: 'Parse Error', age: '0', gender: 'Other', phone: '');
    }
  }
}
