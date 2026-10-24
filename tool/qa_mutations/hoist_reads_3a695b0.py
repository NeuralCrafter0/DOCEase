#!/usr/bin/env python3
"""QA mutations for #16 3a695b0 (security L-3), retargeted from
hoist_spf_outside_lock.py (whose `final x = await _db.swappedPathsFor` shape
no longer exists: 3a695b0 reads storedRow + swapped in a strict try block).

  hoist  : updateRecord's strict reads (fetchPatientsStrict + swappedPathsFor)
           move OUTSIDE _mutateHistory (the per-patient lock), so the save
           uses a snapshot taken before a concurrent removal/upload commits.
  guard  : disables the "a form can keep a cloud reference, never introduce
           one" resurrection check (resurrected.isNotEmpty -> false).
  both   : hoist + guard.

Usage: python3 hoist_reads_3a695b0.py <hoist|guard|both> lib/providers/patient_provider.dart
Exit 2 if the expected shape is not found (re-target by hand; do not guess).
"""
import sys

mode, p = sys.argv[1], sys.argv[2]
s = open(p).read()

HEAD = "  Future<void> updateRecord(String patientId, VisitRecord record) {\n    final copies = <String>[];\n    return _mutateHistory(patientId, (current) async {\n"
READ_ROW = "        storedRow = (await _db.fetchPatientsStrict())\n"
READ_SWP = "        swapped = await _db.swappedPathsFor(expectedOwner: owner, patientId: patientId);\n"
GUARD = "      if (resurrected.isNotEmpty) {"

def need(cond, what):
    if not cond:
        print("shape not found:", what); sys.exit(2)

start = s.find(HEAD)
need(start >= 0, "updateRecord head (non-async, copies, return _mutateHistory)")
end = s.find("\n  Future<", start + len(HEAD))
body = s[start:end]

if mode in ("hoist", "both"):
    need(body.count(READ_ROW) == 1 and body.count(READ_SWP) == 1, "strict reads inside the lock")
    body = body.replace(HEAD,
        "  Future<void> updateRecord(String patientId, VisitRecord record) async {\n"
        "    final copies = <String>[];\n"
        "    // QA MUT hoist: strict reads taken BEFORE the per-patient lock\n"
        "    final qaOwner = _photoOwner;\n"
        "    final qaRows = await _db.fetchPatientsStrict();\n"
        "    final qaSwapped = qaOwner == null ? <String, String>{}\n"
        "        : await _db.swappedPathsFor(expectedOwner: qaOwner, patientId: patientId);\n"
        "    return _mutateHistory(patientId, (current) async {\n", 1)
    body = body.replace(READ_ROW, "        storedRow = (qaRows) // QA MUT hoist\n", 1)
    body = body.replace(READ_SWP, "        swapped = qaSwapped; // QA MUT hoist\n", 1)

if mode in ("guard", "both"):
    need(body.count(GUARD) == 1, "resurrection guard")
    body = body.replace(GUARD, "      if (false && resurrected.isNotEmpty) { // QA MUT guard", 1)

need(mode in ("hoist", "guard", "both"), "mode must be hoist|guard|both")
open(p, "w").write(s[:start] + body + s[end:])
print("applied:", mode)
