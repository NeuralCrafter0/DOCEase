#!/usr/bin/env bash
# Run every integration_test/**/*_test.dart on a connected Android emulator/device.
#
# Used by the "Android emulator integration tests" CI job (inside
# reactivecircus/android-emulator-runner) and runnable locally against any
# device: INTEGRATION_DEVICE=<id> bash tool/ci/run_integration_tests.sh
#
# Dev mode: tests run with --dart-define=DOCEASE_DEV_MODE=true (Firebase, login
# and the lock skipped) EXCEPT files listed in DEV_MODE_EXEMPT_TESTS, which run
# without the define. The DB engineer's device suite is exempt: its results do
# not depend on dev mode and it must not be forced into it.
#
# Flavors: same auto-detection as the Android build job. With no productFlavors
# (main today) no --flavor is passed. With dev + prod flavors (PR #13) the
# dev-mode group uses --flavor dev and the exempt group --flavor prod, because
# the Gradle guard refuses dev without DOCEASE_DEV_MODE=true and prod with it.
#
# Env: INTEGRATION_DEVICE (default emulator-5554)
#      DEV_MODE_EXEMPT_TESTS (space-separated paths relative to the repo root)
# Exit: 0 all groups passed, 1 a group failed or setup error.
set -euo pipefail

DEVICE="${INTEGRATION_DEVICE:-emulator-5554}"
read -r -a exempt_list <<< "${DEV_MODE_EXEMPT_TESTS:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

mapfile -t all_tests < <(find integration_test -type f -name '*_test.dart' 2>/dev/null | LC_ALL=C sort)
if [ "${#all_tests[@]}" -eq 0 ]; then
  echo "::error title=Integration tests::no *_test.dart files under integration_test/"
  exit 1
fi

is_exempt() {
  local f="$1" e
  for e in "${exempt_list[@]}"; do [ "$f" = "$e" ] && return 0; done
  return 1
}
dev_tests=(); plain_tests=()
for f in "${all_tests[@]}"; do
  if is_exempt "$f"; then plain_tests+=("$f"); else dev_tests+=("$f"); fi
done
for e in "${exempt_list[@]}"; do
  [ -f "$e" ] || echo "::notice title=Integration tests::DEV_MODE_EXEMPT_TESTS entry not on this ref: $e"
done

# Flavor detection (keep in sync with the android-build job in ci.yml).
gradle_files=()
for f in android/app/build.gradle.kts android/app/build.gradle; do
  if [ -f "$f" ]; then gradle_files+=("$f"); fi
done
flavors=false
if [ "${#gradle_files[@]}" -gt 0 ] && grep -qE '^[[:space:]]*productFlavors[[:space:]]*\{' "${gradle_files[@]}"; then
  has_dev=false; has_prod=false
  if grep -qE 'create\("dev"\)|^[[:space:]]*dev[[:space:]]*\{' "${gradle_files[@]}"; then has_dev=true; fi
  if grep -qE 'create\("prod"\)|^[[:space:]]*prod[[:space:]]*\{' "${gradle_files[@]}"; then has_prod=true; fi
  if [ "$has_dev" != "true" ] || [ "$has_prod" != "true" ]; then
    echo "::error title=Flavor detection::productFlavors found in ${gradle_files[*]} but not both 'dev' and 'prod' (dev=$has_dev prod=$has_prod). Update tool/ci/run_integration_tests.sh."
    exit 1
  fi
  flavors=true
fi

echo "Device: $DEVICE | flavors: $flavors"
echo "Dev-mode tests (${#dev_tests[@]}): ${dev_tests[*]:-none}"
echo "Exempt tests, no dev define (${#plain_tests[@]}): ${plain_tests[*]:-none}"

{
  echo "## Android emulator integration tests"
  echo ""
  echo "| Group | Command flags | Files | Result |"
  echo "|---|---|---|---|"
} >> "$summary"

overall=0
run_group() {
  local label="$1"; shift
  local -a flags=("$@")
  local -a files=("${group_files[@]}")
  [ "${#files[@]}" -gt 0 ] || return 0
  echo "::group::$label: flutter test ${files[*]} -d $DEVICE ${flags[*]}"
  local status=0
  flutter test "${files[@]}" -d "$DEVICE" "${flags[@]}" || status=$?
  echo "::endgroup::"
  local result="passed"
  if [ "$status" -ne 0 ]; then result="**FAILED** (exit $status)"; overall=1; fi
  echo "| $label | \`${flags[*]:-none}\` | ${files[*]} | $result |" >> "$summary"
  echo "$label: $result"
}

if [ "$flavors" = "true" ]; then dev_flags=(--flavor dev); plain_flags=(--flavor prod); else dev_flags=(); plain_flags=(); fi
group_files=("${plain_tests[@]}")
run_group "Exempt (dev mode not forced)" "${plain_flags[@]}"
group_files=("${dev_tests[@]}")
run_group "DEV mode" "${dev_flags[@]}" --dart-define=DOCEASE_DEV_MODE=true

exit "$overall"
