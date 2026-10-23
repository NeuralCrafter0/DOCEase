# Backend: session and sync

Session controller, injected providers, per-uid sync, visit rollback and
tombstones. On `app/dev-mode-local` (PR #13) this is stacked on the DB
engineer's `fix/db-fail-closed-encryption` (PR #10) and has to merge after it.
Nothing has been deployed to Firebase. The Firebase security rules and their
emulator tests (`firebase/`) are **not on this branch**: they stay parked in
PR #2 (`backend/rules-and-session`) until the owner resumes cloud work.

## What changed in the app

**Session (`lib/services/session_controller.dart`).** One controller owns
the signed-in session. It listens to `authStateChanges`. On sign-out or a
uid change it cancels sync, clears `PatientProvider`, `DoctorProvider` and
`MedicineProvider`, closes the local DB and drops the Firestore cache, all
before the next account opens. It then checks that the email is verified
and that `approvedDoctors/{uid}` exists. The last good answer is cached per
uid, so an offline start still works. Next it opens that doctor's DB. Only
once the DB reports `DbReady(uid)` for the current uid does it load
patients, the profile and medicines together. Stale DB events for a
previous uid are ignored.

**Legacy unscoped DB.** On the first sign-in after the update, the legacy
DB is claimed silently when every patient id in it exists in that doctor's
Firestore data. Otherwise the controller enters `SessionPhase.legacyDecision`
and exposes `legacyPrompt` (legacy count, matching count, whether the cloud
check failed). The UI answers with `resolveLegacyMerge(merge | keepSeparate)`,
and `keepSeparate` is remembered.

**main.dart.** Only two places changed: the MultiProvider block registers
the controller, and the root `StreamBuilder` now reads the controller's
phase (`ready` shows Home, `signedOut` shows Login, anything else shows
`SessionStatusView`). The lock screen, `_authenticate()` and resume/re-lock
logic are untouched. Unlock still sits above the session.

**Providers.**
- `DoctorProvider`: saves with `set(merge: true)`, forces `id` to the uid,
  never erases the photo with a null, and puts avatars at
  `doctor_profiles/{uid}/{timestamp}.{ext}` with a real content type.
- `MedicineProvider`: the list lives at `doctors/{uid}/settings/medicines`.
  On first load it copies the legacy `frequentMedicines` field over once,
  sanitized. Profile saves no longer wipe it.
- `PatientProvider`:
  - Waits for the session.
  - Stores Storage paths, not tokenized URLs, for new attachments.
  - Never writes local file paths to Firestore.
  - Retries failed uploads and pushes with backoff, on resume and after
    any successful write.
  - Merges the cloud copy without overwriting unsynced local edits.
  - Logs ids and error codes only.
- `FirestoreHelper`: refuses every call once its session uid is no longer
  the signed-in user.
- Every provider, `FirestoreHelper` and `SessionController` takes auth,
  Firestore, Storage, the auth stream and the local DB through its
  constructor, defaulting to the real instances.

**Visit saves roll back when the DB refuses them (QA PP-06/PP-07).**
`addRecord`, `updateRecord` and `deleteRecord` now work on a copy of the
patient. The copy replaces the in-memory patient only after the local write
returns a version. A refused save (`UnsyncedCounterException`, or
`LocalSaveFailedException` when nothing was written) leaves memory
unchanged, notifies listeners and rethrows, so the next save can't write
the refused change. Visit writes run one at a time. `deleteRecord` still
waits for its cloud push (the existing contract), but the queue is released
right after the local write, so an offline push never blocks the next save.

**Patient deletes use tombstones.** `deletePatient` calls only
`markPendingDelete(id)` locally, then deletes in Firestore and calls
`clearPendingDelete(id)` only after Firestore confirms. Unconfirmed deletes
come from `pendingDeletes()` and are retried on startup, on resume, after
any successful write and by the backoff timer, along with the dirty rows.
A tombstoned patient never comes back on merge, because `applyCloudPatient`
skips it. A refused local delete changes nothing and is reported.

## Interface dependencies on the DB branch

| Used here | Status |
|---|---|
| `LocalDatabase.openFor/close/states/state`, `DbOpenState` (incl. uid), `unsyncedCount`, `resetAndResync(acknowledgedUnsynced:)`, `hasLegacyDb`, `claimLegacyDb`, `dirtyPatients`, `markSynced` | in `09a405f` |
| `applyCloudPatient(patient) -> Future<bool>` | agreed, not in `09a405f`; declared in `lib/services/local_database_sync.dart` |
| `markPendingDelete(id)`, `pendingDeletes()`, `clearPendingDelete(id)` | confirmed names, not in `09a405f`; same interim file. **Return types assumed:** `Future<void>`, `Future<List<String>>`, `Future<void>`. `markPendingDelete` throws when refused |
| Legacy patient ids (`LegacyDbInspector.legacyPatientIds()`) | optional; without it the user is always asked before a legacy merge |
| Open-DB uid accessor | uses `DbReady.uid` until a dedicated accessor exists |

When the DB branch adds these to `LocalDatabase`:
1. Delete `lib/services/local_database_sync.dart`.
2. Drop the `is LocalDatabaseSync` checks in `PatientProvider`; each
   fallback path is marked `TODO(db-merge)`.
3. Add `@override` on `MergeDb` in `test/backend/fakes.dart`.

## Screens touched (minimal hunks, coordinated with the frontend branch)

- `add_record_screen.dart`: a refused or rejected save stays on the form
  and says why (naming the rejected file).
- `patient_detail_screen.dart`: attachments render through
  `AttachmentImage`. The fire-and-forget patient and visit deletes now show
  a snackbar if refused, instead of an unhandled async error.
- `doctor_profile_screen.dart`: shows why an avatar was rejected (type or
  size) and saves nothing.

## Tests

- `flutter test test/backend test/data test/models test/providers`: 121 pass
  (80 of them are this branch's own in `test/backend`).
- `test/widget_test.dart` already fails on `main`: it imports
  `package:medhistory`, but the package is `docease`. It's left alone. QA
  found that when it's in the same run it can also crash the test compiler
  on another file, so run the directories above.
- `flutter analyze`: no new issues. Remaining errors and warnings are
  pre-existing (`home_screen.dart` imports a missing
  `patient_detail_screen.dart`, `widget_test.dart`, unused imports).
- Rules: parked in PR #2 (72 of 72 emulator tests passing there).

## Follow-ups (not done here)

- `addPatient` and `updatePatient` still keep a change in memory when the
  DB returns `null` without throwing (only thrown refusals roll back).
- Device run of the DB open-error classification (QA CLS-01..04):
  `sqflite_sqlcipher` on Android reports every open failure as
  `open_failed`.
- Existing tokenized download URLs (avatars, older attachments) still
  bypass Storage rules. Migrating them to Storage paths needs a one-off
  pass.
- Tighten the rules' blank-field allowances once form validation lands.
