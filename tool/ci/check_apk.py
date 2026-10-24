#!/usr/bin/env python3
"""Inspect a built Android APK for CI: size breakdown, Play readiness, Firebase isolation.

Checks
- Size breakdown (compressed bytes in the APK): libapp.so (Dart code), libflutter.so
  (engine), other native libs, dex, flutter_assets, Android resources, other.
  Compared with tool/ci/budgets.json "apk.<key>" when --budget-key is given.
- 16 KB memory pages (Google Play, apps targeting Android 15+ on 64-bit devices):
  every 64-bit .so (arm64-v8a, x86_64) must have ELF PT_LOAD p_align >= 16384, and
  when stored uncompressed in the APK its data must start on a 16 KB boundary.
- Target / min SDK from `aapt2 dump badging` (Play minimum in budgets.json).
- Firebase isolation for DEV builds: no google-services config (string/google_app_id)
  and no Firebase Analytics / measurement code in the dex.

Standard library only. Writes a Markdown section to --summary (default
$GITHUB_STEP_SUMMARY) and a JSON report to --json-out. Exit 1 when an enforced check
fails; report-only findings are printed as GitHub warnings.
"""
import argparse
import json
import os
import re
import struct
import subprocess
import sys
import zipfile

ABI_64 = ("arm64-v8a", "x86_64")
FIREBASE_DEX_MARKERS = (
    b"Lcom/google/android/gms/measurement/",
    b"Lcom/google/firebase/analytics/",
)


def kib(n):
    return round(n / 1024, 1)


def elf_min_load_align(data):
    """Smallest p_align of PT_LOAD segments, or None if not a readable ELF."""
    if len(data) < 64 or data[:4] != b"\x7fELF":
        return None
    is64 = data[4] == 2
    endian = "<" if data[5] == 1 else ">"
    if is64:
        e_phoff = struct.unpack_from(endian + "Q", data, 32)[0]
        e_phentsize, e_phnum = struct.unpack_from(endian + "HH", data, 54)
    else:
        e_phoff = struct.unpack_from(endian + "I", data, 28)[0]
        e_phentsize, e_phnum = struct.unpack_from(endian + "HH", data, 42)
    aligns = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        if off + e_phentsize > len(data):
            return None
        p_type = struct.unpack_from(endian + "I", data, off)[0]
        if p_type != 1:  # PT_LOAD
            continue
        if is64:
            p_align = struct.unpack_from(endian + "Q", data, off + 48)[0]
        else:
            p_align = struct.unpack_from(endian + "I", data, off + 28)[0]
        aligns.append(p_align)
    return min(aligns) if aligns else None


def zip_data_offset(fh, info):
    fh.seek(info.header_offset)
    hdr = fh.read(30)
    if len(hdr) < 30 or hdr[:4] != b"PK\x03\x04":
        return None
    n, m = struct.unpack_from("<HH", hdr, 26)
    return info.header_offset + 30 + n + m


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", required=True)
    ap.add_argument("--aapt2", required=True)
    ap.add_argument("--budgets", default="tool/ci/budgets.json")
    ap.add_argument("--budget-key", help="key under apk.* in budgets.json (enforces sizes)")
    ap.add_argument("--title", default="APK checks")
    ap.add_argument("--enforce-16kb", action="store_true")
    ap.add_argument("--enforce-target-sdk", action="store_true")
    ap.add_argument("--firebase", choices=("forbid", "warn", "ignore"), default="ignore")
    ap.add_argument("--json-out")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    a = ap.parse_args()

    budgets = json.load(open(a.budgets))
    errors, warnings = [], []

    cat = {k: 0 for k in ("libapp", "libflutter", "native_other", "dex",
                          "flutter_assets", "resources", "other")}
    raw = {k: 0 for k in cat}
    libs = []
    dex_has_firebase = False
    with zipfile.ZipFile(a.apk) as z, open(a.apk, "rb") as fh:
        for info in z.infolist():
            name = info.filename
            m = re.match(r"lib/([^/]+)/([^/]+\.so)$", name)
            if m:
                abi, so = m.groups()
                key = "libapp" if so == "libapp.so" else (
                    "libflutter" if so == "libflutter.so" else "native_other")
                data = z.read(info)
                align = elf_min_load_align(data)
                stored = info.compress_type == zipfile.ZIP_STORED
                off = zip_data_offset(fh, info) if stored else None
                libs.append({"abi": abi, "lib": so, "kib": kib(info.compress_size),
                             "elf_load_align": align, "stored": stored,
                             "zip_offset_16k_aligned": (off % 16384 == 0) if off is not None else None})
            elif re.match(r"classes\d*\.dex$", name):
                key = "dex"
                if not dex_has_firebase:
                    d = z.read(info)
                    dex_has_firebase = any(mk in d for mk in FIREBASE_DEX_MARKERS)
            elif name.startswith("assets/flutter_assets/"):
                key = "flutter_assets"
            elif name.startswith("res/") or name == "resources.arsc":
                key = "resources"
            else:
                key = "other"
            cat[key] += info.compress_size
            raw[key] += info.file_size
    total = os.path.getsize(a.apk)

    # Per-ABI libapp.so (budget uses the largest single ABI copy).
    libapp_by_abi = {l["abi"]: l["kib"] for l in libs if l["lib"] == "libapp.so"}

    # 16 KB pages.
    page = budgets["play"]["page_size_bytes"]
    bad16 = []
    for l in libs:
        if l["abi"] not in ABI_64:
            continue
        reasons = []
        if l["elf_load_align"] is None or l["elf_load_align"] < page:
            reasons.append(f"ELF LOAD align {l['elf_load_align']}")
        if l["stored"] and l["zip_offset_16k_aligned"] is False:
            reasons.append("uncompressed but not 16 KB zip-aligned")
        if reasons:
            bad16.append(f"{l['abi']}/{l['lib']} ({', '.join(reasons)})")
    abis = sorted({l["abi"] for l in libs})
    if bad16:
        msg = "Not 16 KB page compatible: " + "; ".join(bad16)
        (errors if a.enforce_16kb else warnings).append(msg)

    # Badging.
    badging = run([a.aapt2, "dump", "badging", a.apk])
    pkg = re.search(r"package: name='([^']+)'", badging)
    vcode = re.search(r"versionCode='([^']*)'", badging)
    vname = re.search(r"versionName='([^']*)'", badging)
    tsdk = re.search(r"targetSdkVersion:'(\d+)'", badging)
    msdk = re.search(r"(?:minSdkVersion|sdkVersion):'(\d+)'", badging)
    pkg, vcode, vname = (x.group(1) if x else "?" for x in (pkg, vcode, vname))
    target_sdk = int(tsdk.group(1)) if tsdk else None
    min_sdk = int(msdk.group(1)) if msdk else None
    need = budgets["play"]["min_target_sdk"]
    if target_sdk is None or target_sdk < need:
        msg = f"targetSdkVersion {target_sdk} is below Google Play's required {need}"
        (errors if a.enforce_target_sdk else warnings).append(msg)

    # Firebase isolation.
    resources = run([a.aapt2, "dump", "resources", a.apk])
    has_gs_config = bool(re.search(r"string/google_app_id\b", resources))
    firebase_isolated = not has_gs_config and not dex_has_firebase
    if a.firebase != "ignore" and not firebase_isolated:
        found = []
        if has_gs_config:
            found.append("google-services config (google_app_id)")
        if dex_has_firebase:
            found.append("Firebase Analytics/measurement code")
        msg = ("DEV build is NOT Firebase-isolated: contains " + " and ".join(found)
               + ". It can contact the live Firebase project when launched.")
        (errors if a.firebase == "forbid" else warnings).append(msg)

    # Size budgets.
    limits = budgets["apk"].get(a.budget_key, {}) if a.budget_key else {}
    # What an arm64 phone gets from Play's per-ABI split: the APK minus the
    # native libs of other ABIs (some plugins ship prebuilt libs for every ABI
    # even with --target-platform android-arm64, e.g. SQLCipher).
    other_abi_kib = round(sum(l["kib"] for l in libs if l["abi"] != "arm64-v8a"), 1)
    device_arm64_kib = round(kib(total) - other_abi_kib, 1)
    measured = {
        "max_total_kib": kib(total),
        "max_device_arm64_kib": device_arm64_kib,
        "max_libapp_kib": max(libapp_by_abi.values()) if libapp_by_abi else 0,
        "max_flutter_assets_kib": kib(cat["flutter_assets"]),
        "max_dex_kib": kib(cat["dex"]),
    }
    budget_rows = []
    for k, v in measured.items():
        lim = limits.get(k)
        status = "report only" if lim is None else ("OK" if v <= lim else "OVER")
        budget_rows.append((k, v, lim, status))
        if lim is not None and v > lim:
            errors.append(f"{k}: {v} KiB is over the budget of {lim} KiB")

    report = {
        "apk": os.path.basename(a.apk), "package": pkg, "version_code": vcode,
        "version_name": vname, "min_sdk": min_sdk, "target_sdk": target_sdk,
        "abis": abis, "total_kib": kib(total), "device_arm64_kib": device_arm64_kib,
        "other_abi_libs_kib": other_abi_kib,
        "compressed_kib": {k: kib(v) for k, v in cat.items()},
        "uncompressed_kib": {k: kib(v) for k, v in raw.items()},
        "libapp_kib_by_abi": libapp_by_abi, "libs": libs,
        "page_16kb_ok": not bad16, "page_16kb_problems": bad16,
        "firebase_isolated": firebase_isolated, "google_services_config": has_gs_config,
        "firebase_analytics_code": dex_has_firebase,
        "budgets": {k: {"measured": v, "limit": lim, "status": s} for k, v, lim, s in budget_rows},
        "errors": errors, "warnings": warnings,
    }
    if a.json_out:
        with open(a.json_out, "w") as f:
            json.dump(report, f, indent=1)

    lines = [f"### {a.title}", "",
             f"`{report['apk']}`: **{kib(total)} KiB**, package `{pkg}`, versionCode {vcode}, "
             f"minSdk {min_sdk}, targetSdk {target_sdk}, ABIs {', '.join(abis) or 'none'}", "",
             f"Estimated arm64 phone download (APK minus {other_abi_kib} KiB of other-ABI native libs): **{device_arm64_kib} KiB**", "",
             "| Part (compressed in APK) | KiB |", "|---|---:|"]
    labels = {"libapp": "Dart code (libapp.so, all ABIs)", "libflutter": "Flutter engine (libflutter.so)",
              "native_other": "Other native libs (e.g. SQLCipher)", "dex": "Java/Kotlin (dex)",
              "flutter_assets": "flutter_assets (fonts, images, shaders)",
              "resources": "Android resources", "other": "Other (META-INF, etc.)"}
    for k, v in cat.items():
        lines.append(f"| {labels[k]} | {kib(v)} |")
    if a.budget_key:
        lines += ["", f"Budgets (`apk.{a.budget_key}` in tool/ci/budgets.json):", "",
                  "| Budget | Measured KiB | Limit KiB | Status |", "|---|---:|---:|---|"]
        for k, v, lim, s in budget_rows:
            lines.append(f"| {k} | {v} | {'-' if lim is None else lim} | {s} |")
    lines += ["",
              f"- 16 KB page support (64-bit libs): {'OK' if not bad16 else '**NOT OK**: ' + '; '.join(bad16)}",
              f"- Target SDK: {target_sdk} (Play requires >= {need}): {'OK' if target_sdk and target_sdk >= need else '**below requirement**'}",
              f"- Firebase isolated (no google-services config, no Analytics code): {'yes' if firebase_isolated else '**no**'}"]
    for e in errors:
        lines.append(f"- **ERROR:** {e}")
    for w in warnings:
        lines.append(f"- Warning: {w}")
    md = "\n".join(lines) + "\n\n"
    if a.summary:
        with open(a.summary, "a") as f:
            f.write(md)
    print(md)
    for w in warnings:
        print(f"::warning title={a.title}::{w}")
    for e in errors:
        print(f"::error title={a.title}::{e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
