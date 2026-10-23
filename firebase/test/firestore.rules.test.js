// Firestore rules tests. Run with `npm test` from firebase/ (starts the
// emulators) or `npm run test:run` against already running emulators.
import { after, before, beforeEach, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where,
} from 'firebase/firestore';
import {
  A,
  B,
  UNAPPROVED,
  UNVERIFIED,
  claims,
  doctorProfile,
  firestoreEnv,
  patient,
  seedApproved,
} from './helpers.js';

let env;
const db = (uid) =>
  (uid
    ? env.authenticatedContext(uid, claims(uid))
    : env.unauthenticatedContext()
  ).firestore();
const meds = (uid) => `doctors/${uid}/settings/medicines`;

before(async () => {
  env = await firestoreEnv();
});
after(async () => env.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const admin = ctx.firestore();
    await seedApproved(admin, setDoc, doc);
    for (const u of [A, B, UNAPPROVED, UNVERIFIED]) {
      await setDoc(doc(admin, `doctors/${u}`), {
        ...doctorProfile(u),
        frequentMedicines: ['Legacy 1'],
      });
      await setDoc(doc(admin, `doctors/${u}/patients/p1`), patient('p1'));
      await setDoc(doc(admin, meds(u)), { items: ['Paracetamol 500mg'] });
    }
  });
});

describe('unauthenticated access is denied everywhere', () => {
  for (const path of [`doctors/${A}`, `doctors/${A}/patients/p1`, meds(A)]) {
    test(`get / set / delete ${path}`, async () => {
      await assertFails(getDoc(doc(db(null), path)));
      await assertFails(setDoc(doc(db(null), path), { items: [] }));
      await assertFails(deleteDoc(doc(db(null), path)));
    });
  }
  test('list patients', async () => {
    await assertFails(getDocs(collection(db(null), `doctors/${A}/patients`)));
  });
});

describe('owner access to own data', () => {
  test('profile: get, create, merge-save', async () => {
    await assertSucceeds(getDoc(doc(db(A), `doctors/${A}`)));
    await env.withSecurityRulesDisabled(async (ctx) =>
      deleteDoc(doc(ctx.firestore(), `doctors/${A}`)));
    await assertSucceeds(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A)));
    await assertSucceeds(
      setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, { name: 'New' }), { merge: true }));
  });
  test('profile merge-save keeps the legacy frequentMedicines field readable', async () => {
    await assertSucceeds(
      setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A), { merge: true }));
    const snap = await assertSucceeds(getDoc(doc(db(A), `doctors/${A}`)));
    assert.deepEqual(snap.data().frequentMedicines, ['Legacy 1']);
  });
  test('profile with a Firebase Storage avatar URL', async () => {
    await assertSucceeds(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, {
      profileImageUrl:
        'https://firebasestorage.googleapis.com/v0/b/x.appspot.com/o/doctor_profiles%2FdoctorA%2F1.jpg?alt=media&token=t',
    }), { merge: true }));
  });
  test('patients: create, update, get, list, delete', async () => {
    await assertSucceeds(setDoc(doc(db(A), `doctors/${A}/patients/p2`), patient('p2')));
    await assertSucceeds(updateDoc(doc(db(A), `doctors/${A}/patients/p2`), { name: 'Asha K' }));
    await assertSucceeds(getDoc(doc(db(A), `doctors/${A}/patients/p2`)));
    await assertSucceeds(getDocs(collection(db(A), `doctors/${A}/patients`)));
    await assertSucceeds(deleteDoc(doc(db(A), `doctors/${A}/patients/p2`)));
  });
  test('patients: blank name/phone still sync (forms allow them today)', async () => {
    await assertSucceeds(setDoc(doc(db(A), `doctors/${A}/patients/p3`),
      patient('p3', { name: '', phone: '' })));
  });
  test('settings/medicines: get, create, merge-update, clear to []', async () => {
    await assertSucceeds(getDoc(doc(db(A), meds(A))));
    await env.withSecurityRulesDisabled(async (ctx) => deleteDoc(doc(ctx.firestore(), meds(A))));
    await assertSucceeds(setDoc(doc(db(A), meds(A)), { items: ['Legacy 1'] }));
    await assertSucceeds(setDoc(doc(db(A), meds(A)), { items: ['A', 'B'] }, { merge: true }));
    await assertSucceeds(setDoc(doc(db(A), meds(A)), { items: [] }, { merge: true }));
  });
});

describe('doctor A is denied on doctor B data (read, list, write, delete)', () => {
  test('B profile', async () => {
    await assertFails(getDoc(doc(db(A), `doctors/${B}`)));
    await assertFails(setDoc(doc(db(A), `doctors/${B}`), doctorProfile(B), { merge: true }));
    await assertFails(updateDoc(doc(db(A), `doctors/${B}`), { name: 'x' }));
    await assertFails(deleteDoc(doc(db(A), `doctors/${B}`)));
  });
  test('B patients: get', async () => {
    await assertFails(getDoc(doc(db(A), `doctors/${B}/patients/p1`)));
  });
  test('B patients: list', async () => {
    await assertFails(getDocs(collection(db(A), `doctors/${B}/patients`)));
    await assertFails(getDocs(query(collection(db(A), `doctors/${B}/patients`),
      where('name', '==', 'Asha'))));
  });
  test('B patients: create, set, update', async () => {
    await assertFails(setDoc(doc(db(A), `doctors/${B}/patients/p9`), patient('p9')));
    await assertFails(setDoc(doc(db(A), `doctors/${B}/patients/p1`), patient('p1')));
    await assertFails(updateDoc(doc(db(A), `doctors/${B}/patients/p1`), { name: 'x' }));
  });
  test('B patients: delete', async () => {
    await assertFails(deleteDoc(doc(db(A), `doctors/${B}/patients/p1`)));
  });
  test('B settings/medicines: get, list, write, delete', async () => {
    await assertFails(getDoc(doc(db(A), meds(B))));
    await assertFails(getDocs(collection(db(A), `doctors/${B}/settings`)));
    await assertFails(setDoc(doc(db(A), meds(B)), { items: ['x'] }, { merge: true }));
    await assertFails(updateDoc(doc(db(A), meds(B)), { items: [] }));
    await assertFails(deleteDoc(doc(db(A), meds(B))));
  });
});

describe('no listing across doctors', () => {
  test('list the doctors collection (even filtered to own id)', async () => {
    await assertFails(getDocs(collection(db(A), 'doctors')));
    await assertFails(getDocs(query(collection(db(A), 'doctors'), where('id', '==', A))));
  });
  test('collection-group query on patients', async () => {
    await assertFails(getDocs(query(collectionGroup(db(A), 'patients'))));
    await assertFails(getDocs(query(collectionGroup(db(A), 'patients'), where('id', '==', 'p1'))));
  });
  test('collection-group query on settings', async () => {
    await assertFails(getDocs(query(collectionGroup(db(A), 'settings'))));
  });
});

describe('doctor profile validation', () => {
  test('id in body must equal the path uid', async () => {
    await assertFails(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, { id: B }), { merge: true }));
  });
  test('id is required on the profile document', async () => {
    await env.withSecurityRulesDisabled(async (ctx) =>
      deleteDoc(doc(ctx.firestore(), `doctors/${A}`)));
    const { id, ...noId } = doctorProfile(A);
    await assertFails(setDoc(doc(db(A), `doctors/${A}`), noId));
    await assertFails(setDoc(doc(db(A), `doctors/${A}`), { frequentMedicines: ['x'] }, { merge: true }));
  });
  test('cannot create another doctor document', async () => {
    await assertFails(setDoc(doc(db(A), 'doctors/doctorC'), doctorProfile('doctorC')));
  });
  test('unknown fields are rejected', async () => {
    await assertFails(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, { role: 'admin' }), { merge: true }));
  });
  test('wrong types and oversize strings are rejected', async () => {
    await assertFails(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, { age: 40 }), { merge: true }));
    await assertFails(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, { name: 'x'.repeat(201) }), { merge: true }));
  });
  test('avatar must be a Firebase Storage https URL', async () => {
    for (const url of ['/data/user/0/docease/cache/a.jpg', 'http://firebasestorage.googleapis.com/x',
      'https://evil.example/x.jpg', 'javascript:alert(1)']) {
      await assertFails(setDoc(doc(db(A), `doctors/${A}`), doctorProfile(A, { profileImageUrl: url }), { merge: true }));
    }
  });
  test('owner cannot delete the profile document', async () => {
    await assertFails(deleteDoc(doc(db(A), `doctors/${A}`)));
  });
});

describe('patient validation', () => {
  const p = (id) => doc(db(A), `doctors/${A}/patients/${id}`);
  test('body id must equal the document id', async () => {
    await assertFails(setDoc(p('p5'), patient('other')));
  });
  test('all app fields are required', async () => {
    const { history, ...noHistory } = patient('p5');
    await assertFails(setDoc(p('p5'), noHistory));
    const { relation, ...noRelation } = patient('p5');
    await assertFails(setDoc(p('p5'), noRelation));
  });
  test('unknown fields are rejected', async () => {
    await assertFails(setDoc(p('p5'), patient('p5', { isAdmin: true })));
  });
  test('wrong types are rejected', async () => {
    await assertFails(setDoc(p('p5'), patient('p5', { age: 34 })));
    await assertFails(setDoc(p('p5'), patient('p5', { history: 'none' })));
    await assertFails(setDoc(p('p5'), patient('p5', { name: null })));
  });
  test('oversize values are rejected', async () => {
    await assertFails(setDoc(p('p5'), patient('p5', { name: 'x'.repeat(201) })));
    await assertFails(setDoc(p('p5'), patient('p5', { phone: '1'.repeat(33) })));
    await assertFails(setDoc(p('p5'), patient('p5', { history: Array(1001).fill({}) })));
  });
  test('an ownership field must match the path uid', async () => {
    await assertSucceeds(setDoc(p('p6'), patient('p6', { doctorId: A })));
    await assertFails(setDoc(p('p7'), patient('p7', { doctorId: B })));
    await assertFails(setDoc(p('p7'), patient('p7', { owner: B })));
    await assertFails(setDoc(p('p7'), patient('p7', { ownerUid: B })));
  });
});

describe('settings/medicines validation', () => {
  const m = () => doc(db(A), meds(A));
  test('items must be present and a list', async () => {
    await assertFails(setDoc(m(), {}));
    await assertFails(setDoc(m(), { items: 'Paracetamol' }));
  });
  test('items must be strings', async () => {
    await assertFails(setDoc(m(), { items: [1, 2] }));
    await assertFails(setDoc(m(), { items: ['ok', null] }));
  });
  test('each name is 1-200 characters with no line break', async () => {
    await assertSucceeds(setDoc(m(), { items: ['x'.repeat(200)] }));
    await assertFails(setDoc(m(), { items: ['x'.repeat(201)] }));
    await assertFails(setDoc(m(), { items: [''] }));
    await assertFails(setDoc(m(), { items: ['ok', ''] }));
    await assertFails(setDoc(m(), { items: ['a\nb'] }));
    await assertFails(setDoc(m(), { items: ['ok', 'x'.repeat(201), 'ok'] }));
  });
  test('at most 2,000 entries', async () => {
    const names = (n) => Array.from({ length: n }, (_, i) => `Medicine ${i}`);
    await assertSucceeds(setDoc(m(), { items: names(2000) }));
    await assertFails(setDoc(m(), { items: names(2001) }));
  });
  test('no other fields', async () => {
    await assertFails(setDoc(m(), { items: [], extra: 1 }));
  });
  test('only the medicines document is allowed under settings', async () => {
    await assertFails(setDoc(doc(db(A), `doctors/${A}/settings/anything`), { items: [] }));
    await assertFails(getDoc(doc(db(A), `doctors/${A}/settings/anything`)));
    await assertFails(getDocs(collection(db(A), `doctors/${A}/settings`)));
  });
  test('owner cannot delete it', async () => {
    await assertFails(deleteDoc(m()));
  });
});

describe('default deny', () => {
  test('unknown top-level and nested paths', async () => {
    await assertFails(getDoc(doc(db(A), 'admin/config')));
    await assertFails(setDoc(doc(db(A), 'admin/config'), { x: 1 }));
    await assertFails(setDoc(doc(db(A), `doctors/${A}/other/x`), { x: 1 }));
    await assertFails(getDoc(doc(db(A), `doctors/${A}/patients/p1/visits/v1`)));
    await assertFails(setDoc(doc(db(A), `doctors/${A}/patients/p1/visits/v1`), { x: 1 }));
  });
});

describe('approval gate: verified email AND approvedDoctors/{uid} required', () => {
  for (const [who, uid] of [
    ['unapproved (verified, no allowlist entry)', UNAPPROVED],
    ['unverified (allowlisted, email_verified false)', UNVERIFIED],
  ]) {
    test(`${who}: denied on own profile, patients, settings`, async () => {
      const d = db(uid);
      await assertFails(getDoc(doc(d, `doctors/${uid}`)));
      await assertFails(setDoc(doc(d, `doctors/${uid}`), doctorProfile(uid), { merge: true }));
      await assertFails(getDoc(doc(d, `doctors/${uid}/patients/p1`)));
      await assertFails(getDocs(collection(d, `doctors/${uid}/patients`)));
      await assertFails(setDoc(doc(d, `doctors/${uid}/patients/p2`), patient('p2')));
      await assertFails(deleteDoc(doc(d, `doctors/${uid}/patients/p1`)));
      await assertFails(getDoc(doc(d, meds(uid))));
      await assertFails(setDoc(doc(d, meds(uid)), { items: ['X'] }));
    });
  }

  test('token without an email_verified claim is denied', async () => {
    const d = env.authenticatedContext(A).firestore();
    await assertFails(getDoc(doc(d, `doctors/${A}`)));
    await assertFails(getDocs(collection(d, `doctors/${A}/patients`)));
  });

  test('approved + verified doctor is still limited to own data', async () => {
    await assertSucceeds(getDoc(doc(db(A), `doctors/${A}/patients/p1`)));
    await assertFails(getDoc(doc(db(A), `doctors/${UNAPPROVED}/patients/p1`)));
    await assertFails(getDoc(doc(db(A), `doctors/${B}/patients/p1`)));
  });
});

describe('approvedDoctors allowlist', () => {
  test('a doctor can read only their own entry (present or missing)', async () => {
    await assertSucceeds(getDoc(doc(db(A), `approvedDoctors/${A}`)));
    const missing = await assertSucceeds(getDoc(doc(db(UNAPPROVED), `approvedDoctors/${UNAPPROVED}`)));
    assert.equal(missing.exists(), false);
    // Readable even before email verification so the app can say why.
    await assertSucceeds(getDoc(doc(db(UNVERIFIED), `approvedDoctors/${UNVERIFIED}`)));
  });

  test('reading another doctor\'s entry or listing is denied', async () => {
    await assertFails(getDoc(doc(db(A), `approvedDoctors/${B}`)));
    await assertFails(getDocs(collection(db(A), 'approvedDoctors')));
    await assertFails(getDoc(doc(db(null), `approvedDoctors/${A}`)));
  });

  test('no client can approve itself or change/delete an entry', async () => {
    await assertFails(setDoc(doc(db(UNAPPROVED), `approvedDoctors/${UNAPPROVED}`), { approvedBy: 'me' }));
    await assertFails(setDoc(doc(db(A), `approvedDoctors/${A}`), { approvedBy: 'me' }, { merge: true }));
    await assertFails(deleteDoc(doc(db(A), `approvedDoctors/${A}`)));
    await assertFails(setDoc(doc(db(A), `approvedDoctors/${UNAPPROVED}`), { approvedBy: A }));
  });
});
