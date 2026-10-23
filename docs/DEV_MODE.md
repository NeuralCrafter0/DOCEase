# Dev mode: the app without Firebase, login or lock

The owner has parked the Firebase work so the team can focus on the app. Dev mode is one
compile-time switch that turns the cloud parts **off without deleting them**.

## Run it

```bash
flutter run --dart-define=DOCEASE_DEV_MODE=true
# build an APK for testers
flutter build apk --dart-define=DOCEASE_DEV_MODE=true
```

In VS Code pick **DOCEase (dev mode)** in Run and Debug (`.vscode/launch.json`).
Android Studio: Run > Edit Configurations > Additional run args: `--dart-define=DOCEASE_DEV_MODE=true`.

Without the define (or with `=false`) you get the real app: login, biometric lock, rules and sync.
**The default is off** (`bool.fromEnvironment('DOCEASE_DEV_MODE', defaultValue: false)`), so a
forgotten flag can never ship a release without login.

## What changes when it is on

| Area | Dev mode | Normal (`false`) |
|---|---|---|
| Startup | No `Firebase.initializeApp`, no `GoogleSignIn` | as before |
| Login screen, biometric lock (`SecurityWrapper`, PR #4) | skipped, straight to home | shown |
| Patients, visits, records, search, insights, PDF letterhead | encrypted DB opened with `openFor('local')` | `openFor(<firebase uid>)` |
| Firestore sync, Storage uploads, cloud fetches | skipped (code kept); rows stay "unsynced" | on |
| Doctor profile | DB setting `doctor_profile` (JSON) | `doctors/{uid}` |
| Doctor photo | file in app support `profile/` | Storage `doctors/{uid}/avatar.jpg` |
| Visit photos | file in app support `attachments/` (PR #8 layout) | uploaded to Storage |
| Frequent medicines | DB setting `frequent_medicines` (JSON list) | `doctors/{uid}/settings/preferences` |
| Sign out | hidden (no account) | shown |
| Banner | red "DEV MODE: test data only" on every screen | none |

Dev data lives in its own encrypted DB (owner `local`), so it never mixes with a real doctor's
data. An old unencrypted DB on the phone is left untouched for the real account.

Photo files are only ever deleted inside the app's own `attachments/` and `profile/` folders
(symlinks out of them are refused): an unsaved copy when its save fails, and the previous doctor
photo when a new one is saved. Deleting a visit or patient does not delete its photos (PR #8
owns that cleanup).

## For code and tests

- `lib/config/dev_mode.dart`: `kDevMode` (the define), `kLocalOwnerId`, and `DevMode`, an
  injectable widget flag (`DevMode.of(context)`). Only `main()` reads `kDevMode` directly.
- Providers take `cloudSync: false`; `SessionController.localOnly(...)` replaces the auth flow;
  `DOCEaseApp(devMode: true)` picks `DevModeHome` and the banner. `lib/dev/dev_mode_app.dart` wires it.
- Tests set the mode explicitly and pass with or without the define:
  `flutter test` and `flutter test --dart-define=DOCEASE_DEV_MODE=true`.
- The profile and medicines use the DB engineer's key-value settings table
  (`LocalDatabase.getSetting`/`putSetting`, PR #10 commit 5a1408e), inside the encrypted DB, so
  the interim JSON-file store was not needed. Each provider reads it through one `_local` getter.

## Before a release (DevOps)

CI release builds must pass `--dart-define=DOCEASE_DEV_MODE=false` and refuse a release built
with it on (for example: fail the job if the release command line contains
`DOCEASE_DEV_MODE=true`, and check the built app does not show the dev banner).
PR builds and tests may pass `=true`.
