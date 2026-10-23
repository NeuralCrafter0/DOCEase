#!/usr/bin/env bash
# Release dev-marker scan (QA check REL-07).
#
# Fails if a production build still contains dev-mode code: the dev banner
# string literal must not be compiled into libapp.so of a release APK/AAB.
# Obfuscation does not hide string literals, so the literal is a reliable marker.
# Same marker and method as QA's verify_release_build.sh draft (BANNER_MARKER,
# `strings` over libapp.so, fixed-string match), extended to every ABI, to
# UTF-16LE/BE text and to AABs (base/lib/<abi>/libapp.so).
#
# Usage: tool/ci/check_release_markers.sh <app.apk|app.aab> [more files...]
# Exit:  0 clean, 1 marker found, 2 usage error / file or libapp.so missing.
# Run it on release builds only; DEV (--profile, DOCEASE_DEV_MODE=true) builds
# contain the marker on purpose.
set -euo pipefail

# Keep in sync with kDevModeBannerText in lib/config/dev_mode.dart and QA's BANNER_MARKER.
MARKERS=("DEV MODE: test data only")

usage() { echo "usage: $0 <app.apk|app.aab> [more files...]" >&2; exit 2; }
[ "$#" -ge 1 ] || usage
for tool in unzip strings grep; do
  command -v "$tool" >/dev/null 2>&1 || { echo "check_release_markers: $tool not found" >&2; exit 2; }
done

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

found=0
n=0
for archive in "$@"; do
  if [ ! -f "$archive" ]; then
    echo "::error title=Dev-marker scan::$archive not found"
    exit 2
  fi
  libs="$(unzip -Z1 "$archive" | grep -E '(^|/)lib/[^/]+/libapp\.so$' || true)"
  if [ -z "$libs" ]; then
    echo "::error title=Dev-marker scan::no lib/<abi>/libapp.so in $archive (not an AOT release build?)"
    exit 2
  fi
  while IFS= read -r lib; do
    n=$((n + 1))
    dir="$tmp/$n"
    mkdir -p "$dir"
    unzip -q -o "$archive" "$lib" -d "$dir"
    so="$dir/$lib"
    # S = 8-bit (ASCII/Latin-1/UTF-8), l = UTF-16LE, b = UTF-16BE.
    # strings output goes to a file first: `strings | grep -q` under pipefail
    # can report "not found" when grep exits early and strings gets SIGPIPE.
    for enc in S l b; do
      strings -a -n 8 -e "$enc" "$so" > "$dir/strings.$enc"
      for marker in "${MARKERS[@]}"; do
        if grep -qF -- "$marker" "$dir/strings.$enc"; then
          case "$enc" in S) what="8-bit text" ;; l) what="UTF-16LE" ;; b) what="UTF-16BE" ;; esac
          echo "::error title=Dev-marker scan (REL-07)::\"$marker\" found in $(basename "$archive"):$lib ($what). This release build still contains dev-mode code; gate the dev branch on kDevMode so the AOT compiler strips it."
          found=1
        fi
      done
    done
    echo "scanned $(basename "$archive"):$lib"
  done <<< "$libs"
done

if [ "$found" -ne 0 ]; then
  echo "check_release_markers: FAILED (dev-only marker present)"
  exit 1
fi
echo "check_release_markers: clean (no dev-only marker in $n libapp.so file(s))"
