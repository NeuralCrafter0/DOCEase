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
| Gradle: no dev release | `android/app/build.gradle.kts` | any `DevRelease` task fails: "Refused: the dev flavor never builds in release mode" |
| Gradle: define only on dev | same | `DOCEASE_DEV_MODE=true` with the prod flavor fails, and the dev flavor without the define fails |
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
| PDF | red "TEST DATA - NOT A MEDICAL RECORD" band at the top and bottom of every page; file name `TEST_DATA_...` | no marker |
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
  a new one is saved. Deleting a visit or patient does not delete its photos (PR #8 owns that).
- `local` is a reserved owner. Every cloud path refuses it explicitly, even if cloud sync were
  switched on by mistake: `PatientProvider` (sync, uploads, fetches, retries), `FirestoreHelper`,
  `DoctorProvider`, `MedicineProvider`, `FirebaseSessionPlatform` (approval, cloud ids) and
  `SessionController` (a Firebase account whose uid is `local` ends in a failed state and opens
  nothing). Tests: `test/backend/dev_mode_security_test.dart`.

## For code and tests

- `lib/config/dev_mode.dart`: `kDevModeRequested` (the define), `kDevMode` (define and not
  release), `decideStartMode()`, `kLocalOwnerId`, and `DevMode`, an injectable widget flag
  (`DevMode.of(context)`). Only `main()` decides the start mode.
- `lib/dev/dev_build_refused.dart`: the refusal screen. `lib/dev/dev_mode_app.dart` wires dev mode.
- Providers take `cloudSync: false`; `SessionController.localOnly(...)` replaces the auth flow;
  `DOCEaseApp(devMode: true)` picks `DevModeHome` and the banner.
- Tests set the mode explicitly and pass with or without the define:
  `flutter test` and `flutter test --dart-define=DOCEASE_DEV_MODE=true`.
- The profile and medicines use the DB engineer's key-value settings table
  (`LocalDatabase.getSetting`/`putSetting`, PR #10), inside the encrypted DB.

## For DevOps (CI)

- Release jobs: `flutter build apk --release --flavor prod` / `flutter build appbundle --release --flavor prod`.
  Passing `--dart-define=DOCEASE_DEV_MODE=false` is harmless and still recommended; Gradle already
  fails a release with the define on, and the app would only show the refusal screen.
- Dev/tester jobs: `flutter build apk --profile --flavor dev --dart-define=DOCEASE_DEV_MODE=true`
  (or `--debug`). Artifacts: `app-dev-profile.apk` / `app-dev-debug.apk`.
- Tests: `flutter test` (optionally also with `--dart-define=DOCEASE_DEV_MODE=true`).

## Later

- iOS: dev photos are kept in Application Support, which iOS backs up to iCloud by default. Before
  dev builds go to iOS testers, mark the photo folders excluded from backup (or keep them in
  Caches). Android excludes nothing yet either; the dev app id keeps it separate from the real app.
