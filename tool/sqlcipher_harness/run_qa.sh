#!/usr/bin/env bash
# Runs the real-SQLCipher DatabaseHelper suite
# (integration_test/support/db_suite.dart) on the host, against the system
# libsqlcipher through sqflite_common_ffi.
#
# The repo is copied to a temp dir and the FFI dev dependency plus the
# sqlite3 "system sqlcipher" hook config are added to the COPY only; the
# real pubspec.yaml / pubspec.lock are never modified (checked at the end).
#
# QA variant of run.sh: runs integration_test/support/qa_db_open_suite.dart
# (QA KCV/SET cases) the same way. run.sh itself is untouched.
# Usage (from anywhere):  bash tool/sqlcipher_harness/run_qa.sh [flutter test args]
# Env:
#   QA_FFI_TEST    QA host test file in this folder (default qa_sqlcipher_ffi_test.dart)
#   FLUTTER        flutter executable (default: flutter on PATH)
#   KEEP_WORKDIR=1 keep the temp copy for debugging
# Exit code: non-zero if any test fails or a precondition is not met.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
FLUTTER="${FLUTTER:-flutter}"

# Pinned so CI runs are reproducible; added to the temp copy only.
FFI_PACKAGES=("sqflite_common_ffi:2.4.0+3" "sqlite3:3.1.7")

die() { echo "sqlcipher_harness: $*" >&2; exit 2; }

command -v "$FLUTTER" >/dev/null 2>&1 ||
  die "flutter not found (put it on PATH or set FLUTTER=/path/to/flutter)"
[ -f "$REPO_ROOT/pubspec.yaml" ] || die "repo root not found at $REPO_ROOT"
[ -f "$REPO_ROOT/integration_test/support/db_suite.dart" ] ||
  die "integration_test/support/db_suite.dart is missing"
if ! ldconfig -p 2>/dev/null | grep -qE 'libsqlcipher\.so( |$)'; then
  [ -e /usr/lib/x86_64-linux-gnu/libsqlcipher.so ] || [ -e /usr/lib/libsqlcipher.so ] ||
    die "libsqlcipher.so not found; install it: sudo apt-get install -y libsqlcipher-dev"
fi
if grep -qE '^hooks:' "$REPO_ROOT/pubspec.yaml"; then
  die "pubspec.yaml already has a hooks: section; merge the sqlite3 user_defines by hand"
fi

checksum() { sha256sum "$REPO_ROOT/pubspec.yaml" "$REPO_ROOT/pubspec.lock" 2>/dev/null; }
BEFORE="$(checksum)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/docease_sqlcipher.XXXXXX")"
cleanup() {
  if [ "${KEEP_WORKDIR:-0}" = "1" ]; then
    echo "sqlcipher_harness: kept $WORK"
  else
    rm -rf -- "$WORK"
  fi
}
trap cleanup EXIT

echo "sqlcipher_harness: repo $REPO_ROOT -> copy $WORK"
(cd "$REPO_ROOT" && tar \
  --exclude=./.git --exclude=./.dart_tool --exclude=./build \
  --exclude=./ios/Pods --exclude=./android/.gradle \
  -cf - .) | (cd "$WORK" && tar -xf -)

cd "$WORK"
cat >> pubspec.yaml <<'YAML'

# Added by tool/sqlcipher_harness/run.sh in a temp copy only.
hooks:
  user_defines:
    sqlite3:
      source: system
      name: sqlcipher
YAML
"$FLUTTER" --version
"$FLUTTER" pub add --dev "${FFI_PACKAGES[@]}"
cp "$HARNESS_DIR/sqlcipher_ffi_test.dart" test/sqlcipher_ffi_test.dart
cp "$HARNESS_DIR/qa_sqlcipher_ffi_test.dart" test/qa_sqlcipher_ffi_test.dart
# QA_FFI_TEST picks the QA host test (default: the KCV/SET suite).
QA_FFI_TEST="${QA_FFI_TEST:-qa_sqlcipher_ffi_test.dart}"
[ -f "$HARNESS_DIR/$QA_FFI_TEST" ] || die "no $HARNESS_DIR/$QA_FFI_TEST"
# Copy every QA harness file (shared helpers such as RecOpener live in them).
for q in "$HARNESS_DIR"/qa_*_test.dart; do cp "$q" "test/$(basename "$q")"; done

status=0
"$FLUTTER" test "test/$QA_FFI_TEST" "$@" || status=$?

cd "$REPO_ROOT"
if [ "$(checksum)" != "$BEFORE" ]; then
  echo "sqlcipher_harness: ERROR: the real pubspec.yaml/pubspec.lock changed" >&2
  [ "$status" -ne 0 ] || status=3
fi
if [ "$status" -ne 0 ]; then
  echo "sqlcipher_harness: FAILED (exit $status)" >&2
else
  echo "sqlcipher_harness: PASSED"
fi
exit "$status"
