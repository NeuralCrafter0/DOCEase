# DOCEase Firebase rules

Security rules for Firestore and Cloud Storage, plus emulator tests. This
folder is separate from the Flutter app, so `pubspec.yaml` and
`pubspec.lock` are untouched.

**Nothing here has been deployed.** The project owner has not approved a
deploy to the live project `med-history-299a1`. The tests run only against
the local emulators under the fake project id `demo-docease`, which can't
reach any real project.

## Run the tests

You need Node 20 or newer and Java 11 or newer (the emulators need Java).

```bash
cd firebase
npm ci
npm test   # starts the Firestore and Storage emulators, runs test/*.test.js, stops them
```

If the emulators are already running (`npx firebase emulators:start --only
firestore,storage --project demo-docease`), use `npm run test:run`.

Current result: 72 tests in 18 suites, all passing.

## What the rules enforce

| Path | Who | Writes |
|---|---|---|
| `doctors/{uid}` (profile) | owner only, `get` only (no listing) | allowed keys only, `id == uid`, bounded strings, `profileImageUrl` must be a Firebase Storage URL; no delete |
| `doctors/{uid}/patients/{patientId}` | owner only; `list` only inside the owner's own subcollection | required keys and types, `id == patientId`, `history` is a list of at most 1,000 entries, any ownership field must equal `uid` |
| `doctors/{uid}/settings/medicines` | owner only | only `{items: [...]}`, at most 2,000 strings of 1-200 characters, no line breaks; no delete |
| `approvedDoctors/{uid}` | owner may `get` their own entry | none (Admin SDK / console only) |
| Storage `clinical_attachments/{uid}/{patientId}/{file}` | owner only | JPEG/PNG/WebP, 1 byte to 10 MiB, plain file name, no overwrite |
| Storage `doctor_profiles/{uid}/{file}` | owner only | JPEG/PNG/WebP, 1 byte to 5 MiB, plain file name, no overwrite |
| Anything else | nobody | denied |

Every `doctors/**` path and every Storage path also requires
`email_verified == true` in the ID token and an `approvedDoctors/{uid}`
document (the security review's approval gate).

## Before anyone deploys (owner's call)

1. **Create `approvedDoctors/{uid}` for every existing doctor first.**
   Otherwise every current user is locked out the moment the rules go
   live. Doctors who signed up with email and password also need a verified
   email (Google sign-in accounts are already verified).
2. **Grant Storage access to Firestore.** `storage.rules` uses
   `firestore.exists()`. On the first deploy the console asks to grant the
   Storage service agent access to Firestore. Without that grant, every
   Storage request is denied.
3. **Ship the app update with or before the rules.** Older builds upload
   avatars to the old flat path `doctor_profiles/{uid}_{timestamp}.jpg`,
   which the new rules deny, and they keep the medicines list on the
   profile document (still accepted during the migration window).
4. Deploy with `firebase deploy --only firestore:rules,storage` from this
   folder, against the real project id, once the owner approves.

## Known gaps

- Tokenized download URLs (`...?alt=media&token=...`) bypass Storage rules
  completely. New uploads store Storage paths instead, but avatars and
  older attachments still use such URLs. Revoking a token means
  regenerating it in the console.
- Rules can't loop, so individual visits inside `history` aren't
  validated, only the array's type and length (Firestore caps a document
  at 1 MiB).
- Blank names, ages and phone numbers are allowed because today's forms
  allow them (QA UI-01/UI-02). Tighten the minimum lengths once form
  validation lands.
- The legacy `frequentMedicines` field on the profile is still writable,
  so older builds can keep saving. Remove it from `validDoctor` once every
  client is updated.
