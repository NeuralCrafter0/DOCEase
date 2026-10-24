#!/usr/bin/env python3
"""QA mutation for #16's next head (security L-3): move updateRecord's
swappedPathsFor(...) read from inside _mutateHistory (the per-patient lock)
to before it. RACE-01/02 in qa_race16_ffi_test.dart must then fail.
Usage: python3 tool/qa_mutations/hoist_spf_outside_lock.py lib/providers/patient_provider.dart
Exit 2 if the expected shape is not found (re-target by hand; do not guess)."""
import re, sys
p = sys.argv[1]; s = open(p).read()
m = re.search(r"Future<void> updateRecord\(String patientId, VisitRecord record\)\s*(?:async\s*)?\{", s)
if not m: sys.exit("no updateRecord(String patientId, VisitRecord record) {"[:0] or 2)
body_start = m.end()
lock = s.find("_mutateHistory(", body_start)
call = re.search(r"\n(\s*)(final|var)\s+(\w+)\s*=\s*await\s+_db\.swappedPathsFor\([^;]*\);", s[lock:])
if lock < 0 or not call:
    print("shape not found: expected `final x = await _db.swappedPathsFor(...);` inside _mutateHistory in updateRecord"); sys.exit(2)
stmt = call.group(0)
s2 = s[:lock] + s[lock:].replace(stmt, "\n" + call.group(1) + "// QA MUT: hoisted outside the lock", 1)
ret = s2.rfind("return", body_start, lock)
indent = "    "
hoisted = indent + stmt.strip() + "  // QA MUT\n" + indent
if "async" not in s2[m.start():body_start]:
    s2 = s2[:m.end()-1] + "async " + s2[m.end()-1:]; ret += len("async ")
s2 = s2[:ret] + hoisted + s2[ret:]
open(p, "w").write(s2); print("hoisted:", stmt.strip()[:100])
