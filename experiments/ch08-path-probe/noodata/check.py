#!/usr/bin/env python3
"""Structural checks over a generated NooData directory.

Checks properties of the events, never particular costs.  Exit status 0 and
a last line "CHECK PASSED" mean every check held.
"""
import json
import os
import sys

BIRTH = ("INDEX_PATH_GENERATED", "INDEX_PATH_NOT_GENERATED")
INDEX_TYPES = ("IndexScan", "IndexOnlyScan", "BitmapHeapScan")
FLAGS = ("has_index_clauses", "has_useful_pathkeys",
         "has_useful_backward_pathkeys", "useful_predicate", "index_only_scan")

out = sys.argv[1]
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load(name):
    with open(os.path.join(out, name)) as f:
        return [json.loads(line) for line in f]


recs = {r["id"]: r for r in load("noodata.jsonl")}
base = {r["id"]: r for r in load("baseline.jsonl")}
fates = {r["id"]: r for r in load("index_fates.jsonl")}
seen = set()

check(set(recs) == set(base), "baseline and noodata cover different queries")

for qid, r in recs.items():
    ev = r["trajectory"]
    check(base[qid]["explain"] == r["explain"], f"{qid}: EXPLAIN differs")
    check("trajectory" not in base[qid], f"{qid}: trajectory leaked to baseline")
    check([e["seq"] for e in ev] == list(range(1, len(ev) + 1)),
          f"{qid}: seq not contiguous")
    live = {}           # (rel_id, path_id) -> in pathlist
    born = set()        # indexes with a GENERATED event so far
    for e in ev:
        seen.add(e["event"])
        if e["event"] in BIRTH:
            gen = e["event"] == "INDEX_PATH_GENERATED"
            check(gen == (e["npaths"] > 0), f"{qid}#{e['seq']}: npaths")
            check(gen == any(e[f] for f in FLAGS),
                  f"{qid}#{e['seq']}: birth decision inconsistent with flags")
            if gen:
                born.add(e["index"])
            continue
        if e["event"] == "PRECHECK_REJECTED":
            check(e["path_id"] is None and e["path_type"] is None,
                  f"{qid}#{e['seq']}: precheck subject must not be a Path")
            check(e["rel_kind"] == "join", f"{qid}#{e['seq']}: precheck on "
                  "non-join rel")
            continue
        # every index path was born at the birth boundary before add_path
        if e["path_type"] in INDEX_TYPES and e["index"] is not None:
            check(e["index"] in born,
                  f"{qid}#{e['seq']}: {e['index']} path without birth event")
        key = (e["rel_id"], e["path_id"])
        if e["event"] == "ACCEPTED":
            check(not live.get(key), f"{qid}#{e['seq']}: accepted twice")
            live[key] = True
        elif e["event"] == "DISPLACED":
            if not e.get("first_seen"):
                check(live.get(key), f"{qid}#{e['seq']}: displaced path was "
                      "not accepted before")
            live[key] = False
            check(e["competitor_path_id"] != e["path_id"],
                  f"{qid}#{e['seq']}: displaced by itself")
        elif e["event"] == "REJECTED":
            check(not live.get(key), f"{qid}#{e['seq']}: rejected live path")
            ckey = (e["rel_id"], e.get("competitor_path_id"))
            check(live.get(ckey) or e.get("competitor_first_seen"),
                  f"{qid}#{e['seq']}: rejected by a path not in the list")

    # NEVER_GENERATED means: a birth decision, negative, and no paths at all
    for idx, f in fates[qid]["indexes"].items():
        if f["verdict"] == "NEVER_GENERATED":
            check(f["births"] and not f["paths"] and
                  all(b["event"] == "INDEX_PATH_NOT_GENERATED"
                      for b in f["births"]),
                  f"{qid}: {idx} NEVER_GENERATED with paths or births")
        if f["verdict"] == "NOT_EXAMINED":
            check(not f["births"] and not f["paths"],
                  f"{qid}: {idx} NOT_EXAMINED with events")

# the dataset must contain each kind of fate at least once
for kind in ("ACCEPTED", "REJECTED", "DISPLACED", "PRECHECK_REJECTED",
             "INDEX_PATH_GENERATED", "INDEX_PATH_NOT_GENERATED"):
    check(kind in seen, f"no {kind} event in the dataset")

verdicts = {v["verdict"] for f in fates.values() for v in f["indexes"].values()}
for v in ("CHOSEN", "PRUNED", "NEVER_GENERATED", "SURVIVED_NOT_CHOSEN"):
    check(v in verdicts, f"no {v} verdict in the dataset")

# accepted, then displaced: one path id, two events
check(any(
    any(s["event"] == "ACCEPTED" for s in p["events"]) and
    any(s["event"] == "DISPLACED" for s in p["events"])
    for f in fates.values() for v in f["indexes"].values()
    for p in v["paths"]) or any(
    e["event"] == "DISPLACED" and not e.get("first_seen")
    for r in recs.values() for e in r["trajectory"]),
    "no accept-then-displace sequence")

pairs = load("pairs.jsonl")
check(len(pairs) * 2 == len(recs), "pair/query count mismatch")
splits = {r["pair_id"]: r["split"] for r in recs.values()}
check(all(recs[f"{p['pair_id']}.q1"]["split"] ==
          recs[f"{p['pair_id']}.q2"]["split"] for p in pairs),
      "a pair is split across train/test")

for f in failures:
    print("FAIL:", f)
print(f"{len(recs)} queries, "
      f"{sum(len(r['trajectory']) for r in recs.values())} events, "
      f"{len(failures)} failures")
print("CHECK PASSED" if not failures else "CHECK FAILED")
sys.exit(1 if failures else 0)
