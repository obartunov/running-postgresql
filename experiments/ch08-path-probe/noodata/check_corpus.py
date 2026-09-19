#!/usr/bin/env python3
"""Structural checks over build_corpus.py output.

  - A and B hold the same items with the same answers and splits; B's
    prompt is A's prompt plus trajectory blocks, nothing else;
  - no trajectory in A; the changed query of an L2 item is given as SQL
    only, in both corpora;
  - answers carry no event labels or payload field names, and L2 answers
    carry no cost figures;
  - the held-out family never appears in train; every test_interp template
    has other variants in train; no test SQL text appears in train.

Last line "CHECK PASSED" and exit 0 mean every check held.
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_corpus import FORBIDDEN  # noqa: E402

out = sys.argv[1]
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f]


TRAJ = re.compile(r"\n\n[^\n]*planner trajectory:\n.*?(?=\n\n|\Z)", re.S)

folds = sorted(glob.glob(os.path.join(out, "fold-*")))
check(folds, "no folds")
for fdir in folds:
    fold = fdir.split("fold-", 1)[1]
    A, B = {}, {}
    for path in glob.glob(os.path.join(fdir, "corpus_A.*.jsonl")):
        A.update({r["id"]: r for r in load(path)})
    for path in glob.glob(os.path.join(fdir, "corpus_B.*.jsonl")):
        B.update({r["id"]: r for r in load(path)})
    check(A and set(A) == set(B), f"{fold}: A and B hold different items")

    sql_by_split = {}
    for iid, a in A.items():
        b = B.get(iid)
        if b is None:
            continue
        ua, ub = a["messages"][0]["content"], b["messages"][0]["content"]
        ans = a["messages"][1]["content"]
        check(ans == b["messages"][1]["content"], f"{fold} {iid}: answers differ")
        check(a["split"] == b["split"], f"{fold} {iid}: splits differ")
        check("planner trajectory" not in ua, f"{fold} {iid}: trajectory in A")
        check(TRAJ.sub("", ub) == ua,
              f"{fold} {iid}: B is not A plus trajectory")
        n_full = ua.count("final plan (EXPLAIN)")
        check(ub.count("planner trajectory:") == n_full,
              f"{fold} {iid}: B lacks a trajectory for a planned query")
        for tok in FORBIDDEN:
            check(tok not in ans, f"{fold} {iid}: answer contains {tok!r}")
        if a["level"] == "L2":
            check(not re.search(r"\d+\.\d\d", ans),
                  f"{fold} {iid}: cost figure in an L2 answer")
            # predict: one planned query plus the changed one as SQL only;
            # repair: the planned query alone
            m = re.search(r"Changed query \(not planned\):\n", ua)
            check(bool(m) == (a["kind"] != "repair") and
                  ua.count("final plan (EXPLAIN)") == 1,
                  f"{fold} {iid}: L2 prompt plans more than the source query")
        meta = a["meta"]
        sp = a["split"]
        if sp == "test_transfer":
            check(meta["family"] == fold, f"{fold} {iid}: wrong family in "
                  "transfer")
        else:
            check(meta["family"] != fold, f"{fold} {iid}: held-out family "
                  f"in {sp}")
        for m in re.finditer(r"(?m)^(?:Query(?: \d)?|Changed query[^:]*):\n(.+)$",
                             ua):
            sql_by_split.setdefault(sp, set()).add(m.group(1))

    train_t = {a["meta"]["template"] for a in A.values()
               if a["split"] == "train"}
    for a in A.values():
        if a["split"] == "test_interp":
            check(a["meta"]["template"] in train_t,
                  f"{fold} {a['id']}: interp template absent from train")
    for sp in ("test_interp", "test_transfer"):
        overlap = sql_by_split.get(sp, set()) & sql_by_split.get("train", set())
        check(not overlap, f"{fold}: {sp} SQL also in train: "
              f"{sorted(overlap)[:3]}")

for f in failures[:40]:
    print("FAIL:", f)
print(f"{len(folds)} folds, {len(failures)} failures")
print("CHECK PASSED" if not failures else "CHECK FAILED")
sys.exit(1 if failures else 0)
