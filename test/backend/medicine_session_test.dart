// Security (#6 / #16): the shared learned-medicines load flag
// (_learnedMedicinesLoaded) is reset together with the list on session end
// and owner change, through the real SessionController wiring, so the next
// doctor's first add (or #6's remove) before their own load never runs
// against the previous doctor's list and never persists it under them.
// Cloud mode on fakes only (FakeAuth, FakeFirestore); nothing contacted.
import 'dart:async';

import 'package:docease/providers/medicine_provider.dart';
import 'package:docease/services/session_controller.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// A real MedicineProvider; only B's load can be held at [gate] so the test
/// can act in the window between the switch and B's load.
class _GatedMedicines extends MedicineProvider {
  _GatedMedicines(this.fakeAuth, this.fs) : super(auth: fakeAuth, firestore: fs);
  final FakeAuth fakeAuth;
  final FakeFirestore fs;
  Completer<void>? gate;
  String? gatedUid;
  int clears = 0;
  @override
  Future<void> load(String uid) async {
    final g = gate;
    if (g != null && uid == gatedUid) await g.future;
    return super.load(uid);
  }

  @override
  void clear() {
    clears++;
    super.clear();
  }
}

const docA = 'doctors/a/settings/medicines';
const docB = 'doctors/b/settings/medicines';

void main() {
  late List<String> log;
  late SessionDb db;
  late StreamController<User?> auth;
  late FakeAuth fakeAuth;
  late FakeFirestore fs;
  late _GatedMedicines meds;
  late SessionController c;

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await flushMicrotasks();
      await c.idle;
    }
  }

  Future<void> signIn(String uid) async {
    fakeAuth.signIn(uid);
    auth.add(FakeUser(uid));
    await settle();
  }

  List<String> writesTo(String doc) => fs.log.where((l) => l.startsWith('set:$doc')).toList();

  setUp(() {
    log = [];
    db = SessionDb();
    auth = StreamController<User?>.broadcast();
    fakeAuth = FakeAuth();
    fs = FakeFirestore();
    fs.docs[docA] = {'items': ['AmoxA', 'ParaA']};
    fs.docs[docB] = {'items': ['ZincB']};
    meds = _GatedMedicines(fakeAuth, fs);
    c = SessionController(
      authStateChanges: auth.stream,
      db: db,
      patients: SpyPatients(log),
      doctor: SpyDoctor(log),
      medicines: meds,
      platform: FakeSessionPlatform(log),
      observeAppLifecycle: false,
    );
  });

  tearDown(() async {
    c.dispose();
    await auth.close();
  });

  test('switch A -> B: an add before B loads is not saved, and A\'s list never reaches B', () async {
    await signIn('a');
    expect(meds.learnedMedicinesLoaded, isTrue);
    expect(meds.frequentMedicines, ['AmoxA', 'ParaA']);

    meds
      ..gatedUid = 'b'
      ..gate = Completer<void>();
    final clearsBefore = meds.clears;
    await signIn('b'); // owner change through the session controller
    expect(meds.clears, greaterThan(clearsBefore), reason: 'the owner-change path calls MedicineProvider.clear()');
    expect(meds.learnedMedicinesLoaded, isFalse, reason: "#6's removeLearnedMedicine refuses exactly on this flag");
    expect(meds.frequentMedicines, isEmpty, reason: "A's list is gone with the flag");

    fs.log.clear();
    await meds.addMedicineIfNew('NewB');
    await flushMicrotasks();
    expect(writesTo(docB), isEmpty, reason: 'nothing saved before B\'s list was read');
    expect(writesTo(docA), isEmpty);
    expect(fs.docs[docB], {'items': ['ZincB']});

    meds.gate!.complete();
    await settle();
    expect(meds.learnedMedicinesLoaded, isTrue);
    expect(meds.frequentMedicines, ['ZincB', 'NewB']);
    final savedB = (fs.docs[docB]!['items'] as List).cast<String>();
    expect(savedB, ['ZincB', 'NewB']);
    expect(savedB, isNot(anyOf(contains('AmoxA'), contains('ParaA'))));
    expect(fs.docs[docA], {'items': ['AmoxA', 'ParaA']}, reason: "A's stored list untouched");
  });

  test('sign-out after A: the flag and list are reset, an add is memory-only, and B never gets A\'s list', () async {
    await signIn('a');
    expect(meds.learnedMedicinesLoaded, isTrue);
    await c.signOut();
    fakeAuth.currentUser = null;
    auth.add(null);
    await settle();
    expect(meds.learnedMedicinesLoaded, isFalse);
    expect(meds.frequentMedicines, isEmpty);

    fs.log.clear();
    await meds.addMedicineIfNew('Stray');
    await flushMicrotasks();
    expect(fs.log.where((l) => l.startsWith('set:')), isEmpty);

    await signIn('b');
    final savedB = (fs.docs[docB]!['items'] as List).cast<String>();
    expect(meds.frequentMedicines, isNot(anyOf(contains('AmoxA'), contains('ParaA'))));
    expect(savedB, isNot(anyOf(contains('AmoxA'), contains('ParaA'))));
    expect(fs.docs[docA], {'items': ['AmoxA', 'ParaA']});
  });

  test('load() for a different owner without clear() also resets the flag first', () async {
    final m = _GatedMedicines(FakeAuth('a'), fs);
    await m.load('a');
    expect(m.learnedMedicinesLoaded, isTrue);
    m
      ..gatedUid = 'b'
      ..gate = Completer<void>();
    m.fakeAuth.signIn('b');
    final pending = m.load('b');
    await flushMicrotasks();
    // No clear() from a session controller here: load('b') itself must
    // reset A's state before B's read.
    expect(m.frequentMedicines, ['AmoxA', 'ParaA'], reason: 'still held at the gate');
    m.gate!.complete();
    await pending;
    expect(m.learnedMedicinesLoaded, isTrue);
    expect(m.frequentMedicines, ['ZincB']);
    expect(m.clears, 1, reason: 'switching owner inside load() clears A first');
  });
}
