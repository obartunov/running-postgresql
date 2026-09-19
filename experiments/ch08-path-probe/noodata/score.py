#!/usr/bin/env python3
"""Score model outputs on one fold of the NooData corpus.

  score.py FOLD_DIR --pred NAME=preds.jsonl [--pred ...] [--dsn DSN]
           [--split test_transfer] [--json out.json]

preds.jsonl: one {"id": ..., "output": ...} per test item.  NAME is a
label for the table, e.g. "B-lora@A" for a model trained on B and
evaluated with A prompts.  Gold answers come from corpus_A.<split>.jsonl
(A and B carry the same gold).

Metrics, reported separately (overall accuracy is misleading with a 75%
majority class):
  fate      L0  macro-F1 over verdicts, per-verdict recall
  predict   L2  macro-F1 over verdicts; verdict and inputs both exact
  diverge   L2  predict_divergence: exact "X | Y"; both sides separately
  repair    L2  proposed SQL planned with the focus index in the plan, and
                a small edit of the original: token edit distance at most
                that of the reference answer plus 1 (without this, any
                known-good query for the same index passes); needs --dsn to
                a server loaded with setup.sql
  why       L1  as predict (not a headline metric)
  diverge0  L0  divergence with both queries planned (reading)

Three baselines are always added: "majority" (the most frequent gold answer
in the fold's train split, per metric; for repair, the query returned
unchanged), "shuffled" (gold answers permuted among the items of the same
kind, fixed seed: chance level for an answer in the right format and
vocabulary), and "reference" (the gold answers themselves; must score 1.0,
which checks the parser and the repair execution).
"""
import argparse
import json
import os
import random
import re
from collections import Counter, defaultdict

VERDICTS = ["used in the final plan", "built, lost in its relation",
            "built, kept in its relation, not used above it",
            "built for bitmap scans only, never compared", "never built",
            "not considered"]
INPUTS = ["usable condition", "useful order", "useful backward order",
          "implied predicate", "index-only scan"]


def norm(s):
    return re.sub(r"\s+", " ", (s or "").strip().strip("'\"`").rstrip(".")
                  .lower())


def field(output, name):
    m = re.search(rf"(?im)^\s*\**{name}\**\s*:\s*(.+?)\s*$", output or "")
    return m.group(1) if m else None


def parse_verdict(output):
    v = norm(field(output, "verdict"))
    if v in VERDICTS:
        return v
    # tolerate a verdict followed by extra words, longest match first
    for cand in sorted(VERDICTS, key=len, reverse=True):
        if v.startswith(cand):
            return cand
    return "invalid"


def parse_inputs(output):
    v = norm(field(output, "inputs"))
    if v in ("", "none"):
        return ["none"] if v == "none" else None
    got = [norm(x) for x in v.split(",")]
    return sorted(got)


def parse_divergence(output):
    v = field(output, "divergence")
    if v is None:
        return None
    parts = [norm(x) for x in v.split("|")]
    return " | ".join(parts)


def sql_tokens(sql):
    return re.findall(r"\w+|[^\w\s]", (sql or "").lower())


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def macro_f1(gold, pred):
    labels = sorted(set(gold))
    f1s, recall = [], {}
    for lab in labels:
        tp = sum(1 for g, p in zip(gold, pred) if g == lab and p == lab)
        fp = sum(1 for g, p in zip(gold, pred) if g != lab and p == lab)
        fn = sum(1 for g, p in zip(gold, pred) if g == lab and p != lab)
        prec = tp / (tp + fp) if tp + fp else 0.0
        rec = tp / (tp + fn) if tp + fn else 0.0
        f1s.append(2 * prec * rec / (prec + rec) if prec + rec else 0.0)
        recall[lab] = rec
    return (sum(f1s) / len(f1s) if f1s else 0.0), recall


class Planner:
    """Plans a proposed SELECT and reports the indexes in the plan."""

    def __init__(self, dsn):
        import psycopg
        self.conn = psycopg.connect(dsn, autocommit=True)
        for g in ("max_parallel_workers_per_gather = 0", "jit = off",
                  "statement_timeout = '5s'"):
            self.conn.execute(f"SET {g}")

    def indexes(self, sql):
        sql = (sql or "").strip().rstrip(";").strip()
        if not re.match(r"(?is)^select\b", sql) or ";" in sql:
            return None
        try:
            with self.conn.transaction():
                self.conn.execute("SET TRANSACTION READ ONLY")
                plan = self.conn.execute(
                    f"EXPLAIN (FORMAT JSON) {sql}").fetchone()[0]
        except Exception:
            return None
        names = []

        def walk(n):
            if "Index Name" in n:
                names.append(n["Index Name"])
            for c in n.get("Plans", []):
                walk(c)
        walk(plan[0]["Plan"])
        return names


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f]


def score(items, preds, planner):
    by_kind = defaultdict(list)
    for it in items:
        by_kind[it["kind"]].append(it)
    res = {}
    missing = sum(1 for it in items if it["id"] not in preds)

    def verdict_block(kind, with_inputs):
        its = by_kind.get(kind, [])
        if not its:
            return None
        gold = [it["meta"]["gold"]["verdict"] for it in its]
        pred = [parse_verdict(preds.get(it["id"])) for it in its]
        f1, rec = macro_f1(gold, pred)
        r = {"n": len(its), "macro_f1": round(f1, 3),
             "accuracy": round(sum(g == p for g, p in zip(gold, pred))
                               / len(its), 3),
             "invalid": sum(p == "invalid" for p in pred),
             "recall": {k: round(v, 3) for k, v in rec.items()}}
        if with_inputs:
            ok = 0
            for it, p in zip(its, pred):
                pi = parse_inputs(preds.get(it["id"]))
                ok += (p == it["meta"]["gold"]["verdict"] and
                       pi == sorted(it["meta"]["gold"]["inputs"]))
            r["verdict_and_inputs"] = round(ok / len(its), 3)
        return r

    def divergence_block(kind):
        its = by_kind.get(kind, [])
        if not its:
            return None
        exact = sides = 0
        for it in its:
            g = norm(it["meta"]["gold"]["divergence"])
            p = parse_divergence(preds.get(it["id"]))
            exact += (p == g)
            gs, ps = g.split(" | "), (p or "").split(" | ")
            if len(gs) == 2 and len(ps) == 2:
                sides += (gs[0] == ps[0]) + (gs[1] == ps[1])
            elif gs == ps:
                sides += 2
        return {"n": len(its), "exact": round(exact / len(its), 3),
                "side_match": round(sides / (2 * len(its)), 3)}

    res["fate"] = verdict_block("fate", False)
    res["predict"] = verdict_block("predict", True)
    res["why"] = verdict_block("why", True)
    res["diverge"] = divergence_block("predict_divergence")
    res["diverge0"] = divergence_block("divergence")
    its = by_kind.get("repair", [])
    if its and planner is not None:
        ok = in_plan = unchanged = invalid = too_far = 0
        for it in its:
            sql = field(preds.get(it["id"]), "sql")
            orig = re.search(r"(?m)^Query:\n(.+)$",
                             it["messages"][0]["content"]).group(1)
            if norm(sql) == norm(orig):
                unchanged += 1
            bound = edit_distance(sql_tokens(orig),
                                  sql_tokens(it["meta"]["gold"]["sql"])) + 1
            near = edit_distance(sql_tokens(orig), sql_tokens(sql)) <= bound
            idx = planner.indexes(sql)
            if idx is None:
                invalid += 1
            elif it["meta"]["focus"] in idx:
                in_plan += 1
                ok += near
                too_far += not near
        res["repair"] = {"n": len(its), "focus_in_plan": round(ok / len(its), 3),
                         "focus_in_plan_any_edit": round(in_plan / len(its), 3),
                         "too_far": too_far, "unchanged": unchanged,
                         "invalid_sql": invalid}
    res["missing"] = missing
    return {k: v for k, v in res.items() if v is not None}


def baselines(fold_dir, split, items):
    train = load(os.path.join(fold_dir, "corpus_A.train.jsonl"))
    maj = {}
    for kind in ("fate", "predict", "why"):
        g = [t["meta"]["gold"] for t in train if t["kind"] == kind]
        if g:
            v = Counter(x["verdict"] for x in g).most_common(1)[0][0]
            i = Counter(", ".join(x["inputs"]) for x in g).most_common(1)[0][0]
            maj[kind] = f"Verdict: {v}\nInputs: {i}"
    for kind in ("divergence", "predict_divergence"):
        g = [t["meta"]["gold"]["divergence"] for t in train if t["kind"] == kind]
        if g:
            maj[kind] = "Divergence: " + Counter(g).most_common(1)[0][0]
    majority, reference, shuffled = {}, {}, {}
    rng = random.Random(0)
    by_kind = defaultdict(list)
    for it in items:
        by_kind[it["kind"]].append(it)
    for kind, its in by_kind.items():
        outs = [it["messages"][1]["content"] for it in its]
        rng.shuffle(outs)
        shuffled.update({it["id"]: o for it, o in zip(its, outs)})
    for it in items:
        if it["kind"] == "repair":
            orig = re.search(r"(?m)^Query:\n(.+)$",
                             it["messages"][0]["content"]).group(1)
            majority[it["id"]] = f"SQL: {orig}"
        else:
            majority[it["id"]] = maj.get(it["kind"], "")
        reference[it["id"]] = it["messages"][1]["content"]
    return {"majority": majority, "shuffled": shuffled,
            "reference": reference}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fold_dir")
    ap.add_argument("--split", default="test_transfer")
    ap.add_argument("--pred", action="append", default=[],
                    help="NAME=predictions.jsonl")
    ap.add_argument("--dsn")
    ap.add_argument("--json")
    args = ap.parse_args()

    items = load(os.path.join(args.fold_dir, f"corpus_A.{args.split}.jsonl"))
    planner = Planner(args.dsn) if args.dsn else None
    runs = baselines(args.fold_dir, args.split, items)
    for spec in args.pred:
        name, path = spec.split("=", 1)
        runs[name] = {r["id"]: r["output"] for r in load(path)}

    table = {name: score(items, preds, planner) for name, preds in runs.items()}
    cols = [("fate", "macro_f1"), ("predict", "macro_f1"),
            ("predict", "verdict_and_inputs"), ("diverge", "exact"),
            ("diverge", "side_match"), ("repair", "focus_in_plan"),
            ("diverge0", "exact"), ("why", "verdict_and_inputs")]
    hdr = ["run"] + [f"{a}.{b}" for a, b in cols] + ["missing"]
    print(f"fold {os.path.basename(args.fold_dir)}, split {args.split}, "
          f"{len(items)} items")
    print(" | ".join(hdr))
    for name, r in table.items():
        row = [name] + [str(r.get(a, {}).get(b, "-")) for a, b in cols]
        print(" | ".join(row + [str(r["missing"])]))
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"fold": os.path.basename(args.fold_dir),
                       "split": args.split, "runs": table}, f, indent=2)


if __name__ == "__main__":
    main()
