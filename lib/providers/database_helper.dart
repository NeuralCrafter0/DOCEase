import 'dart:convert';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import '../models/patient.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static const _storage = FlutterSecureStorage();

  DatabaseHelper._init();

  // Safer initialization
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('docease_production_v1.db');
    return _database!;
  }

  Future<String> _getEncryptionKey() async {
    try {
      String? key = await _storage.read(key: 'db_encryption_key_prod');
      if (key == null) {
        key = const Uuid().v4();
        await _storage.write(key: 'db_encryption_key_prod', value: key);
      }
      return key;
    } catch (e) {
      debugPrint('STORAGE ERROR: $e');
      return 'fallback_secure_key_123'; // Last resort fallback to prevent crash
    }
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    final password = await _getEncryptionKey();
    
    try {
      return await openDatabase(path, version: 1, password: password, onCreate: _createDB);
    } catch (e) {
      debugPrint('DB OPEN ERROR: $e. Attempting recovery...');
      // If it fails (maybe wrong password?), try without password or fresh file
      return await openDatabase(path, version: 1, onCreate: _createDB);
    }
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE patients (
        id TEXT PRIMARY KEY,
        name TEXT, age TEXT, gender TEXT, phone TEXT, relation TEXT, history TEXT
      )
    ''');
  }

  Future<void> insertPatient(Patient patient) async {
    try {
      final db = await database;
      await db.insert('patients', {
        'id': patient.id, 'name': patient.name, 'age': patient.age,
        'gender': patient.gender, 'phone': patient.phone, 'relation': patient.relation,
        'history': jsonEncode(patient.history.map((e) => e.toJson()).toList()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) { debugPrint('SQLITE Error: $e'); }
  }

  Future<void> updatePatient(Patient patient) async {
    try {
      final db = await database;
      await db.update('patients', {
        'id': patient.id, 'name': patient.name, 'age': patient.age,
        'gender': patient.gender, 'phone': patient.phone, 'relation': patient.relation,
        'history': jsonEncode(patient.history.map((e) => e.toJson()).toList()),
      }, where: 'id = ?', whereArgs: [patient.id]);
    } catch (e) { debugPrint('SQLITE Update Error: $e'); }
  }

  Future<List<Patient>> fetchPatients() async {
    try {
      final db = await database;
      final result = await db.query('patients');
      return result.map((json) {
        final historyList = (jsonDecode(json['history'] as String) as List);
        return Patient(
          id: json['id'] as String, name: json['name'] as String, age: json['age'] as String,
          gender: json['gender'] as String, phone: json['phone'] as String, relation: json['relation'] as String? ?? 'Self',
          history: historyList.map((e) => VisitRecord.fromJson(e)).toList(),
        );
      }).toList();
    } catch (e) { return []; }
  }

  Future<void> deletePatient(String id) async {
    try {
      final db = await database;
      await db.delete('patients', where: 'id = ?', whereArgs: [id]);
    } catch (e) { debugPrint('SQLITE Delete Error: $e'); }
  }
}
