# Real-SQLCipher test harness

Runs the `DatabaseHelper` suite against a real SQLCipher library on a Linux host (no emulator, no Gradle). It checks encryption at rest, both recovery migrations, the v1 → v2 upgrade, key-check classification and the settings table.

## What it runs

- Test bodies: `integration_test/support/db_suite.dart`. The device test `integration_test/db_encryption_migration_test.dart` uses the same file.
- Host entry point: `tool/sqlcipher_harness/sqlcipher_ffi_test.dart`. It opens databases through `sqflite_common_ffi` with `PRAGMA key`. Its first test fails if the loaded library is plain SQLite rather than SQLCipher.

`run.sh` copies the repo to a temp dir (`mktemp`). Only in that copy does it add `sqflite_common_ffi 2.4.0+3` and `sqlite3 3.1.7` as dev dependencies, plus the `sqlite3` hook setting `source: system, name: sqlcipher`. The real `pubspec.yaml` and `pubspec.lock` are never modified. The script checks this at the end and fails if they changed. The temp copy is deleted afterwards; set `KEEP_WORKDIR=1` to keep it.

## Prerequisites (Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y libsqlcipher-dev   # provides libsqlcipher.so (pulls in libsqlcipher1)
```

- Flutter 3.41.2 on `PATH`, or set `FLUTTER=/path/to/flutter`.
- Network access to pub.dev, for `flutter pub get` in the copy.
- No Android SDK, emulator or Gradle is needed.

## Run

From the repo root:

```bash
bash tool/sqlcipher_harness/run.sh
```

Extra arguments go to `flutter test`, for example `bash tool/sqlcipher_harness/run.sh --plain-name "SET-"`.

## Expected result

The script ends with `All tests passed!` from `flutter test`, followed by `sqlcipher_harness: PASSED`, and exits with status 0. Any failing test, a missing `libsqlcipher.so`, or a change to the real pubspec gives a non-zero exit code.

The log contains a few expected lines that are not failures: `cipher_version: 4.5.6 community` (the version depends on the package), and `database is locked` / `Secure storage …` messages from tests that provoke those errors on purpose.
