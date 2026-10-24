#!/usr/bin/env python3
"""Asset, font and dependency rules for CI (no Flutter or Gradle needed).

Rules (limits in tool/ci/budgets.json "assets" / "packages"):
- Every asset and font declared in pubspec.yaml exists.
- Size limits per raster image, font, animation and other file; total bundle budget.
- Raster image pixel limit (PNG, JPEG, WebP, GIF headers).
- Fonts are .ttf/.otf, at most N files, and each font folder carries its licence
  per family: a generic OFL.txt / LICENSE* / COPYING* in the folder, or a
  family-prefixed one such as NotoSansDevanagari-OFL.txt.
- Banned packages (runtime font download, runtime .env, embedded secrets), as
  direct dependencies or pulled in indirectly (pubspec.lock).
- With --base REF (pull requests): new/removed direct dependencies and new locked
  packages are listed for sign-off, and newly added hard-coded remote image/font
  URLs in lib/ fail the check (bundle the file instead). Existing ones on the base
  are only reported.

Standard library + PyYAML when available, otherwise `yq -o=json` (preinstalled on
GitHub's Ubuntu runners). Writes Markdown to --summary (default $GITHUB_STEP_SUMMARY).
"""
import argparse
import json
import os
import re
import struct
import subprocess
import sys

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
FONT_EXT = {".ttf", ".otf"}
ANIM_EXT = {".json", ".riv", ".lottie"}
LICENSE_RE = re.compile(r"(ofl|licen[cs]e|copying)", re.I)
REMOTE_ASSET_RES = [
    re.compile(r"(Image\.network|NetworkImage)\(\s*['\"]https?://"),
    re.compile(r"fonts\.(googleapis|gstatic)\.com"),
    re.compile(r"\bGoogleFonts\."),  # runtime font download (google_fonts)
    re.compile(r"['\"]https?://[^'\"\s]+\.(png|jpe?g|webp|gif|svg|ttf|otf|woff2?|riv|lottie)(\?[^'\"]*)?['\"]", re.I),
]


def load_yaml_text(text):
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text) or {}
    except ImportError:
        out = subprocess.run(["yq", "-o=json", "."], input=text, capture_output=True,
                             text=True, check=True).stdout
        return json.loads(out or "{}") or {}


def git(*args, check=True):
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check).stdout


def font_family_prefix(path):
    """'Figtree' for Figtree-SemiBold.ttf, 'NotoSansDevanagari' for NotoSansDevanagari-Regular.ttf."""
    stem = os.path.splitext(os.path.basename(path))[0]
    return re.split(r"[-_\[]", stem, maxsplit=1)[0]


def font_has_licence(path):
    """A generic licence file (OFL.txt, LICENSE*, COPYING*) in the font's folder
    covers every font there; a prefixed one (NotoSansDevanagari-OFL.txt) covers
    only fonts whose file name starts with that prefix."""
    d = os.path.dirname(path) or "."
    fam = font_family_prefix(path).lower()
    for n in os.listdir(d):
        low = n.lower()
        if low.endswith(tuple(FONT_EXT)) or not LICENSE_RE.search(n):
            continue
        if re.match(r"^(ofl|licen[cs]e|copying)", low) or low.startswith(fam):
            return True
    return False


def image_px(path):
    with open(path, "rb") as f:
        head = f.read(64 * 1024)
    try:
        if head[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", head[16:24])
        if head[:6] in (b"GIF87a", b"GIF89a"):
            return struct.unpack("<HH", head[6:10])
        if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
            chunk = head[12:16]
            if chunk == b"VP8X":
                w = int.from_bytes(head[24:27], "little") + 1
                h = int.from_bytes(head[27:30], "little") + 1
                return w, h
            if chunk == b"VP8L":
                b = int.from_bytes(head[21:25], "little")
                return (b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1
            if chunk == b"VP8 ":
                w, h = struct.unpack("<HH", head[26:30])
                return w & 0x3FFF, h & 0x3FFF
        if head[:2] == b"\xff\xd8":
            i = 2
            while i + 9 < len(head):
                if head[i] != 0xFF:
                    i += 1
                    continue
                marker = head[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h, w = struct.unpack(">HH", head[i + 5:i + 9])
                    return w, h
                seg = struct.unpack(">H", head[i + 2:i + 4])[0]
                i += 2 + seg
    except struct.error:
        return None
    return None


def declared_assets(flutter):
    """Files Flutter bundles for `flutter: assets:` (dir entries: direct files and
    resolution-variant subfolders like 2.0x/), plus `fonts:`."""
    files, missing, fonts = [], [], []
    for entry in flutter.get("assets") or []:
        path = entry.get("path") if isinstance(entry, dict) else entry
        if not path:
            continue
        if path.endswith("/"):
            if not os.path.isdir(path):
                missing.append(path)
                continue
            for name in sorted(os.listdir(path)):
                p = os.path.join(path, name)
                if os.path.isfile(p):
                    files.append(p)
                elif re.match(r"^\d+(\.\d+)?x$", name):
                    files += [os.path.join(p, n) for n in sorted(os.listdir(p))
                              if os.path.isfile(os.path.join(p, n))]
        elif os.path.isfile(path):
            files.append(path)
        else:
            missing.append(path)
    for fam in flutter.get("fonts") or []:
        for f in fam.get("fonts") or []:
            p = f.get("asset")
            if not p:
                continue
            if os.path.isfile(p):
                fonts.append(p)
            else:
                missing.append(p)
    # A font may also be listed under assets (e.g. for the PDF renderer).
    allf = list(dict.fromkeys(files + fonts))
    return allf, missing


def deps(pubspec):
    out = {}
    for sec in ("dependencies", "dev_dependencies", "dependency_overrides"):
        for k in (pubspec.get(sec) or {}):
            out[k] = sec
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budgets", default="tool/ci/budgets.json")
    ap.add_argument("--base", help="git ref to compare against (pull requests)")
    ap.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    a = ap.parse_args()
    B = json.load(open(a.budgets))
    L = B["assets"]
    errors, warnings, info = [], [], []

    pubspec = load_yaml_text(open("pubspec.yaml").read())
    flutter = pubspec.get("flutter") or {}
    files, missing = declared_assets(flutter)
    for m in missing:
        errors.append(f"Declared in pubspec.yaml but missing: {m}")

    rows, total, fonts_total, font_files = [], 0, 0, []
    for p in files:
        size = os.path.getsize(p)
        total += size
        ext = os.path.splitext(p)[1].lower()
        k = size / 1024
        px = None
        if ext in IMAGE_EXT:
            kind = "image"
            px = image_px(p)
            if k > L["max_image_kib"]:
                errors.append(f"{p}: {k:.0f} KiB image is over {L['max_image_kib']} KiB (compress, use WebP, or resize)")
            elif k > L["warn_image_kib"]:
                warnings.append(f"{p}: {k:.0f} KiB image (over {L['warn_image_kib']} KiB; check compression)")
            if px is None:
                warnings.append(f"{p}: could not read image dimensions")
            elif max(px) > L["max_image_px"]:
                errors.append(f"{p}: {px[0]}x{px[1]} px is over {L['max_image_px']} px on a side")
            elif max(px) > L["warn_image_px"]:
                warnings.append(f"{p}: {px[0]}x{px[1]} px (over {L['warn_image_px']} px; provide 1x/2x/3x variants sized to the widget)")
        elif ext in FONT_EXT:
            kind = "font"
            fonts_total += size
            font_files.append(p)
            if k > L["max_font_kib"]:
                errors.append(f"{p}: {k:.0f} KiB font is over {L['max_font_kib']} KiB (subset it or use only the weights you need)")
            d = os.path.dirname(p) or "."
            if not font_has_licence(p):
                fam = font_family_prefix(p)
                errors.append(f"{p}: no licence for this font in {d}/ (add OFL.txt / LICENSE.txt, or {fam}-OFL.txt)")
        elif ext in ANIM_EXT:
            kind = "animation/data"
            if k > L["max_animation_kib"]:
                errors.append(f"{p}: {k:.0f} KiB is over {L['max_animation_kib']} KiB")
        elif ext in {".woff", ".woff2"}:
            kind = "font"
            errors.append(f"{p}: Flutter needs .ttf/.otf fonts, not {ext}")
        else:
            kind = "other"
            if k > L["max_other_kib"]:
                errors.append(f"{p}: {k:.0f} KiB is over {L['max_other_kib']} KiB")
        rows.append((p, kind, k, f"{px[0]}x{px[1]}" if px else ""))
    if total / 1024 > L["max_total_kib"]:
        errors.append(f"Bundled assets total {total/1024:.0f} KiB is over {L['max_total_kib']} KiB")
    if fonts_total / 1024 > L["max_fonts_total_kib"]:
        errors.append(f"Fonts total {fonts_total/1024:.0f} KiB is over {L['max_fonts_total_kib']} KiB")
    if len(font_files) > L["max_font_files"]:
        errors.append(f"{len(font_files)} font files bundled, limit {L['max_font_files']} (use fewer weights or a variable font)")

    cur = deps(pubspec)
    try:
        locked = set((load_yaml_text(open("pubspec.lock").read()).get("packages") or {}).keys())
    except OSError:
        locked = set()
    for pkg, why in B["packages"]["banned"].items():
        if pkg in cur:
            errors.append(f"Package `{pkg}` is not allowed: {why}")
        elif pkg in locked:
            errors.append(f"Package `{pkg}` is pulled in indirectly (pubspec.lock) by another dependency and is not allowed: {why}")

    added_deps, removed_deps, new_locked, remote_new = [], [], [], []
    if a.base:
        base_pub = git("show", f"{a.base}:pubspec.yaml", check=False)
        base_deps = deps(load_yaml_text(base_pub)) if base_pub else {}
        added_deps = sorted(set(cur) - set(base_deps))
        removed_deps = sorted(set(base_deps) - set(cur))
        for d in added_deps:
            warnings.append(f"New direct dependency `{d}` ({cur[d]}): needs DevOps + security sign-off on this PR")
        try:
            base_lock = load_yaml_text(git("show", f"{a.base}:pubspec.lock", check=False) or "{}")
            cur_lock = load_yaml_text(open("pubspec.lock").read())
            bp = set((base_lock.get("packages") or {}).keys())
            new_locked = sorted(set((cur_lock.get("packages") or {}).keys()) - bp)
        except (OSError, subprocess.CalledProcessError, ValueError):
            pass
        diff = git("diff", "--unified=0", "--no-color", f"{a.base}...HEAD", "--", "lib")
        fname, lineno = None, 0
        for line in diff.splitlines():
            if line.startswith("+++ "):
                fname = line[6:] if line.startswith("+++ b/") else None
            elif line.startswith("@@"):
                m = re.search(r"\+(\d+)", line)
                lineno = int(m.group(1)) if m else 0
            elif line.startswith("+") and fname and fname.endswith(".dart"):
                if any(r.search(line) for r in REMOTE_ASSET_RES):
                    remote_new.append(f"{fname}:{lineno}")
                lineno += 1
        for loc in remote_new:
            errors.append(f"{loc}: new runtime font download (GoogleFonts.*) or hard-coded remote image/font URL. Bundle the file under assets/ (offline, private, no third-party request)")

    # Existing remote assets in the tree (informational).
    existing = []
    for root, _, names in os.walk("lib"):
        for n in names:
            if not n.endswith(".dart"):
                continue
            p = os.path.join(root, n)
            for i, line in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
                if any(r.search(line) for r in REMOTE_ASSET_RES):
                    existing.append(f"{p}:{i}")
    if existing and not a.base:
        warnings.append("Hard-coded remote image/font URLs in lib/: " + ", ".join(existing[:10]))

    md = ["### Assets, fonts and dependencies", "",
          f"Bundled assets: **{len(rows)} file(s), {total/1024:.0f} KiB** (budget {L['max_total_kib']} KiB); "
          f"fonts {len(font_files)} file(s), {fonts_total/1024:.0f} KiB (budget {L['max_font_files']} files / {L['max_fonts_total_kib']} KiB). "
          "Material Icons are tree-shaken from release builds and not counted here.", ""]
    if rows:
        md += ["| Asset | Kind | KiB | Pixels |", "|---|---|---:|---|"]
        md += [f"| `{p}` | {k} | {s:.0f} | {px} |" for p, k, s, px in rows]
        md.append("")
    if a.base:
        md.append(f"Compared with `{a.base}`: new direct dependencies: {', '.join(f'`{d}`' for d in added_deps) or 'none'}; "
                  f"removed: {', '.join(f'`{d}`' for d in removed_deps) or 'none'}; "
                  f"new locked packages: {len(new_locked)}{(' (' + ', '.join(new_locked[:15]) + (' ...' if len(new_locked) > 15 else '') + ')') if new_locked else ''}.")
        md.append(f"New runtime font downloads / remote image or font URLs in lib/: {len(remote_new)}. In lib/ now (including existing ones): {len(existing)}"
                  + (f" ({', '.join(existing[:5])})" if existing else "") + ".")
        md.append("")
    md += [f"- **ERROR:** {e}" for e in errors]
    md += [f"- Warning: {w}" for w in warnings]
    if not errors:
        md.append("- Result: **OK**")
    text = "\n".join(md) + "\n\n"
    if a.summary:
        with open(a.summary, "a") as f:
            f.write(text)
    print(text)
    for w in warnings:
        print(f"::warning title=Assets and dependencies::{w}")
    for e in errors:
        print(f"::error title=Assets and dependencies::{e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
