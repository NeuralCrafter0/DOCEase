# Dev mode: the app without Firebase, login or lock

The owner has parked the Firebase work so the team can focus on the app. Dev mode is one
compile-time switch that turns the cloud parts **off without deleting them**. It only ever runs
in **debug or profile** builds of the separate **`dev` Android flavor**: never in a release, and
never as the real app.

## Run it

```bash
# On a phone or emulator (debug):
flutter run --flavor dev --dart-define=DOCEASE_DEV_MODE=true
# A tester APK: profile (or debug), never release
flutter build apk --profile --flavor dev --dart-define=DOCEASE_DEV_MODE=true
# -> build/app/outputs/flutter-apk/app-dev-profile.apk  (app "DOCEase DEV", id com.medhistory.app.medhistory.dev)

# The real app (login, biometric lock, Firebase):
flutter run --flavor prod
flutter build apk --release --flavor prod
flutter build appbundle --release --flavor prod
```

In VS Code pick **DOCEase DEV (dev mode)** or **DOCEase DEV (dev mode, profile)** in Run and Debug
(`.vscode/launch.json`). Android Studio: Run > Edit Configurations > Build flavor `dev`,
Additional run args `--dart-define=DOCEASE_DEV_MODE=true`.

## Why it can never ship

| Guard | Where | What happens |
|---|---|---|
| Define defaults off | `lib/config/dev_mode.dart`: `bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false)` | a forgotten flag gives the real app |
| Release gate | `kDevMode = kDevModeRequested && !kReleaseMode` | dev mode is compiled out of release builds |
| Refusal screen | `main()` > `decideStartMode()`: define + release = `StartMode.refused` | the app shows a blocking "Dev build refused" screen and does nothing else: no Firebase, no data, no back button |
| Gradle: no dev release | `android/app/build.gradle.kts` | the `devRelease` variant does not exist (`androidComponents.beforeVariants`), so `--flavor dev --release` fails, and a plain `flutter build apk --release` (no flavor) builds only the prod app. A guard also refuses any `DevRelease` task in the graph, with or without the define, so a dev APK is never release-signed: "Refused: the dev flavor never builds in release mode" |
| Gradle: define only on dev | same, checked on the task graph (`gradle.taskGraph.whenReady`), so it covers `flutter`, `./gradlew assembleDebug`/`build` and IDE runs alike | `DOCEASE_DEV_MODE=true` in any prod app fails, a dev app without the define fails, and a build producing both flavors at once (e.g. `./gradlew assembleDebug`) fails |
| Own app | flavor `dev`: `applicationIdSuffix ".dev"`, label "DOCEase DEV" (`android/app/src/dev/AndroidManifest.xml`) | never installs over, or shares storage with, the real app |

The `prod` flavor is the app as before: same application id `com.medhistory.app.medhistory`, label
"DOCEase", `google-services.json` and Firebase Analytics. The dev flavor skips the
google-services step and removes Firebase's native auto-init, since dev mode never uses Firebase.

There is no `default-flavor` in `pubspec.yaml` on purpose: Flutter applies it to iOS too, and the
iOS project has no matching schemes, so iOS builds would fail. Android commands therefore always
name the flavor (`--flavor prod` or `--flavor dev`).

## What changes when it is on

| Area | Dev mode | Normal |
|---|---|---|
| Startup | No `Firebase.initializeApp`, no `GoogleSignIn` | as before |
| Login screen, biometric lock (`SecurityWrapper`, PR #4) | skipped, straight to home | shown |
| Patients, visits, records, search, insights, PDF letterhead | encrypted DB opened with `openFor('local')` | `openFor(<firebase uid>)` |
| PDF | red "TEST DATA - NOT A MEDICAL RECORD" band at the top and bottom of every page; file name `TEST_DATA_report_<id8>_<yyyymmdd>.pdf` | `report_<id8>_<yyyymmdd>.pdf` (#7's scheme, never the patient's name) |
| Shared visit text | first line `*TEST DATA - NOT A MEDICAL RECORD*` (`markShareText`, `lib/utils/test_data_marker.dart`) | unchanged |
| Firestore sync, Storage uploads, cloud fetches | skipped (code kept); rows stay "unsynced" | on |
| Doctor profile | DB setting `doctor_profile` (JSON) | `doctors/{uid}` |
| Doctor photo | `profile/<owner folder>/` in app support | Storage `doctors/{uid}/avatar.jpg` |
| Visit photos | `attachments/<owner folder>/` in app support | uploaded to Storage |
| Frequent medicines | DB setting `frequent_medicines` (JSON list) | `doctors/{uid}/settings/preferences` |
| Sign out | hidden (no account) | shown |
| Banner | red "DEV MODE: test data only" on every screen | none |

## Keeping dev and real data apart

- Dev data lives in its own encrypted DB (owner `local`). An old unencrypted DB on the phone is
  left untouched for the real account.
- Photos are kept per owner: `attachments/<owner folder>/` and `profile/<owner folder>/`, where the
  owner folder is the same hash the DB file name uses (`docease_<hash>.db`), so the uid is not on
  disk. Photo files are only ever deleted inside the folders of the owner that is asking
  (symlinks are refused): an unsaved copy when its save fails, and the previous doctor photo when
  a new one is saved, and the photos of a deleted patient or visit (below).
- Photo cleanup (security's #8 review; `PatientProvider`, `services/photo_sweep.dart`), for dev
  and real owners alike:
  - After a local delete succeeds (`markPendingDelete` for a patient, the visit save for a
    deleted visit or a photo removed while editing), the provider deletes the dropped photos. A
    refused delete removes nothing. A photo another visit still uses is kept; a file that is
    already gone is ignored, so a second delete is harmless. "Still used" is never taken from the
    in-memory list alone (it was loaded with `fetchPatients()`, which returns `[]` on a read
    error): a fresh `referencedAttachmentKeys()` scan after the DB change must succeed, and a
    still-used local entry that cannot be keyed aborts the cleanup too (left to the sweep; log
    `Photos: cleanup skipped (<reason>)`).
  - Cloud mode (parked, security F8-R1): once a photo's Storage upload is confirmed and the visit
    row has been rewritten to the Storage path, the same provider cleanup deletes the local copy
    (PR #8 writes picks into `attachments/<owner folder>/`). A failed upload, or a rewrite that is
    refused or not confirmed, keeps the file for the retry; a copy another visit or a pending
    upload still uses is kept; files outside the owner folder are never deleted, and the Storage
    path must be in the signed-in owner's folder for that patient. Tests:
    `test/backend/upload_cleanup_test.dart`.
  - At startup (`StartupHooks`, both start modes) a sweep waits for the first open DB and deletes
    files in that owner's `attachments/<owner folder>/` that no row references any more (e.g.
    after a crash between the DB delete and the file delete). Rules: it skips everything unless
    #10's `referencedAttachmentKeys()` returns the full set; it throws `AttachmentScanIncomplete`
    otherwise, and only the reason's name is logged (`noDatabase`, `openFailed`, `unreadableRow`,
    `unreadableAttachmentList`, `unreadableDoctorProfile`, `unrecognisedPath`, `readFailed`).
    Unsynced rows count as referenced; only regular files directly in that folder, never
    symlinks, directories, `profile/` or another owner's folder; files changed in the last 10
    minutes are kept; logs carry counts only. It runs once per start, so a skip is logged once.
  - Deletes (both paths) go through `LocalPhotoStore.deleteOwnedVisitFile`: only names the app
    generates (`<uuid v4>.<jpg|png|webp>`, lower case), only directly in the owner folder, the
    folder must resolve to itself, and the entry is re-checked as a regular file (no-follow) right
    before `File(entry).delete()`. The delete target is always the entry's own path, never a
    resolved one, so a last-moment symlink swap can at worst unlink that link.
  - Both compare #10's owner-relative keys (`AttachmentRefs.attachmentKey`: `attachments/<file>`
    or `profile/<file>`), never raw paths, so `/data/user/0/...` and `/data/data/...` name the
    same photo; the sweep only looks at `attachments/` keys. The owner folder is #10's
    `ownerFolderNameFor` (sha256 hex, first 32; `local` is `25bf8e1a2393f1108d37029b3df55932`).
  - The scan also counts the doctor's photo (`doctor_profile` setting, the same key
    `DoctorProvider` writes). A new avatar is saved in the setting before the old file is deleted,
    so the two never disagree; the sweep never touches `profile/`.
  - Known limitation: a visit that still holds an old image_picker cache path makes the scan fail
    with `unrecognisedPath`, so that phone is never swept (safe; clinical records are not
    migrated). Provider cleanup is skipped there as well (the fresh scan fails the same way). A leftover avatar after a crash is
    not swept either. Tests: `test/backend/photo_cleanup_test.dart`.
- iOS: each owner photo folder is excluded from iCloud and computer backups when it is first used
  in a run, through #10's `PlatformBackupExcluder` (the existing `docease/backup_exclusion`
  channel in `ios/Runner/AppDelegate.swift`, which also covers the encrypted DB; no new native
  code). A failure is logged as a code and retried on the next photo. Android backups are off in
  the main manifest (`allowBackup="false"`), which the dev flavor inherits. Not compiled or run
  on iOS here (no Mac); covered by Dart tests with a fake excluder.
- `local` is a reserved owner. Every cloud path refuses it explicitly, even if cloud sync were
  switched on by mistake: `PatientProvider` (sync, uploads, fetches, retries), `FirestoreHelper`,
  `DoctorProvider`, `MedicineProvider`, `FirebaseSessionPlatform` (approval, cloud ids) and
  `SessionController` (a Firebase account whose uid is `local` ends in a failed state and opens
  nothing). Tests: `test/backend/dev_mode_security_test.dart`.

## For code and tests

- `lib/config/dev_mode.dart`: `kDevModeRequested` (the define), `kDevMode` (define and not
  release), `decideStartMode()`, `kLocalOwnerId`, and `DevMode`, a widget flag that can only turn dev mode off
  (`DevMode.of(context)`). Only `main()` decides the start mode.
- `lib/dev/dev_build_refused.dart`: the refusal screen. `lib/dev/dev_mode_app.dart` wires dev mode.
- Providers take `cloudSync: false`; `SessionController.localOnly(...)` replaces the auth flow;
  `DOCEaseApp(devMode: true)` picks `DevModeHome` and the banner.
- Dev mode can only be turned on by the define. Every injectable entry point is gated on
  `kDevMode` (define on and not release), so nothing can enable it in a build without the
  define (security F4-R3):
  - `DOCEaseApp(devMode: true)`: the effective value is `isDevMode => kDevMode && devMode`.
  - `DevMode(enabled: true)`: `DevMode.of` is `kDevMode && enabled`, so a scope can only turn
    dev mode off.
  - `SessionController.localOnly` and `LocalOnlySessionPlatform` (which approves everyone)
    throw `StateError`.
  - `buildDevModeApp` returns the refusal screen.
  - The TEST DATA markers (PDF band, PDF file-name prefix, share text) apply only when
    `kDevMode && testData`; without the define `testData: true` is ignored.
  - Not gated: the providers' `cloudSync: false`. It only turns cloud work off and never skips
    sign-in, the lock or approval, or changes the owner. Unit-test fakes use it in both modes.
- Dev-only code is compiled out of builds without the define. `kDevMode` and
  `kDevBuildRefused` are compile-time constants, and `main()` uses them directly
  (`if (kDevBuildRefused) { ... }`, `if (kDevMode) { ... }`), as does `DOCEaseApp.build`. The AOT
  compiler then drops `buildDevModeApp`, `DevModeHome`, the banner, `localOnly`, the TEST DATA
  markers and their strings from release builds. Rule for new dev-only code: put it directly
  under `if (kDevMode) {` or after `kDevMode && ` (constant first). A runtime value (a function
  result like `decideStartMode(...)`, a getter, a local variable) keeps the code in the binary.
  `dev_mode_security_test.dart` checks this for the known dev symbols. To check a release APK
  (expect 0 for each):

      unzip -p build/app/outputs/flutter-apk/app-prod-release.apk lib/arm64-v8a/libapp.so \
        | strings | grep -c -e 'DEV MODE' -e buildDevModeApp -e 'TEST DATA'

- Tests: run the suite twice. Both commands pass unchanged (apart from `test/widget_test.dart`,
  below), because tests that
  need one mode skip themselves in the other (`skip: !kDevMode` / `skip: kDevMode` inside the
  test file; no tags):

      flutter test
      flutter test --dart-define=DOCEASE_DEV_MODE=true

  Only with the define (`skip: !kDevMode`): in `test/backend/dev_mode_test.dart`, the `session`
  group (4 tests), `DOCEaseApp(devMode: true) skips lock and login, shows the banner` and
  `session screens offer no Sign out in dev mode`; in `test/backend/current_owner_test.dart`,
  `dev mode (localOnly): owner is "local"`; in `test/backend/dev_mode_security_test.dart`,
  `dev mode PDFs say TEST DATA; real ones do not`.
  Only without the define (`skip: kDevMode`): the `without the define, every dev-mode entry
  point refuses` group in `dev_mode_test.dart` (4 tests: `DOCEaseApp(devMode: true)` is
  ignored; `localOnly`, `LocalOnlySessionPlatform` and `buildDevModeApp` refuse), and
  `without the define testData: true is ignored (marker compiled out)` in
  `dev_mode_security_test.dart`.
  Everything else runs in both. The PDF file-name and share-text marker tests in
  `dev_mode_followups_test.dart` run in both and expect the marker only when `kDevMode`. New dev-mode tests that need it on use `skip: !kDevMode`.
  `test/widget_test.dart` is the broken Flutter template and fails in both modes, on `main`
  too.
- The profile and medicines use the DB engineer's key-value settings table
  (`LocalDatabase.getSetting`/`putSetting`, PR #10), inside the encrypted DB.
- `CurrentOwner.id` (`lib/services/current_owner.dart`): the owner of the open session, or null.
  `SessionController` sets it when a session is ready (`local` in dev mode, the Firebase uid
  otherwise) and clears it before anything closes on sign-out, account switch, failure or
  dispose. For code without a `BuildContext`, e.g. PR #8:
  `AttachmentStorage.currentOwnerId = () => CurrentOwner.id;`.
- `StartupHooks` (`lib/services/startup_hooks.dart`): work that must run after start in both
  modes. Register before the start switch in `main()`, e.g. PR #8:
  `StartupHooks.register('picker_hygiene', PickerHygiene.atStartup);` (replacing its
  `PickerHygiene.atStartup().ignore();` after the normal `runApp`, which dev mode never reaches).
  `main()` runs them after `runApp` on both paths, never on the refusal screen; failures log a
  code only.
- `PatientProvider.addPatient`/`updatePatient` throw `SaveRefusedException` when a save is
  refused, after rolling back the list (a refused add is gone, a refused update shows the old
  version). `.error` is the original error, `.causeCode` is safe to log. A refusal caused by
  `UnsyncedCounterException` or `UnreadablePatientException` is also an instance of that type,
  so existing catches keep working. Screens should `await` the call and catch
  `SaveRefusedException`.

## For DevOps (CI)

- Release jobs: `flutter build apk --release --flavor prod` / `flutter build appbundle --release --flavor prod`.
  Always name one flavor: a plain `./gradlew assembleDebug` or `build` would produce both flavors
  in one build, and the guard refuses that.
  Passing `--dart-define=DOCEASE_DEV_MODE=false` is harmless and still recommended; Gradle already
  fails a release with the define on, and the app would only show the refusal screen.
- Dev/tester jobs: `flutter build apk --profile --flavor dev --dart-define=DOCEASE_DEV_MODE=true`
  (or `--debug`). Artifacts: `app-dev-profile.apk` / `app-dev-debug.apk`.
- Tests: two jobs, `flutter test` and `flutter test --dart-define=DOCEASE_DEV_MODE=true` (see
  "For code and tests"). No tags or excludes are needed; `test/widget_test.dart` fails in both
  until the owner fixes or removes it.

## Later

- iOS: the photo-folder backup exclusion has not been run on a device (no Mac here). Check it
  on the first iOS dev build, e.g. that `attachments/<owner folder>` shows
  `NSURLIsExcludedFromBackupKey` = true.
