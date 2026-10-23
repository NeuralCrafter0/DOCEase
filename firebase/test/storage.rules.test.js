// Cloud Storage rules tests. Run with `npm test` from firebase/.
import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import {
  deleteObject,
  getBytes,
  getMetadata,
  listAll,
  ref,
  updateMetadata,
  uploadBytes,
} from 'firebase/storage';
import { doc, setDoc } from 'firebase/firestore';
import { A, B, UNAPPROVED, UNVERIFIED, claims, seedApproved, storageEnv } from './helpers.js';

let env;
const st = (uid) =>
  (uid
    ? env.authenticatedContext(uid, claims(uid))
    : env.unauthenticatedContext()
  ).storage();

const MB = 1024 * 1024;
const bytes = (n) => new Uint8Array(n).fill(7);
const jpg = bytes(16);
const JPEG = { contentType: 'image/jpeg' };

// Paths the app writes today / after this change.
const att = (uid, name = 'x.jpg') => `clinical_attachments/${uid}/p1/${name}`;
const avatar = (uid, name = '1729700000000.jpg') => `doctor_profiles/${uid}/${name}`;

before(async () => {
  env = await storageEnv();
});
after(async () => env.cleanup());

beforeEach(async () => {
  await env.clearStorage();
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    await seedApproved(ctx.firestore(), setDoc, doc);
    for (const u of [A, B, UNAPPROVED, UNVERIFIED]) {
      await uploadBytes(ref(ctx.storage(), att(u)), jpg, JPEG);
      await uploadBytes(ref(ctx.storage(), avatar(u)), jpg, JPEG);
    }
  });
});

describe('unauthenticated access is denied', () => {
  for (const path of [att(A), avatar(A)]) {
    test(path, async () => {
      await assertFails(getBytes(ref(st(null), path)));
      await assertFails(uploadBytes(ref(st(null), path.replace(/[^/]+$/, 'new.jpg')), jpg, JPEG));
      await assertFails(deleteObject(ref(st(null), path)));
    });
  }
});

describe('owner access', () => {
  test('attachment: get, create (jpeg/png/webp), delete', async () => {
    await assertSucceeds(getBytes(ref(st(A), att(A))));
    await assertSucceeds(uploadBytes(ref(st(A), att(A, 'a.jpg')), jpg, JPEG));
    await assertSucceeds(uploadBytes(ref(st(A), att(A, 'b.png')), jpg, { contentType: 'image/png' }));
    await assertSucceeds(uploadBytes(ref(st(A), att(A, 'c.webp')), jpg, { contentType: 'image/webp' }));
    await assertSucceeds(deleteObject(ref(st(A), att(A, 'a.jpg'))));
  });
  test('attachment named like the app names it ({uuid}.jpg)', async () => {
    await assertSucceeds(uploadBytes(
      ref(st(A), att(A, '3f2c1d5e-9a8b-4c7d-8e6f-1a2b3c4d5e6f.jpg')), jpg, JPEG));
  });
  test('avatar: get, create at doctor_profiles/{uid}/{timestamp}.jpg, delete', async () => {
    await assertSucceeds(getBytes(ref(st(A), avatar(A))));
    await assertSucceeds(uploadBytes(ref(st(A), avatar(A, '1729700000001.jpg')), jpg, JPEG));
    await assertSucceeds(deleteObject(ref(st(A), avatar(A, '1729700000001.jpg'))));
  });
});

describe('doctor A is denied on doctor B objects (read, list, write, delete)', () => {
  test('B clinical_attachments', async () => {
    await assertFails(getBytes(ref(st(A), att(B))));
    await assertFails(getMetadata(ref(st(A), att(B))));
    await assertFails(listAll(ref(st(A), `clinical_attachments/${B}/p1`)));
    await assertFails(listAll(ref(st(A), `clinical_attachments/${B}`)));
    await assertFails(uploadBytes(ref(st(A), att(B, 'y.jpg')), jpg, JPEG));
    await assertFails(uploadBytes(ref(st(A), att(B)), jpg, JPEG));
    await assertFails(updateMetadata(ref(st(A), att(B)), { contentType: 'image/png' }));
    await assertFails(deleteObject(ref(st(A), att(B))));
  });
  test('B doctor_profiles (avatars are owner-only)', async () => {
    await assertFails(getBytes(ref(st(A), avatar(B))));
    await assertFails(getMetadata(ref(st(A), avatar(B))));
    await assertFails(listAll(ref(st(A), `doctor_profiles/${B}`)));
    await assertFails(uploadBytes(ref(st(A), avatar(B, '2.jpg')), jpg, JPEG));
    await assertFails(uploadBytes(ref(st(A), avatar(B)), jpg, JPEG));
    await assertFails(deleteObject(ref(st(A), avatar(B))));
  });
});

describe('content type limits (jpeg, png, webp only)', () => {
  for (const contentType of ['image/gif', 'image/svg+xml', 'application/x-sh',
    'application/pdf', 'application/octet-stream', 'text/html']) {
    test(`${contentType} is denied on both paths`, async () => {
      await assertFails(uploadBytes(ref(st(A), att(A, 'n.jpg')), jpg, { contentType }));
      await assertFails(uploadBytes(ref(st(A), avatar(A, '9.jpg')), jpg, { contentType }));
    });
  }
  test('upload without an explicit content type is denied', async () => {
    await assertFails(uploadBytes(ref(st(A), att(A, 'n.jpg')), jpg));
  });
});

describe('size limits', () => {
  test('attachments: 10 MB allowed, 10 MB + 1 byte denied, empty denied', async () => {
    await assertSucceeds(uploadBytes(ref(st(A), att(A, 'max.jpg')), bytes(10 * MB), JPEG));
    await assertFails(uploadBytes(ref(st(A), att(A, 'big.jpg')), bytes(10 * MB + 1), JPEG));
    await assertFails(uploadBytes(ref(st(A), att(A, 'empty.jpg')), bytes(0), JPEG));
  });
  test('avatars: 5 MB allowed, 5 MB + 1 byte denied', async () => {
    await assertSucceeds(uploadBytes(ref(st(A), avatar(A, '5.jpg')), bytes(5 * MB), JPEG));
    await assertFails(uploadBytes(ref(st(A), avatar(A, '6.jpg')), bytes(5 * MB + 1), JPEG));
  });
});

describe('objects are immutable for the owner too', () => {
  test('overwrite and metadata update are denied', async () => {
    await assertFails(uploadBytes(ref(st(A), att(A)), jpg, JPEG));
    await assertFails(updateMetadata(ref(st(A), att(A)), { contentType: 'image/png' }));
    await assertFails(uploadBytes(ref(st(A), avatar(A)), jpg, JPEG));
  });
});

describe('path and name validation', () => {
  test('legacy flat avatar path is denied, even with the caller\'s own uid', async () => {
    await assertFails(uploadBytes(ref(st(A), `doctor_profiles/${A}_123.jpg`), jpg, JPEG));
    await assertFails(uploadBytes(ref(st(A), `doctor_profiles/${B}_123.jpg`), jpg, JPEG));
  });
  test('unexpected file names are denied', async () => {
    await assertFails(uploadBytes(ref(st(A), att(A, 'script.sh')), jpg, JPEG));
    await assertFails(uploadBytes(ref(st(A), att(A, 'x.jpg.exe')), jpg, JPEG));
    await assertFails(uploadBytes(ref(st(A), avatar(A, 'no_extension')), jpg, JPEG));
  });
  test('deeper or shallower attachment paths are denied', async () => {
    await assertFails(uploadBytes(ref(st(A), `clinical_attachments/${A}/x.jpg`), jpg, JPEG));
    await assertFails(uploadBytes(ref(st(A), `clinical_attachments/${A}/p1/sub/x.jpg`), jpg, JPEG));
  });
  test('owner listing is not needed by the app and is denied', async () => {
    await assertFails(listAll(ref(st(A), `clinical_attachments/${A}/p1`)));
  });
  test('unknown paths are denied (default deny)', async () => {
    await assertFails(uploadBytes(ref(st(A), `exports/${A}/x.jpg`), jpg, JPEG));
    await assertFails(getBytes(ref(st(A), 'x.jpg')));
  });
});

describe('approval gate (cross-service read of approvedDoctors/{uid})', () => {
  for (const [who, uid] of [
    ['unapproved (verified, no allowlist entry)', UNAPPROVED],
    ['unverified (allowlisted, email_verified false)', UNVERIFIED],
  ]) {
    test(`${who}: denied on own attachments and avatar`, async () => {
      await assertFails(getBytes(ref(st(uid), att(uid))));
      await assertFails(uploadBytes(ref(st(uid), att(uid, 'n.jpg')), jpg, JPEG));
      await assertFails(deleteObject(ref(st(uid), att(uid))));
      await assertFails(getBytes(ref(st(uid), avatar(uid))));
      await assertFails(uploadBytes(ref(st(uid), avatar(uid, '1.jpg')), jpg, JPEG));
    });
  }

  test('approval revoked: access stops immediately', async () => {
    await assertSucceeds(getBytes(ref(st(A), att(A))));
    await env.withSecurityRulesDisabled(async (ctx) => {
      const { deleteDoc } = await import('firebase/firestore');
      await deleteDoc(doc(ctx.firestore(), `approvedDoctors/${A}`));
    });
    await assertFails(getBytes(ref(st(A), att(A))));
    await assertFails(uploadBytes(ref(st(A), att(A, 'z.jpg')), jpg, JPEG));
  });
});
