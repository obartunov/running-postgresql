#!/usr/bin/env python3
"""NooData v0 dataset generator.

Runs controlled query pairs against a server built with the planner
injection points and the noodata_trace module, and writes:

  baseline.jsonl   SQL + schema/statistics + final EXPLAIN
  noodata.jsonl    the same + planner trajectory (raw events)
  actual.jsonl     EXPLAIN ANALYZE per query (kept apart; not part of v0)
  pairs.jsonl      per pair: first divergence of the two trajectories
  questions.jsonl  questions whose answers are derived from the trace only
  manifest.json    server version, GUCs, counts

Usage: gen.py --dsn "host=/tmp port=5499 dbname=postgres" --out DIR
       gen.py --dsn ... --out DIR --explain-only   (plans only, no trace)
       gen.py --dsn ... --out DIR --pairs pairs-v1.json

A pair file entry either gives q1/q2 directly, or gives q1/q2 as format
templates plus "variants", a list of parameter dicts; each variant becomes a
pair with id "<id>.v<n>".  Optional "family" and "focus" are passed through.
"""
import argparse
import hashlib
import json
import os
import re
import sys

import psycopg

HERE = os.path.dirname(os.path.abspath(__file__))

SESSION_GUCS = {
    "max_parallel_workers_per_gather": "0",
    "jit": "off",
    "client_min_messages": "notice",
}

# Fields that identify an event structurally: costs, row counts and path ids
# are left out, so two trajectories diverge where the planner did something
# different, not where a number moved.
STRUCT_FIELDS = [
    "event", "rel_id", "rel_kind", "relids",
    "path_type", "index", "pathkeys", "required_outer",
    "competitor_path_type", "competitor_index", "competitor_pathkeys",
    "competitor_required_outer",
    "bitmap_only", "has_index_clauses", "has_useful_pathkeys",
    "has_useful_backward_pathkeys", "useful_predicate", "index_only_scan",
    "npaths",
]

BIRTH_EVENTS = ("INDEX_PATH_GENERATED", "INDEX_PATH_NOT_GENERATED")
INDEX_PATH_TYPES = ("IndexScan", "IndexOnlyScan", "BitmapHeapScan")


def split_of(pair_id):
    """Deterministic train/test split by pair, shared by both datasets."""
    h = int(hashlib.sha1(pair_id.encode()).hexdigest(), 16)
    return "test" if h % 5 == 0 else "train"


def tables_of(sql):
    return sorted(set(m for m in re.findall(r"\b(?:FROM|JOIN)\s+(\w+)", sql,
                                            re.I)))


class Runner:
    def __init__(self, dsn, trace):
        self.conn = psycopg.connect(dsn, autocommit=True)
        self.notices = []
        self.conn.add_notice_handler(self._notice)
        self.trace = trace

    def _notice(self, diag):
        msg = diag.message_primary or ""
        if msg.startswith("NOODATA "):
            self.notices.append(json.loads(msg[len("NOODATA "):]))

    def execute(self, sql):
        with self.conn.cursor() as cur:
            cur.execute(sql)
            if cur.description is None:
                return None
            return cur.fetchall()

    def setup(self):
        # one statement at a time: VACUUM cannot run in the implicit
        # transaction of a multi-statement string
        with open(os.path.join(HERE, "setup.sql")) as f:
            for stmt in re.split(r";\s*\n", f.read()):
                if stmt.strip() and not all(
                        ln.strip().startswith("--") or not ln.strip()
                        for ln in stmt.splitlines()):
                    self.execute(stmt)
        for k, v in SESSION_GUCS.items():
            self.execute(f"SET {k} = {v}")
        if self.trace:
            self.execute("CREATE EXTENSION IF NOT EXISTS noodata_trace")
            self.execute("SELECT noodata_trace_detach()")
            # one statement: see noodata_trace--0.1.sql
            self.execute("SELECT noodata_trace_attach()")

    def teardown(self):
        if self.trace:
            self.execute("SELECT noodata_trace_detach()")

    def explain(self, sql):
        rows = self.execute(f"EXPLAIN (COSTS ON) {sql}")
        return "\n".join(r[0] for r in rows)

    def traced_explain(self, sql):
        self.notices = []
        self.execute("SET noodata_trace.enabled = on")
        text = self.explain(sql)
        self.execute("RESET noodata_trace.enabled")
        events = self.notices
        self.notices = []
        plans = {e["plan"] for e in events}
        if len(plans) > 1:
            raise RuntimeError(f"trace spans {len(plans)} planner calls: {sql}")
        return text, events

    def explain_json(self, sql):
        return self.execute(f"EXPLAIN (COSTS ON, FORMAT JSON) {sql}")[0][0]

    def explain_analyze(self, sql):
        return self.execute(
            "EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF, BUFFERS OFF, "
            f"FORMAT JSON) {sql}")[0][0]

    def stats(self, tables):
        out = {}
        for t in tables:
            rel = self.execute(
                "SELECT reltuples::bigint, relpages FROM pg_class "
                f"WHERE oid = '{t}'::regclass")[0]
            idx = self.execute(
                "SELECT c.relname, c.relpages, pg_get_indexdef(i.indexrelid) "
                "FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid "
                f"WHERE i.indrelid = '{t}'::regclass ORDER BY c.relname")
            cols = self.execute(
                "SELECT attname, null_frac, n_distinct, correlation, "
                "(most_common_vals::text::text[])[1:3], "
                "most_common_freqs[1:3] "
                "FROM pg_stats WHERE schemaname = 'public' "
                f"AND tablename = '{t}' ORDER BY attname")
            out[t] = {
                "reltuples": rel[0], "relpages": rel[1],
                "indexes": [{"name": n, "relpages": p, "def": d}
                            for n, p, d in idx],
                "columns": {
                    a: {"null_frac": round(nf, 4),
                        "n_distinct": round(nd, 4),
                        "correlation": (round(cor, 4) if cor is not None
                                        else None),
                        "mcv": mcv, "mcf": ([round(x, 4) for x in mcf]
                                            if mcf else None)}
                    for a, nf, nd, cor, mcv, mcf in cols},
            }
        return out


def plan_index_names(plan_json):
    names = []

    def walk(node):
        if "Index Name" in node:
            names.append(node["Index Name"])
        for ch in node.get("Plans", []):
            walk(ch)
    walk(plan_json[0]["Plan"])
    return names


def signature(e):
    return tuple(json.dumps(e.get(k), sort_keys=True) for k in STRUCT_FIELDS)


def first_divergence(ev1, ev2, key):
    n = min(len(ev1), len(ev2))
    for i in range(n):
        if key(ev1[i]) != key(ev2[i]):
            return {"position": i + 1, "q1_event": ev1[i], "q2_event": ev2[i]}
    if len(ev1) != len(ev2):
        return {"position": n + 1,
                "q1_event": ev1[n] if len(ev1) > n else None,
                "q2_event": ev2[n] if len(ev2) > n else None}
    return None


def index_fates(events, index_names, final_indexes):
    """Per index: birth decisions, lifecycle of each of its paths, verdict.

    Derived from the trace alone plus the index names of the final plan.
    """
    out = {}
    for idx in index_names:
        births = [e for e in events
                  if e["event"] in BIRTH_EVENTS and e["index"] == idx]
        paths = {}
        for e in events:
            if e["event"] in BIRTH_EVENTS or e["event"] == "PRECHECK_REJECTED":
                continue
            if e.get("index") != idx or e["path_type"] not in INDEX_PATH_TYPES:
                continue
            p = paths.setdefault(e["path_id"], {
                "path_id": e["path_id"], "path_type": e["path_type"],
                "required_outer": e["required_outer"],
                "pathkeys": e["pathkeys"], "events": []})
            step = {"seq": e["seq"], "event": e["event"],
                    "rel_id": e["rel_id"]}
            if "competitor_path_id" in e:
                step["by"] = {"path_id": e["competitor_path_id"],
                              "path_type": e["competitor_path_type"],
                              "index": e["competitor_index"]}
            p["events"].append(step)
        for p in paths.values():
            # fate in the relation where the path was first submitted
            home = p["events"][0]["rel_id"]
            last = [s for s in p["events"] if s["rel_id"] == home][-1]
            p["fate"] = {"ACCEPTED": "SURVIVED", "REJECTED": "REJECTED",
                         "DISPLACED": "DISPLACED"}[last["event"]]
            if "by" in last and last["event"] != "ACCEPTED":
                p["lost_to"] = last["by"]

        generated = any(b["event"] == "INDEX_PATH_GENERATED" for b in births)
        if idx in final_indexes:
            verdict = "CHOSEN"
        elif not births:
            verdict = "NOT_EXAMINED"
        elif not generated:
            verdict = "NEVER_GENERATED"
        elif not paths:
            verdict = "GENERATED_NOT_SUBMITTED"
        elif any(p["fate"] == "SURVIVED" for p in paths.values()):
            verdict = "SURVIVED_NOT_CHOSEN"
        else:
            verdict = "PRUNED"
        out[idx] = {
            "verdict": verdict,
            "births": [{k: b[k] for k in (
                "seq", "event", "required_outer", "bitmap_only",
                "has_index_clauses", "has_useful_pathkeys",
                "has_useful_backward_pathkeys", "useful_predicate",
                "index_only_scan", "npaths")} for b in births],
            "paths": sorted(paths.values(), key=lambda p: p["path_id"]),
        }
    return out


def questions_for_query(qid, split, fates):
    qs = []

    def add(kind, index, question, answer):
        qs.append({"id": f"{qid}:{kind}:{index}", "query_id": qid,
                   "split": split, "kind": kind, "index": index,
                   "question": question, "answer": answer})

    for idx, f in fates.items():
        v = f["verdict"]
        plain = any(b["event"] == "INDEX_PATH_GENERATED" and
                    not b["bitmap_only"] for b in f["births"])
        add("generated", idx, f"Was an IndexPath on {idx} generated?",
            "not examined" if v == "NOT_EXAMINED" else
            "no" if v == "NEVER_GENERATED" else
            "yes" if plain else "yes, for bitmap scans only")
        add("existed_or_not", idx,
            f"If {idx} is not in the final plan: did a candidate on it exist "
            "and lose, or did no candidate exist?",
            {"CHOSEN": "in final plan",
             "NOT_EXAMINED": "no candidate: index not examined",
             "NEVER_GENERATED": "no candidate: never generated",
             "GENERATED_NOT_SUBMITTED": "existed, not submitted to add_path",
             "SURVIVED_NOT_CHOSEN": "existed and survived its relation, "
                                    "lost above it",
             "PRUNED": "existed and lost in add_path"}[v])
        if v == "NEVER_GENERATED":
            b = [x for x in f["births"] if not x["bitmap_only"]] or f["births"]
            add("why_not_generated", idx,
                f"Why was no IndexPath on {idx} generated?",
                {k: b[0][k] for k in ("has_index_clauses", "has_useful_pathkeys",
                                      "has_useful_backward_pathkeys",
                                      "useful_predicate", "index_only_scan")})
        for p in f["paths"]:
            if p["fate"] in ("REJECTED", "DISPLACED"):
                add(f"lost_to#{p['path_id']}", idx,
                    f"The {p['path_type']} on {idx} "
                    f"(required_outer={p['required_outer']}, "
                    f"pathkeys={p['pathkeys']}): how did it lose, and to what?",
                    {"boundary": p["fate"], "by": p.get("lost_to")})
    return qs


PASS_THROUGH = ("template", "family", "focus", "params")


def expand_pairs(entries):
    out = []
    for p in entries:
        if "variants" not in p:
            out.append(p)
            continue
        for i, params in enumerate(p["variants"]):
            q = {k: v for k, v in p.items() if k != "variants"}
            q.update(id=f"{p['id']}.v{i}", template=p["id"], params=params,
                     q1=p["q1"].format(**params), q2=p["q2"].format(**params))
            if "focus" in p:
                q["focus"] = p["focus"].format(**params)
            out.append(q)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--explain-only", action="store_true")
    ap.add_argument("--pairs", default=os.path.join(HERE, "pairs.json"))
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    with open(args.pairs) as f:
        pairs = expand_pairs(json.load(f))
    with open(os.path.join(HERE, "setup.sql")) as f:
        schema_sql = f.read()

    r = Runner(args.dsn, trace=not args.explain_only)
    r.setup()

    if args.explain_only:
        with open(os.path.join(args.out, "explains.txt"), "w") as f:
            for p in pairs:
                for v in ("q1", "q2"):
                    f.write(f"-- {p['id']} {v}: {p[v]}\n{r.explain(p[v])}\n\n")
        return

    all_tables = sorted({t for p in pairs for v in ("q1", "q2")
                         for t in tables_of(p[v])})
    stats = r.stats(all_tables)
    server = r.execute("SELECT version()")[0][0]

    base_f = open(os.path.join(args.out, "baseline.jsonl"), "w")
    noo_f = open(os.path.join(args.out, "noodata.jsonl"), "w")
    act_f = open(os.path.join(args.out, "actual.jsonl"), "w")
    pair_f = open(os.path.join(args.out, "pairs.jsonl"), "w")
    q_f = open(os.path.join(args.out, "questions.jsonl"), "w")
    fate_f = open(os.path.join(args.out, "index_fates.jsonl"), "w")

    counts = {"queries": 0, "events": 0, "by_event": {}, "questions": 0,
              "verdicts": {}}
    for p in pairs:
        split = split_of(p["id"])
        traces = {}
        for v in ("q1", "q2"):
            sql = p[v]
            qid = f"{p['id']}.{v}"
            tables = tables_of(sql)
            text, events = r.traced_explain(sql)
            if r.explain(sql) != text:
                raise RuntimeError(f"plan differs with tracing on: {sql}")
            pj = r.explain_json(sql)
            final_idx = plan_index_names(pj)
            idx_names = [i["name"] for t in tables for i in stats[t]["indexes"]]
            fates = index_fates(events, idx_names, final_idx)
            traces[v] = events

            common = {"id": qid, "pair_id": p["id"], "variant": v,
                      **{k: p[k] for k in PASS_THROUGH if k in p},
                      "split": split, "category": p["category"], "sql": sql,
                      "schema": schema_sql,
                      "statistics": {t: stats[t] for t in tables}}
            base_f.write(json.dumps({**common, "explain": text}) + "\n")
            noo_f.write(json.dumps({**common, "trajectory": events,
                                    "explain": text}) + "\n")
            act_f.write(json.dumps({"id": qid, "sql": sql,
                                    "explain_analyze": r.explain_analyze(sql)})
                        + "\n")
            for q in questions_for_query(qid, split, fates):
                q_f.write(json.dumps(q) + "\n")
                counts["questions"] += 1
            # keep the derived per-index facts next to the questions
            fate_f.write(json.dumps({"id": qid, "final_plan_indexes": final_idx,
                                     "indexes": fates}) + "\n")
            counts["queries"] += 1
            counts["events"] += len(events)
            for e in events:
                counts["by_event"][e["event"]] = \
                    counts["by_event"].get(e["event"], 0) + 1
            for f_ in fates.values():
                counts["verdicts"][f_["verdict"]] = \
                    counts["verdicts"].get(f_["verdict"], 0) + 1

        d_struct = first_divergence(traces["q1"], traces["q2"], signature)
        d_full = first_divergence(
            traces["q1"], traces["q2"],
            lambda e: json.dumps({k: v for k, v in e.items() if k != "plan"},
                                 sort_keys=True))
        pair_rec = {"pair_id": p["id"],
                    **{k: p[k] for k in PASS_THROUGH if k in p},
                    "split": split,
                    "category": p["category"], "diff": p["diff"],
                    "q1": p["q1"], "q2": p["q2"],
                    "events": [len(traces["q1"]), len(traces["q2"])],
                    "first_divergence": d_full,
                    "first_structural_divergence": d_struct}
        pair_f.write(json.dumps(pair_rec) + "\n")
        for kind, question, answer in (
                ("first_divergence",
                 "Where do the Q1 and Q2 planner trajectories first diverge "
                 "structurally (ignoring costs)?",
                 None if d_struct is None else
                 {"position": d_struct["position"],
                  "q1": d_struct["q1_event"] and
                  {k: d_struct["q1_event"].get(k) for k in STRUCT_FIELDS
                   if k in d_struct["q1_event"]},
                  "q2": d_struct["q2_event"] and
                  {k: d_struct["q2_event"].get(k) for k in STRUCT_FIELDS
                   if k in d_struct["q2_event"]}}),
                ("input_difference",
                 "What single input difference between Q1 and Q2 corresponds "
                 "to that divergence?", p["diff"])):
            q_f.write(json.dumps({"id": f"{p['id']}:{kind}",
                                  "pair_id": p["id"], "split": split,
                                  "kind": kind, "question": question,
                                  "answer": answer}) + "\n")
            counts["questions"] += 1

    r.teardown()
    for f in (base_f, noo_f, act_f, pair_f, q_f, fate_f):
        f.close()
    manifest = {"server": server, "session_gucs": SESSION_GUCS,
                "pairs": len(pairs),
                "splits": {s: sum(1 for p in pairs if split_of(p["id"]) == s)
                           for s in ("train", "test")},
                "counts": counts}
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    json.dump(counts, sys.stdout, indent=2, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
