#!/usr/bin/env python3
"""Make a release-semantics copy of the repo for host widget tests.

flutter test always runs with asserts enabled and kDebugMode == true. A
release AOT build drops every assert and has kDebugMode == false,
kReleaseMode == true. This copies the repo (tar, no rsync) and, in lib/:
  * replaces the argument list of every `assert(...)` with `(true)`, so its
    body (including `assert(() { ... }())` closures) never runs, while the
    syntax stays valid everywhere (statements and initializer lists);
  * replaces the identifiers kDebugMode/kProfileMode with false and
    kReleaseMode with true, outside import/export lines and string literals.
Usage: make_release_sim.py <repo> <dest>   (prints a summary)
"""
import os
import re
import subprocess
import sys

CONSTS = {"kDebugMode": "false", "kProfileMode": "false", "kReleaseMode": "true"}


def scan(src):
    """Yield (kind, text) tokens: 'str', 'comment' or 'code'."""
    i, n = 0, len(src)
    buf = []
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            yield "code", "".join(buf); buf = []
            yield "comment", src[i:j]; i = j; continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            yield "code", "".join(buf); buf = []
            yield "comment", src[i:j]; i = j; continue
        raw = c == "r" and i + 1 < n and src[i + 1] in "'\""
        q0 = i + 1 if raw else i
        if src[q0:q0 + 1] in ("'", '"') and (raw or c in "'\""):
            q = src[q0]
            triple = src.startswith(q * 3, q0)
            end = q * 3 if triple else q
            j = q0 + len(end)
            while j < n:
                if not raw and src[j] == "\\":
                    j += 2; continue
                if src.startswith(end, j):
                    j += len(end); break
                if not triple and src[j] == "\n":
                    break
                j += 1
            yield "code", "".join(buf); buf = []
            yield "str", src[i:j]; i = j; continue
        buf.append(c); i += 1
    yield "code", "".join(buf)


def transform(src):
    kinds = []
    for kind, text in scan(src):
        kinds.extend([kind] * len(text))
    # mask whole import/export/part directives (they span str tokens)
    for m in re.finditer(r"(?m)^\s*(import|export|part)\b[^;]*;", src):
        for k in range(m.start(), m.end()):
            kinds[k] = "directive"
    res, asserts, consts = [], 0, 0
    pat_assert = re.compile(r"assert\s*\(")
    pat_const = re.compile(r"(%s)(?![\w$])" % "|".join(CONSTS))
    i, n = 0, len(src)
    while i < n:
        boundary = i == 0 or not (src[i - 1].isalnum() or src[i - 1] in "_$.")
        if kinds[i] == "code" and boundary:
            m = pat_assert.match(src, i)
            if m:
                j, depth = m.end(), 1
                while j < n and depth:
                    if kinds[j] == "code":
                        depth += {"(": 1, ")": -1}.get(src[j], 0)
                    j += 1
                res.append("assert(true)"); asserts += 1; i = j; continue
            m = pat_const.match(src, i)
            if m:
                res.append(CONSTS[m.group(1)]); consts += 1; i = m.end(); continue
        res.append(src[i]); i += 1
    return "".join(res), asserts, consts


def main():
    repo, dest = sys.argv[1], sys.argv[2]
    subprocess.check_call(["rm", "-rf", dest])
    os.makedirs(dest)
    subprocess.check_call(
        "tar -C %s --exclude=./build --exclude=./.git -cf - . | tar -C %s -xf -"
        % (repo, dest), shell=True)
    files = asserts = consts = 0
    for root, _, names in os.walk(os.path.join(dest, "lib")):
        for nm in names:
            if not nm.endswith(".dart"):
                continue
            p = os.path.join(root, nm)
            src = open(p, encoding="utf-8").read()
            new, a, c = transform(src)
            if new != src:
                files += 1
                asserts += a
                consts += c
                open(p, "w", encoding="utf-8").write(new)
    print("release-sim: %d files changed, %d asserts emptied, %d build-mode constants replaced -> %s"
          % (files, asserts, consts, dest))


if __name__ == "__main__":
    main()
