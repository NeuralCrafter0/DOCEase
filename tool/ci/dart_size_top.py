#!/usr/bin/env python3
"""Print a Markdown table of the largest Dart packages inside libapp.so from
`flutter build apk --analyze-size` output (apk-code-size-analysis_*.json).

Usage: dart_size_top.py <dir-with-json> [top_n]
"""
import glob
import json
import os
import sys


def find(node, pred):
    if pred(node):
        return node
    for c in node.get("children") or []:
        r = find(c, pred)
        if r:
            return r
    return None


def size(node):
    if "value" in node:
        return node["value"]
    return sum(size(c) for c in node.get("children") or [])


def main():
    d = sys.argv[1]
    top = int(sys.argv[2]) if len(sys.argv) > 2 else 15
    files = sorted(glob.glob(os.path.join(d, "apk-code-size-analysis_*.json")))
    if not files:
        print("_No --analyze-size report found._\n")
        return 0
    data = json.load(open(files[-1]))
    root = data.get("root", data)
    lib = find(root, lambda n: "libapp.so" in str(n.get("n", "")))
    if not lib:
        print("_libapp.so not found in the size report._\n")
        return 0
    kids = sorted(lib.get("children") or [], key=size, reverse=True)
    total = size(lib)
    print("#### Largest Dart packages in libapp.so (arm64, uncompressed)\n")
    print("| Package | KiB | Share |")
    print("|---|---:|---:|")
    for k in kids[:top]:
        s = size(k)
        print(f"| `{k.get('n')}` | {s / 1024:.0f} | {100 * s / total:.1f}% |")
    print(f"| **libapp.so total** | **{total / 1024:.0f}** | |\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
