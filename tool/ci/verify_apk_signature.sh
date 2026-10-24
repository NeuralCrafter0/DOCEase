#!/usr/bin/env bash
# Signature, package-ID and dev-mode guard for one Android APK. Shared by the
# "Android build" and "Split-per-ABI APK size" jobs in .github/workflows/ci.yml
# so every APK CI builds gets exactly the same checks.
#
# Usage: verify_apk_signature.sh APK OUT_FILE
# Environment:
#   ANDROID_HOME  Android SDK (newest stable build-tools is used)
#   APP_ID        production application ID (com.medhistory.app.medhistory)
#   DEV_MODE      "true" / "false": the DOCEASE_DEV_MODE the APK was built with
#   SIGNED        "true" when release-signing secrets were used, else "false"
#   FLAVOR        "dev", "prod" or empty (no productFlavors on this ref)
#
# Fails (exit 1, ::error annotation) when:
#   - there is not exactly one readable signer certificate;
#   - a production build (DEV_MODE=false) does not have package APP_ID, or a
#     dev-flavor build does not have package APP_ID.dev;
#   - signing secrets were used but the APK is signed with the debug key;
#   - the APK carries a non-debug (release) certificate but DEV_MODE != false.
# On success writes public certificate details only (no secrets) to OUT_FILE
# as key=value lines: bt, cert_dn, cert_sha256, pkg, debug_cert, apk_sha256.
set -euo pipefail

apk="${1:?usage: verify_apk_signature.sh APK OUT_FILE}"
out="${2:?usage: verify_apk_signature.sh APK OUT_FILE}"
: "${ANDROID_HOME:?}" "${APP_ID:?}" "${DEV_MODE:?}" "${SIGNED:?}"
FLAVOR="${FLAVOR:-}"
test -f "$apk"

# Newest stable build-tools (skip -rc). apksigner output differs by version
# ("Signer #1 certificate DN:" in 36, "V2 Signer: certificate DN:" in 37),
# so match on the field name only.
bt="$(find "$ANDROID_HOME/build-tools" -mindepth 1 -maxdepth 1 -type d | grep -vE -- '-rc[0-9]*$' | sort -V | tail -1)"
certs="$("$bt/apksigner" verify --print-certs "$apk")"
dns="$(printf '%s\n' "$certs" | sed -n 's/^.*certificate DN: //p' | sort -u)"
shas="$(printf '%s\n' "$certs" | sed -n 's/^.*certificate SHA-256 digest: //p' | sort -u)"
# Fail closed: exactly one readable signer certificate is required.
if [ -z "$dns" ] || [ -z "$shas" ] || [ "$(printf '%s\n' "$shas" | wc -l)" -ne 1 ]; then
  echo "::error title=Signature check::Could not read exactly one signer certificate from $apk with $(basename "$bt") apksigner."
  exit 1
fi
cert_dn="$(printf '%s\n' "$dns" | head -1)"
cert_sha256="$shas"
echo "APK signer (apksigner $(basename "$bt")): $cert_dn, SHA-256 $cert_sha256"

# Package ID: production builds must be exactly APP_ID; dev-flavor builds APP_ID.dev.
pkg="$("$bt/aapt2" dump packagename "$apk")"
echo "APK package: $pkg (flavor ${FLAVOR:-none})"
if [ "$DEV_MODE" = "false" ] && [ "$pkg" != "$APP_ID" ]; then
  echo "::error title=Release guard::Production build has package '$pkg', expected '$APP_ID'."
  exit 1
fi
if [ "$FLAVOR" = "dev" ] && [ "$pkg" != "$APP_ID.dev" ]; then
  echo "::error title=Release guard::Dev-flavor build has package '$pkg', expected '$APP_ID.dev'."
  exit 1
fi

debug_cert=false
if printf '%s' "$cert_dn" | grep -q 'CN=Android Debug'; then debug_cert=true; fi
# Never label a debug-key APK as release-signed.
if [ "$SIGNED" = "true" ] && [ "$debug_cert" = "true" ]; then
  echo "::error title=Release signing failed::Signing secrets were provided but the APK is signed with the debug key."
  exit 1
fi
# A non-debug (release) certificate on a dev-mode build is never allowed.
if [ "$debug_cert" = "false" ] && [ "$DEV_MODE" != "false" ]; then
  echo "::error title=Release guard::The APK carries a release certificate but was built with DOCEASE_DEV_MODE=$DEV_MODE."
  exit 1
fi

apk_sha256="$(sha256sum "$apk" | cut -d' ' -f1)"
{
  echo "bt=$bt"
  echo "cert_dn=$cert_dn"
  echo "cert_sha256=$cert_sha256"
  echo "pkg=$pkg"
  echo "debug_cert=$debug_cert"
  echo "apk_sha256=$apk_sha256"
} > "$out"
