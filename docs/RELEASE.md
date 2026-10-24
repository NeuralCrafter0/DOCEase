# Releasing DOCEase (Android)

This is the checklist for shipping a real, patient-facing build of DOCEase. It covers the signing key, the GitHub secrets CI needs, how to cut a `v*` release, what CI checks for you, what must still be checked by hand, and how to roll back.

Never put real passwords, keystores or base64 keystore text in this file, in an issue, in a PR, or in chat. Every value below is a placeholder.

## 1. The upload key (one time)

Google Play uses two keys. **Play App Signing** holds the *app signing key* that users' phones trust. You keep an *upload key*, and CI signs every release with it. If the upload key is ever lost or leaked, the Play Console account owner can ask Google to reset it, but only if the app is enrolled in Play App Signing. Enrol before the first upload.

Create the upload keystore on a trusted computer that is not the shared team machine:

```bash
keytool -genkeypair -v \
  -keystore docease-upload.jks -storetype PKCS12 \
  -alias upload -keyalg RSA -keysize 2048 -validity 10000
```

`keytool` asks for a password and a name. With PKCS12 the key password is the same as the store password.

Write down the certificate fingerprint. CI prints it in every signed run's summary, so you can tell the right key was used:

```bash
keytool -list -v -keystore docease-upload.jks -alias upload | grep 'SHA256:'
```

### Back up the keystore (do this before anything else)

- Keep **two** offline copies, for example an encrypted USB drive in the office and one with the app owner, plus the passwords in the team password manager. Keep the passwords separate from the file.
- Write down who holds each copy, and check once a quarter that a copy still opens (`keytool -list -keystore ...`).
- Never commit it. `.gitignore` already blocks `*.jks`, `*.keystore`, `key.properties` and `.env`, and gitleaks scans every PR. Don't keep it in the repo folder at all.
- If it leaks, stop releasing, tell security, and request an upload-key reset in the Play Console. Then replace the GitHub secrets.

## 2. The four GitHub secrets

Add these in GitHub under **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the keystore file, base64-encoded on one line |
| `ANDROID_KEYSTORE_PASSWORD` | the keystore password |
| `ANDROID_KEY_ALIAS` | `upload` (or the alias you chose) |
| `ANDROID_KEY_PASSWORD` | the key password (same as the store password for PKCS12) |

To encode the keystore without it ending up in your shell history or a stray file, pipe it straight into the GitHub CLI (`gh`):

```bash
base64 -w0 docease-upload.jks | gh secret set ANDROID_KEYSTORE_BASE64 --repo NeuralCrafter0/DOCEase
gh secret set ANDROID_KEYSTORE_PASSWORD --repo NeuralCrafter0/DOCEase   # prompts, input hidden
gh secret set ANDROID_KEY_ALIAS --repo NeuralCrafter0/DOCEase
gh secret set ANDROID_KEY_PASSWORD --repo NeuralCrafter0/DOCEase
```

On macOS use `base64 -i docease-upload.jks` instead of `base64 -w0 docease-upload.jks`.

How CI uses them:

- **When they're used:** only on pushes to `main` and on `v*` tags. They are never exposed to pull requests (including Dependabot PRs), other branches or manual runs.
- **Missing secrets:** CI still builds, but the APK is signed with the debug key and labelled `prod-NOT-release-signed-debug-key`. Don't distribute that.
- **Partial secrets:** CI does not sign if only some of the four are set.
- **Never in logs:** the keystore is written to the runner's temp folder, `android/key.properties` is created only for the build, and both are deleted afterwards even if the job fails. Nothing secret is printed.

## 3. Cutting a release

1. **Bump the version** in `pubspec.yaml` through a normal PR to `main`. For example, `version: 1.0.1+2` gives versionName `1.0.1` and versionCode `2`. The versionCode (the number after `+`) must be higher than every build ever uploaded to Play, including halted ones.
2. **Wait for `main` to be green.** With the secrets set, the `main` run already produces a release-signed APK and AAB.
3. **Tag the exact commit on `main`** that you tested:

   ```bash
   git fetch origin
   git tag -a v1.0.1 -m "DOCEase 1.0.1" <commit-sha-on-main>
   git push origin v1.0.1
   ```

   Tag only commits on `main`, or a rollback branch (section 6). The tag name should match the pubspec versionName.
4. **Check the tag's CI run.** All jobs should pass, and the job summary should show **Production build**, `DOCEASE_DEV_MODE=false`, the upload certificate SHA-256 you wrote down, and a clean dev-marker scan.
5. **Download the artifacts straight away**, and archive them privately (section 5). Tag runs upload:
   - `docease-apk-release-signed` (kept 7 days)
   - `docease-aab-release-signed` (14 days)
   - `docease-debug-symbols-release-signed` (14 days: Dart split debug info and the R8 `mapping.txt`)

   The repo is public, so any signed-in GitHub user can download these artifacts. After archiving them, delete them from the run (Actions → run → Artifacts → delete).
6. **Upload the AAB to Play.** Go internal testing → closed testing → production with a **staged rollout** (start small, for example 5–10%). Upload `mapping.txt` and the debug symbols as deobfuscation files for that version so crash reports are readable.

## 4. What CI checks on a release

| Check | Fails the release when |
|---|---|
| Secret scan (gitleaks) | a credential is committed |
| `flutter analyze`, `flutter test` (dev mode off and on) | code or tests are broken |
| Release guard | a signed or `v*` tag build would use dev mode, or a dev build would be release-signed |
| Build | the build is not `--release --obfuscate --split-debug-info` with `DOCEASE_DEV_MODE=false` (`--flavor prod` once flavors exist) |
| Signature check | a "signed" build carries the debug certificate, or a dev build carries a release certificate |
| Dev-marker scan (`tool/ci/check_release_markers.sh`) | the text `DEV MODE: test data only` is still inside `libapp.so` of the APK or AAB |
| Real SQLCipher DB tests, Android emulator integration tests | the encrypted database layer misbehaves (when those tests exist on the ref) |
| Firebase rules (emulator tests) | the rules tests fail (when `firebase/` exists; emulator only, never the live project) |

CI cannot check real hardware, real biometrics or iOS. That's what the next list is for.

## 5. Pre-release checklist (by hand, every release)

- [ ] **BLOCKER:** No production release until PR #2's rules are finished (validMedicineItems and the metadata check), deployed, and backend has signed off.
- [ ] **Real Android phone:** install the release-signed APK from the tag run (not a DEV build). Create a patient, force-stop the app and reopen it, and the data must still be there. On a second phone or a fresh install, confirm the database file can't be read without the app (encryption on).
- [ ] **Biometrics:** the lock asks for fingerprint or face on launch and on return from the background. Cancel and fail both keep the data hidden. It behaves sensibly with no biometrics enrolled.
- [ ] **iOS app-switcher cover:** on a real iPhone, open a patient, go to the app switcher, and the preview must be covered (no patient data visible). CI is Android-only, so this is always manual.
- [ ] **Dev mode off:** no DEV MODE banner, the login and lock screens appear, and the app ID is `com.medhistory.app.medhistory` (not `.dev`). The tag summary shows `DOCEASE_DEV_MODE=false`.
- [ ] **Marker scan clean:** the tag run's summary shows "Dev-marker scan (REL-07): clean". You can re-run it locally: `bash tool/ci/check_release_markers.sh app-release.apk app-release.aab`
- [ ] **Firebase still parked:** confirm with the backend engineer before every release. A production build (`DOCEASE_DEV_MODE=false`) turns Firebase, login and the lock back on against the live project `med-history-299a1`. Don't ship to patients until the team has decided Firebase is ready for deployment (rules deployed and tested).
- [ ] **Version:** the versionCode is higher than anything on Play, and the tag matches the pubspec versionName.
- [ ] **Archive** for this tag, in private team storage (never the public repo or a public GitHub release): the signed AAB and APK, `mapping.txt`, the `debug-info/` folder, the CI run URL, the commit SHA and the signer SHA-256.

## 6. Rollback plan

1. **Halt the staged rollout** in Play Console → Release → Production → *Halt rollout*. New users stop getting the bad version, but people who already updated keep it.
2. **Re-release the previous good code with a higher versionCode.** Play never lets you go back to a lower versionCode. Build the last good tag's code again with a bigger number:

   ```bash
   git fetch origin --tags
   git checkout -b release/rollback-1.0.2 v1.0.0     # last good tag
   # edit pubspec.yaml: version: 1.0.2+4   (versionCode above the bad build's)
   git commit -am "release: re-release 1.0.0 code as 1.0.2+4"
   git push origin release/rollback-1.0.2
   git tag -a v1.0.2 -m "DOCEase 1.0.2 (rollback to 1.0.0 code)"
   git push origin v1.0.2
   ```

   The `v1.0.2` tag run release-signs it with all the usual checks. Upload that AAB as a new release and roll it out.
3. **Database caution:** if the bad version changed the local database schema or the encryption key handling, an older app may not open the newer database. Check with the DB engineer before re-releasing old code. You may need a forward fix instead of a rollback.
4. **Why we archive every tag:** crash reports from the bad version can only be decoded with that tag's `mapping.txt` and `debug-info/`. A re-release can only be compared against what was shipped if the exact signed artifacts are kept. GitHub deletes run artifacts after 7–14 days, so the private archive from section 5 is the only lasting copy.
