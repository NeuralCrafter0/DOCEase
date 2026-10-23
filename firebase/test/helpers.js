// Shared setup for the rules tests. Uses only the local Emulator Suite:
// the project id starts with "demo-", which the Firebase tools treat as an
// offline demo project, so nothing can reach the live project.
import { readFileSync } from 'node:fs';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';

export const PROJECT_ID = 'demo-docease';
export const A = 'doctorA';
export const B = 'doctorB';
// Verified email but no approvedDoctors entry.
export const UNAPPROVED = 'doctorUnapproved';
// Has an approvedDoctors entry but email_verified is false.
export const UNVERIFIED = 'doctorUnverified';
// Doctors with an approvedDoctors/{uid} entry.
export const APPROVED = [A, B, UNVERIFIED];

// ID-token claims for a context. Only UNVERIFIED gets email_verified: false.
export const claims = (uid) => ({ email_verified: uid !== UNVERIFIED });

// Seeds the admin-managed allowlist (rules disabled = Admin SDK).
export async function seedApproved(admin, setDoc, doc) {
  for (const u of APPROVED) {
    await setDoc(doc(admin, `approvedDoctors/${u}`), { approvedBy: 'test' });
  }
}

const rulesFile = (name) =>
  readFileSync(new URL(`../${name}`, import.meta.url), 'utf8');

export async function firestoreEnv() {
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: { rules: rulesFile('firestore.rules') },
  });
}

// Storage rules read approvedDoctors/{uid} from Firestore (cross-service
// firestore.exists), so the Storage tests run the Firestore emulator too.
export async function storageEnv() {
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    storage: { rules: rulesFile('storage.rules') },
    firestore: { rules: rulesFile('firestore.rules') },
  });
}

// Payloads shaped exactly like the app's toJson() output.
export const patient = (id = 'p1', extra = {}) => ({
  id,
  name: 'Asha',
  age: '34',
  gender: 'Female',
  phone: '+919999999999',
  relation: 'Self',
  history: [
    {
      id: 'r1',
      date: '2026-10-01T00:00:00.000',
      visitType: 'Routine',
      symptoms: 'cough',
      diagnosis: 'URTI',
      prescription: 'Paracetamol 500mg',
      notes: null,
      attachmentPaths: [],
      bp: '120/80',
      temp: null,
      pulse: null,
      weight: null,
      sugar: null,
    },
  ],
  ...extra,
});

export const doctorProfile = (uid, extra = {}) => ({
  id: uid,
  title: 'DR',
  name: 'John',
  email: 'john@example.com',
  age: '40',
  mobileNumber: '+919000000000',
  specialty: 'GP',
  clinicName: 'City Clinic',
  practiceMode: 'Solo Practice',
  profileImageUrl: null,
  ...extra,
});
