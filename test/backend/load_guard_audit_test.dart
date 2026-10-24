// DB engineer's audit of lenient reads (#16):
// - MedicineProvider never saves over a list it could not read (local
//   settings or Firestore); additions made meanwhile are kept in memory and
//   saved together with the stored list once it loads;
// - PatientProvider's push reads dirty rows and tombstones strictly: a
//   failed read pushes nothing and keeps the retry pending (never "all
//   synced").
// Fakes only; runs in both suite modes.
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:docease/providers/local_database.dart';
import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/providers/patient_provider.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

class _SettingsDb extends FakeLocalDatabase {
  bool getThrows = false;
  int puts = 0;
  @override
  Future<String?> getSetting(String key) async {
    if (getThrows) throw StateError('read failed');
    return super.getSetting(key);
  }

  @override
  Future<void> putSetting(String key, String value) async {
    puts++;
    return super.putSetting(key, value);
  }
}

class _TombstoneReadFailsDb extends MergeDb {
  bool failTombstoneRead = false;
  @override
  Future<List<String>> pendingDeletesStrict() async {
    if (failTombstoneRead) throw const DbReadException(DbReadFailure.readFailed);
    return super.pendingDeletesStrict();
  }
}

void main() {
  const key = MedicineProvider.localSettingKey;

  group('MedicineProvider never saves over an unread list', () {
    late _SettingsDb db;
    MedicineProvider local() =>
        MedicineProvider(cloudSync: false, localDb: db, auth: FakeAuth('local'), firestore: FakeFirestore());

    setUp(() {
      db = _SettingsDb()..state = const DbReady('local');
      db.settings[key] = jsonEncode(['A', 'B']);
    });

    test('local read fails: loadFailed, the addition stays in memory, the stored list is untouched', () async {
      final m = local();
      db.getThrows = true;
      await m.load('local');
      expect(m.loadFailed, isTrue);
      await m.addMedicineIfNew('X');
      expect(m.frequentMedicines, ['X']);
      expect(db.puts, 0);
      expect(jsonDecode(db.settings[key]!), ['A', 'B']);

      db.getThrows = false;
      await m.load('local'); // a failed load can be retried
      expect(m.loadFailed, isFalse);
      expect(m.frequentMedicines, ['A', 'B', 'X']);
      await flushMicrotasks();
      expect(jsonDecode(db.settings[key]!), ['A', 'B', 'X'], reason: 'merged, not replaced');
    });

    test('stored value that is not a list is a failed load, never overwritten', () async {
      db.settings[key] = jsonEncode({'not': 'a list'});
      final m = local();
      await m.load('local');
      expect(m.loadFailed, isTrue);
      await m.addMedicineIfNew('X');
      expect(db.puts, 0);
      expect(jsonDecode(db.settings[key]!), {'not': 'a list'});
    });

    test('a loaded list saves additions as before', () async {
      final m = local();
      await m.load('local');
      expect((m.loadFailed, m.frequentMedicines.join(',')), (false, 'A,B'));
      await m.addMedicineIfNew('C');
      expect(jsonDecode(db.settings[key]!), ['A', 'B', 'C']);
    });

    test('cloud read fails: no Firestore write until the list loads', () async {
      final fs = FakeFirestore();
      fs.docs['doctors/a/settings/medicines'] = {'items': ['A']};
      final m = MedicineProvider(auth: FakeAuth('a'), firestore: fs);
      fs.failReads = FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
      await m.load('a');
      expect(m.loadFailed, isTrue);
      fs.log.clear();
      await m.addMedicineIfNew('B');
      expect(fs.log.where((l) => l.startsWith('set:')), isEmpty);
      expect(fs.docs['doctors/a/settings/medicines'], {'items': ['A']});

      fs.failReads = null;
      await m.load('a');
      await flushMicrotasks();
      expect(m.frequentMedicines, ['A', 'B']);
      expect(fs.docs['doctors/a/settings/medicines'], {'items': ['A', 'B']});
    });
  });

  group('PatientProvider push uses strict reads', () {
    late _TombstoneReadFailsDb db;
    late CloudFirestoreHelper remote;
    late PatientProvider provider;

    setUp(() async {
      db = _TombstoneReadFailsDb()..state = const DbReady('doctorA');
      db.rows['p1'] = testPatient('p1');
      remote = CloudFirestoreHelper();
      provider = PatientProvider(
          db: db, firestore: remote, auth: FakeAuth('doctorA'), storage: FakeStorage(),
          retryBaseDelay: const Duration(hours: 1), retryMaxDelay: const Duration(hours: 1));
      await provider.loadAndSync('doctorA');
      await flushMicrotasks();
    });

    tearDown(() => provider.dispose());

    test('dirty rows cannot be read: nothing pushed, the row stays dirty, the retry stays pending', () async {
      db.dirty['p1'] = true;
      db.failDirtyRead = true;
      remote.payloads.clear();
      await provider.retryDirty();
      await flushMicrotasks();
      expect(remote.payloads, isEmpty);
      expect(db.dirty['p1'], isTrue);
      expect(provider.retryPendingForTesting, isTrue, reason: 'a read error is not "all synced"');
    });

    test('tombstones cannot be read: no cloud delete, the tombstone stays, the retry stays pending', () async {
      db.tombstones.add('gone');
      db.failTombstoneRead = true;
      await provider.retryDirty();
      await flushMicrotasks();
      expect(remote.deletes, isEmpty);
      expect(db.tombstones, contains('gone'));
      expect(provider.retryPendingForTesting, isTrue);
    });

    test('source pin: the push and the tombstone pass never use the lenient reads', () {
      final s = File('lib/providers/patient_provider.dart').readAsStringSync();
      expect(s, isNot(contains('_db.dirtyPatients()')));
      expect(s, isNot(contains('_db.pendingDeletes()')));
      expect(s, isNot(contains('_db.fetchPatients()')));
    });
  });
}
