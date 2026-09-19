#!/usr/bin/env python3
"""Build the A/B training corpora and the eval sets from a gen.py directory.

  A = schema/statistics + SQL + final EXPLAIN
  B = A + planner trajectory

Both corpora contain the same questions with the same reference answers; only
the context differs.  Answers are worded in terms of what the planner did
(built, kept, discarded, replaced, never built), never as event labels or
payload field names, so that a correct answer is not a copy of a token from
the input.

Questions come in three levels:
  L0  what happened          (reading; mostly a sanity check for B)
  L1  why it happened        (inputs of the build decision, cost comparison)
  L2  what if / transfer     (predict the fate or the first divergence for a
                              changed query, whose plan and trajectory are NOT
                              given; propose a change that makes the index
                              usable)

Splits, per held-out family F (one "fold" per F given with --fold):
  test_transfer  every instance of family F
  test_interp    variant 2 of every other template whose variants give
                 pairwise different SQL on both sides (a template with a
                 constant side, like "s = 0", would repeat that query and its
                 trajectory in train)
  train          the rest
The pair split of gen.py (sha1 of the pair id) is kept as "pair_split".

Usage: build_corpus.py RAW_DIR OUT_DIR --fold ordering --fold expression_index
"""
import argparse
import json
import os
import re
from collections import Counter, defaultdict

VERDICT_SHORT = {
    "CHOSEN": "used in the final plan",
    "PRUNED": "built, lost in its relation",
    "SURVIVED_NOT_CHOSEN": "built, kept in its relation, not used above it",
    "GENERATED_NOT_SUBMITTED": "built for bitmap scans only, never compared",
    "NEVER_GENERATED": "never built",
    "NOT_EXAMINED": "not considered",
}
# for the repair question: which side of a pair is the weaker one
VERDICT_RANK = ["NOT_EXAMINED", "NEVER_GENERATED", "GENERATED_NOT_SUBMITTED",
                "PRUNED", "SURVIVED_NOT_CHOSEN", "CHOSEN"]

INPUTS = [("has_index_clauses", "a query condition usable with the index"),
          ("has_useful_pathkeys", "a useful sort order"),
          ("has_useful_backward_pathkeys", "a useful sort order when scanned "
           "backward"),
          ("useful_predicate", "an index predicate implied by the query"),
          ("index_only_scan", "an index-only scan is possible")]

# tokens that must never appear in an answer
FORBIDDEN = ["ACCEPTED", "REJECTED", "DISPLACED", "PRECHECK", "INDEX_PATH",
             "NEVER_GENERATED", "NOT_EXAMINED", "PRUNED", "SURVIVED_NOT_CHOSEN",
             "GENERATED_NOT_SUBMITTED", "CHOSEN", "has_index_clauses",
             "has_useful", "useful_predicate", "index_only_scan", "bitmap_only",
             "path_id", "rel_id", "competitor", "npaths", '"event"', "{\""]


def load(path):
    with open(path) as f:
        return [json.loads(line) for line in f]


# ---------------------------------------------------------------- context

def table_columns(schema_sql):
    cols = {}
    for name, body in re.findall(r"CREATE TABLE (\w+) \((.*?)\n\);", schema_sql,
                                 re.S):
        cols[name] = []
        for line in body.splitlines():
            line = re.sub(r"--.*", "", line).strip().rstrip(",")
            m = re.match(r"(\w+)\s+(\w+)", line)
            if m:
                cols[name].append((m.group(1), m.group(2)))
    return cols


def render_schema(rec):
    cols = table_columns(rec["schema"])
    out = []
    for t, st in rec["statistics"].items():
        out.append(f"table {t}: {st['reltuples']} rows, {st['relpages']} pages")
        for c, typ in cols[t]:
            s = st["columns"].get(c, {})
            mcv = ""
            if s.get("mcv"):
                mcv = " mcv=" + ",".join(
                    f"{v}:{f}" for v, f in zip(s["mcv"], s["mcf"]))
            out.append(f"  column {c} {typ}: n_distinct={s.get('n_distinct')} "
                       f"null_frac={s.get('null_frac')} "
                       f"correlation={s.get('correlation')}{mcv}")
        for i in st["indexes"]:
            d = re.sub(r"^CREATE (UNIQUE )?INDEX \w+ ON \w+\.(\w+) USING ", r"\2 ",
                       i["def"])
            out.append(f"  index {i['name']} on {d}, {i['relpages']} pages")
    return "\n".join(out)


def rel_name(e, tables):
    if e["rel_kind"] in ("upper", "other_upper"):
        return f"result level {e['rel_id']}"
    names = [tables[r - 1] if 0 < r <= len(tables) else f"rel{r}"
             for r in e["relids"]]
    return ("join of " if len(names) > 1 else "scan of ") + " and ".join(names)


def path_desc(e, prefix=""):
    t = e[prefix + "path_type"]
    idx = e.get(prefix + "index")
    s = f"{t}#{e[prefix + 'path_id']}" + (f"[{idx}]" if idx else "")
    extra = []
    if e.get(prefix + "pathkeys"):
        extra.append("order " + ",".join(e[prefix + "pathkeys"]))
    if e.get(prefix + "required_outer"):
        extra.append(f"needs outer {e[prefix + 'required_outer']}")
    cost = f"cost {e[prefix + 'startup_cost']:.2f}..{e[prefix + 'total_cost']:.2f}"
    if prefix + "rows" in e:
        cost += f" rows {e[prefix + 'rows']:.0f}"
    return s + " " + cost + (" (" + "; ".join(extra) + ")" if extra else "")


def render_event(e, tables):
    """One trajectory line for corpus B."""
    n = f"{e['seq']:>3} "
    if e["event"] in ("INDEX_PATH_GENERATED", "INDEX_PATH_NOT_GENERATED"):
        flags = " ".join(f"{k.split('_', 1)[1] if k.startswith('has_') else k}="
                         f"{'yes' if e[k] else 'no'}" for k, _ in INPUTS)
        what = (f"built {e['npaths']}" if e["event"] == "INDEX_PATH_GENERATED"
                else "not built")
        scope = " bitmap-only" if e["bitmap_only"] else ""
        if e["required_outer"]:
            scope += f" needs outer {e['required_outer']}"
        return f"{n}index {e['index']}{scope}: {what}; inputs {flags}"
    where = rel_name(e, tables)
    if e["event"] == "PRECHECK_REJECTED":
        return (f"{n}{where}: proposed join path cost {e['startup_cost']:.2f}.."
                f"{e['total_cost']:.2f} discarded before construction, "
                f"beaten by {path_desc(e, 'competitor_')}")
    if e["event"] == "ACCEPTED":
        return f"{n}{where}: keep {path_desc(e)}"
    if e["event"] == "REJECTED":
        return (f"{n}{where}: discard {path_desc(e)}, "
                f"beaten by {path_desc(e, 'competitor_')}")
    return (f"{n}{where}: remove {path_desc(e)}, "
            f"replaced by {path_desc(e, 'competitor_')}")


def render_trajectory(rec):
    tables = re.findall(r"\b(?:FROM|JOIN)\s+(\w+)", rec["sql"], re.I)
    return "\n".join(render_event(e, tables) for e in rec["trajectory"])


def query_block(rec, label, with_trace):
    s = f"{label}:\n{rec['sql']}\n\n{label} final plan (EXPLAIN):\n{rec['explain']}"
    if with_trace:
        s += f"\n\n{label} planner trajectory:\n{render_trajectory(rec)}"
    return s


# ---------------------------------------------------------------- answers

def inputs_text(*births):
    have = [t for k, t in INPUTS if any(b[k] for b in births)]
    return " and ".join(have) if len(have) < 3 else \
        ", ".join(have[:-1]) + " and " + have[-1]


def a(word):
    return ("an " if word[0] in "AEIOUaeiou" else "a ") + word


def fate_answer(idx, fate, rec):
    """L0: what happened to the candidates on idx."""
    v = fate["verdict"]
    if v == "CHOSEN":
        return f"A path on {idx} was built and is used in the final plan."
    if v == "NOT_EXAMINED":
        return (f"The planner did not consider {idx} for this query; no "
                "candidate on it existed.")
    if v == "NEVER_GENERATED":
        return (f"No candidate path on {idx} was ever built, so there was "
                "nothing to compare.")
    if v == "GENERATED_NOT_SUBMITTED":
        return (f"Only bitmap-scan candidates on {idx} were built, and none of "
                "them reached the comparison of paths.")
    lost = [p for p in fate["paths"] if p["fate"] != "SURVIVED"]
    parts = []
    for p in lost:
        by = p.get("lost_to") or {}
        verb = "discarded" if p["fate"] == "REJECTED" else "later replaced"
        parts.append(f"{a(p['path_type'])} on {idx} was built and {verb} in favour "
                     f"of {by.get('path_type')}"
                     + (f" on {by['index']}" if by.get("index") else ""))
    if v == "PRUNED":
        return ("Candidates existed and lost where they were compared: "
                + "; ".join(parts) + ".")
    kept = [p for p in fate["paths"] if p["fate"] == "SURVIVED"]
    return (f"Candidates on {idx} were built and {len(kept)} of them were kept "
            "for their relation, but the plan chosen above them does not use "
            "them." + (" Also: " + "; ".join(parts) + "." if parts else ""))


def why_answer(idx, fate, rec, numbers=True):
    """L1: why, from the decision inputs and the compared costs.

    numbers=False drops cost figures: for a query that is not planned in the
    context (L2), exact estimates are not something the answer can require.
    """
    v = fate["verdict"]
    births = fate["births"]
    gen = [b for b in births if b["event"] == "INDEX_PATH_GENERATED"]
    if v == "NOT_EXAMINED":
        idef = next(i["def"] for st in rec["statistics"].values()
                    for i in st["indexes"] if i["name"] == idx)
        if " WHERE " in idef:
            pred = idef.split(" WHERE ", 1)[1].strip()
            if pred.startswith("((") and pred.endswith("))"):
                pred = pred[1:-1]
            return (f"{idx} is a partial index with predicate {pred}; "
                    "the query does not imply that predicate, so the index "
                    "is skipped before any path is built.")
        return f"{idx} is skipped before path construction."
    if v == "NEVER_GENERATED":
        return (f"When the planner decided whether to build a path on {idx}, "
                "none of the reasons to build one held: there was no query "
                "condition usable with the index, no useful sort order, no "
                "implied index predicate, and an index-only scan was not "
                "possible.")
    reason = f"A path on {idx} was built because of {inputs_text(*gen)}."
    ev = {e["seq"]: e for e in rec["trajectory"]}
    if v == "GENERATED_NOT_SUBMITTED":
        return (reason + " It was built for bitmap scans only, and no bitmap "
                "path using it reached the comparison of paths, so it never "
                "competed.")
    if v in ("PRUNED", "SURVIVED_NOT_CHOSEN"):
        lines = []
        for p in fate["paths"]:
            if p["fate"] == "SURVIVED":
                continue
            step = p["events"][-1]
            e = ev[step["seq"]]
            verb = ("was not better than" if step["event"] == "REJECTED"
                    else "was replaced by")
            if numbers:
                lines.append(
                    f"{p['path_type']} estimated at total cost "
                    f"{e['total_cost']:.2f} for {e['rows']:.0f} rows {verb} "
                    f"{e['competitor_path_type']} at "
                    f"{e['competitor_total_cost']:.2f}")
            else:
                lines.append(f"{p['path_type']} {verb} "
                             f"{e['competitor_path_type']}")
        tail = ("; ".join(lines) + ".") if lines else ""
        if v == "PRUNED":
            return reason + " It lost on estimated cost: " + tail
        return (reason + " Its paths were kept for their relation, but the "
                "cheaper plan above them was built from other paths."
                + (" Discarded along the way: " + tail if tail else ""))
    # CHOSEN
    beaten = []
    for e in rec["trajectory"]:
        if e["event"] in ("REJECTED", "DISPLACED") and \
                e.get("competitor_index") == idx:
            loser = e["path_type"] + (f" on {e['index']}" if e.get("index")
                                      else "")
            winner = f"the {e['competitor_path_type']} on {idx}"
            beaten.append(
                f"{loser} at total cost {e['total_cost']:.2f} lost to "
                f"{winner} at {e['competitor_total_cost']:.2f}"
                if numbers else f"{loser} lost to {winner}")
    return reason + (" In the comparisons it won: "
                     + "; ".join(dict.fromkeys(beaten)) + "."
                     if beaten else " Nothing it was compared with beat it.")


def event_words(e):
    if e is None:
        return "no further decision is made"
    idx = f" on {e['index']}" if e.get("index") else ""
    if e["event"] == "INDEX_PATH_GENERATED":
        return (f"a path on {e['index']} is built because of "
                f"{inputs_text(e)}")
    if e["event"] == "INDEX_PATH_NOT_GENERATED":
        return f"no path on {e['index']} is built"
    cidx = (f" on {e['competitor_index']}" if e.get("competitor_index")
            else "")
    if e["event"] == "ACCEPTED":
        return f"{a(e['path_type'])}{idx} path is kept"
    if e["event"] == "REJECTED":
        return (f"{a(e['path_type'])}{idx} path is discarded in favour of "
                f"{e['competitor_path_type']}{cidx}")
    if e["event"] == "DISPLACED":
        return (f"a kept {e['path_type']}{idx} path is replaced by "
                f"{e['competitor_path_type']}{cidx}")
    return (f"a proposed join path is discarded before construction in "
            f"favour of {e['competitor_path_type']}{cidx}")


INPUT_NAMES = {"has_index_clauses": "usable condition",
               "has_useful_pathkeys": "useful order",
               "has_useful_backward_pathkeys": "useful backward order",
               "useful_predicate": "implied predicate",
               "index_only_scan": "index-only scan"}

VERDICT_LINE = ("Start the answer with a line 'Verdict: V', V being one of: "
                + "; ".join(VERDICT_SHORT.values()) + ".")
INPUTS_LINE = ("Then a line 'Inputs: L', L being the reasons a path on the "
               "index was built, from: " + ", ".join(INPUT_NAMES.values())
               + " (comma-separated), or 'none' if no path was built.")
DIVERGENCE_LINE = ("Start the answer with a line 'Divergence: X | Y' giving "
                   "the first differing decision for the first and the second "
                   "query, each as '<index> built', '<index> not built', "
                   "'<PathType>[<index>] kept', '<PathType>[<index>] "
                   "discarded', '<PathType>[<index>] replaced', 'join path "
                   "discarded before construction' or 'end' (omit [<index>] "
                   "for a path without one); or 'Divergence: none'.")
REPAIR_LINE = "Start the answer with a line 'SQL: <the changed query>'."


def gold_inputs(fate):
    gen = [b for b in fate["births"] if b["event"] == "INDEX_PATH_GENERATED"]
    names = [n for k, n in INPUT_NAMES.items() if any(b[k] for b in gen)]
    return names or ["none"]


def divergence_side(e):
    if e is None:
        return "end"
    if e["event"] == "INDEX_PATH_GENERATED":
        return f"{e['index']} built"
    if e["event"] == "INDEX_PATH_NOT_GENERATED":
        return f"{e['index']} not built"
    if e["event"] == "PRECHECK_REJECTED":
        return "join path discarded before construction"
    p = e["path_type"] + (f"[{e['index']}]" if e.get("index") else "")
    return p + " " + {"ACCEPTED": "kept", "REJECTED": "discarded",
                      "DISPLACED": "replaced"}[e["event"]]


def gold_divergence(pair):
    d = pair["first_structural_divergence"]
    if d is None:
        return "none"
    return divergence_side(d["q1_event"]) + " | " + divergence_side(d["q2_event"])


def divergence_answer(pair):
    d = pair["first_structural_divergence"]
    if d is None:
        return ("The planner makes the same decisions for both queries; only "
                "the cost estimates differ.")
    return (f"The first differing decision: for the first query {event_words(d['q1_event'])}; "
            f"for the second {event_words(d['q2_event'])}.")


# ---------------------------------------------------------------- build

def interp_templates(pairs):
    by_t = defaultdict(list)
    for p in pairs.values():
        by_t[p["template"]].append(p)
    return {t for t, ps in by_t.items()
            if len(ps) >= 3 and len({p["q1"] for p in ps}) == len(ps)
            and len({p["q2"] for p in ps}) == len(ps)}


def split_of(rec, fold, interp):
    if rec["family"] == fold:
        return "test_transfer"
    n = int(rec["pair_id"].rsplit(".v", 1)[1])
    if n == 2 and rec["template"] in interp:
        return "test_interp"
    return "train"


def build(raw, out, folds):
    recs = {r["id"]: r for r in load(os.path.join(raw, "noodata.jsonl"))}
    base = {r["id"]: r for r in load(os.path.join(raw, "baseline.jsonl"))}
    fates = {r["id"]: r for r in load(os.path.join(raw, "index_fates.jsonl"))}
    pairs = {p["pair_id"]: p for p in load(os.path.join(raw, "pairs.jsonl"))}
    for qid, r in recs.items():
        assert base[qid]["explain"] == r["explain"]
    vpt = interp_templates(pairs)

    items = []          # questions, context-free: (level, kind, parts, answer)

    def ctx(parts, with_trace):
        blocks = []
        schema_rec = recs[parts[0][1]]
        blocks.append("Schema and statistics:\n" + render_schema(schema_rec))
        for kind, qid, label in parts:
            if kind == "full":
                blocks.append(query_block(recs[qid], label, with_trace))
            else:
                blocks.append(f"{label} (not planned):\n{recs[qid]['sql']}")
        return "\n\n".join(blocks)

    for pid, p in pairs.items():
        focus = p["focus"]
        q1, q2 = f"{pid}.q1", f"{pid}.q2"
        f1 = fates[q1]["indexes"][focus]
        f2 = fates[q2]["indexes"][focus]
        meta = {"pair_id": pid, "template": p["template"],
                "family": p["family"], "focus": focus,
                "pair_split": p["split"]}

        for qid, f in ((q1, f1), (q2, f2)):
            parts = [("full", qid, "Query")]
            items.append({**meta, "id": f"{qid}:L0:fate", "level": "L0",
                          "kind": "fate", "parts": parts,
                          "question": f"What happened to candidate paths on "
                                      f"index {focus} while this query was "
                                      "planned? Did a candidate exist and "
                                      "lose, or did none exist?",
                          "answer": fate_answer(focus, f, recs[qid]),
                          "answer_short": VERDICT_SHORT[f["verdict"]],
                          "verdict": f["verdict"]})
            items.append({**meta, "id": f"{qid}:L1:why", "level": "L1",
                          "kind": "why", "parts": parts,
                          "question": f"Why did index {focus} end up this way "
                                      "for this query?",
                          "answer": why_answer(focus, f, recs[qid]),
                          "answer_short": VERDICT_SHORT[f["verdict"]],
                          "verdict": f["verdict"]})

        both = [("full", q1, "Query 1"), ("full", q2, "Query 2")]
        d = p["first_structural_divergence"]
        items.append({**meta, "id": f"{pid}:L0:divergence", "level": "L0",
                      "kind": "divergence", "parts": both,
                      "question": "Where do the planner's decisions for the "
                                  "two queries first differ?",
                      "answer": divergence_answer(p),
                      "answer_short": None if d is None else
                      [d["q1_event"] and d["q1_event"]["event"],
                       d["q2_event"] and d["q2_event"]["event"]],
                      "divergence_position": None if d is None else
                      d["position"]})
        items.append({**meta, "id": f"{pid}:L1:difference", "level": "L1",
                      "kind": "difference", "parts": both,
                      "question": "What single difference between the two "
                                  "queries is responsible for that?",
                      "answer": p["diff"][0].upper() + p["diff"][1:] + ".",
                      "answer_short": p["diff"]})

        for src, dst, fsrc, fdst in ((q1, q2, f1, f2), (q2, q1, f2, f1)):
            parts = [("full", src, "Query"), ("sql", dst, "Changed query")]
            items.append({**meta, "id": f"{src}:L2:predict", "level": "L2",
                          "kind": "predict", "parts": parts,
                          "question": f"If the query is changed as shown, "
                                      f"what will happen to candidate paths "
                                      f"on {focus}, and why?",
                          "answer": fate_answer(focus, fdst, recs[dst]) + " "
                          + why_answer(focus, fdst, recs[dst], numbers=False),
                          "answer_short": VERDICT_SHORT[fdst["verdict"]],
                          "verdict": fdst["verdict"],
                          "verdict_before": fsrc["verdict"]})
        dd = divergence_answer(p)
        items.append({**meta, "id": f"{q1}:L2:divergence", "level": "L2",
                      "kind": "predict_divergence",
                      "parts": [("full", q1, "Query"),
                                ("sql", q2, "Changed query")],
                      "question": "Where will the planner's decisions for the "
                                  "changed query first differ from those for "
                                  "the original one?",
                      "answer": dd.replace("the first query", "the original "
                                           "query").replace("the second",
                                                            "the changed one"),
                      "answer_short": None if d is None else
                      [d["q1_event"] and d["q1_event"]["event"],
                       d["q2_event"] and d["q2_event"]["event"]],
                      "divergence_position": None if d is None else
                      d["position"]})

        r1, r2 = VERDICT_RANK.index(f1["verdict"]), VERDICT_RANK.index(f2["verdict"])
        if r1 != r2 and max(r1, r2) == VERDICT_RANK.index("CHOSEN"):
            weak, strong, fs = (q2, q1, f1) if r1 > r2 else (q1, q2, f2)
            items.append({**meta, "id": f"{weak}:L2:repair", "level": "L2",
                          "kind": "repair",
                          "parts": [("full", weak, "Query")],
                          "question": f"What single change to this query "
                                      f"would make the planner use index "
                                      f"{focus}? Give the changed query.",
                          "answer": f"For example: {recs[strong]['sql']} . "
                          + why_answer(focus, fs, recs[strong], numbers=False),
                          "answer_short": recs[strong]["sql"],
                          "reference_sql": recs[strong]["sql"],
                          "grading": "execute: plan the proposed SQL and "
                                     f"check that {focus} is in the final plan"})

    # A scored header on the first lines of every answer, and the matching
    # format instruction in every question, identical for A, B and a base
    # model evaluated zero-shot.
    for it in items:
        k = it["kind"]
        if k in ("fate", "why", "predict"):
            qid = it["parts"][1][1] if k == "predict" else it["parts"][0][1]
            fate = fates[qid]["indexes"][it["focus"]]
            it["gold"] = {"verdict": VERDICT_SHORT[fate["verdict"]],
                          "inputs": gold_inputs(fate)}
            head = f"Verdict: {it['gold']['verdict']}\n"
            fmt = VERDICT_LINE
            if k != "fate":
                head += "Inputs: " + ", ".join(it["gold"]["inputs"]) + "\n"
                fmt += " " + INPUTS_LINE
        elif k in ("divergence", "predict_divergence"):
            it["gold"] = {"divergence": gold_divergence(pairs[it["pair_id"]])}
            head = f"Divergence: {it['gold']['divergence']}\n"
            fmt = DIVERGENCE_LINE
        elif k == "repair":
            it["gold"] = {"sql": it["reference_sql"]}
            head = f"SQL: {it['reference_sql']}\n"
            fmt = REPAIR_LINE
            it["answer"] = it["answer"].replace(
                f"For example: {it['reference_sql']} . ", "")
        else:
            it["gold"] = None
            head, fmt = "", ""
        it["answer"] = head + it["answer"]
        if fmt:
            it["question"] += " " + fmt

    for it in items:
        for tok in FORBIDDEN:
            assert tok not in it["answer"], (it["id"], tok, it["answer"])

    os.makedirs(out, exist_ok=True)
    manifest = {"raw": os.path.basename(os.path.normpath(raw)),
                "items": len(items),
                "by_level": Counter(i["level"] for i in items),
                "by_kind": Counter(i["kind"] for i in items), "folds": {}}
    for fold in folds:
        fdir = os.path.join(out, f"fold-{fold}")
        os.makedirs(fdir, exist_ok=True)
        counts = defaultdict(Counter)
        files = {}
        for it in items:
            split = split_of({**recs[it["parts"][0][1]], "pair_id":
                              it["pair_id"], "template": it["template"],
                              "family": it["family"]}, fold, vpt)
            for corpus, trace in (("A", False), ("B", True)):
                key = (corpus, split)
                if key not in files:
                    files[key] = open(os.path.join(
                        fdir, f"corpus_{corpus}.{split}.jsonl"), "w")
                rec = {"id": it["id"], "level": it["level"],
                       "kind": it["kind"], "split": split,
                       "messages": [
                           {"role": "user",
                            "content": ctx(it["parts"], trace) + "\n\nQuestion: "
                            + it["question"]},
                           {"role": "assistant", "content": it["answer"]}],
                       "meta": {k: v for k, v in it.items()
                                if k not in ("parts", "question", "answer")}}
                files[key].write(json.dumps(rec) + "\n")
                if corpus == "A":
                    counts[split][it["level"]] += 1
        for f in files.values():
            f.close()
        manifest["folds"][fold] = {s: dict(c) for s, c in counts.items()}
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    return items, recs, pairs, fates


def human_eval(items, recs, fates, fold, out, vpt):
    """30-50 hand-checkable cases from the test splits of one fold.

    Chosen by rule, not by hand: every PRUNED/NEVER_GENERATED fate question
    whose final plan has no index on the focus, then first-divergence and
    counterfactual questions spread over templates.
    """
    def split(it):
        r = recs[it["parts"][0][1]]
        return split_of({**r, "pair_id": it["pair_id"],
                         "template": it["template"],
                         "family": it["family"]}, fold, vpt)

    test = [it for it in items if split(it) != "train"]
    picked = []

    def take(pred, limit):
        seen_t = Counter()
        for it in test:
            if len([p for p in picked if pred(p)]) >= limit:
                break
            if it in picked or not pred(it) or seen_t[it["template"]] >= 2:
                continue
            seen_t[it["template"]] += 1
            picked.append(it)

    def kind(k, extra=lambda it: True):
        return lambda it: it["kind"] == k and extra(it)

    def in_split(pred, sp):
        return lambda it: pred(it) and split(it) == sp

    # "existed and lost" and "never existed", in equal numbers
    lost = kind("fate", lambda it: it["verdict"] in (
        "PRUNED", "SURVIVED_NOT_CHOSEN", "GENERATED_NOT_SUBMITTED"))
    unborn = kind("fate", lambda it: it["verdict"] in (
        "NEVER_GENERATED", "NOT_EXAMINED"))
    changed = kind("predict", lambda it: it["verdict"] != it["verdict_before"])
    # transfer cases first: L2 on the held-out family is the main question
    for pred, n_transfer, n_total in ((lost, 2, 7), (unborn, 2, 7),
                                      (kind("predict_divergence"), 5, 10),
                                      (changed, 5, 10),
                                      (kind("repair"), 3, 6)):
        take(in_split(pred, "test_transfer"), n_transfer)
        before = len([p for p in picked if pred(p)])
        take(in_split(pred, "test_interp"), n_total - before)

    def evidence(qid, focus):
        tables = re.findall(r"\b(?:FROM|JOIN)\s+(\w+)", recs[qid]["sql"], re.I)
        return [render_event(e, tables) for e in recs[qid]["trajectory"]
                if e.get("index") == focus or
                e.get("competitor_index") == focus]

    md = [f"# NooData human eval (fold {fold})", "",
          f"{len(picked)} cases from test_interp/test_transfer. Reference "
          "answers are derived from the trace; 'evidence' lists the "
          "trajectory lines about the focus index. Repair answers are graded "
          "by planning the proposed SQL, not by string match.", ""]
    with open(os.path.join(out, f"eval_human.{fold}.jsonl"), "w") as f:
        for n, it in enumerate(picked, 1):
            sp = split(it)
            md.append(f"## {n}. {it['id']} — {it['level']} {it['kind']} "
                      f"({sp}, family {it['family']})")
            md.append("")
            for kind, qid, label in it["parts"]:
                md.append(f"**{label}**" + (" (not planned)" if kind == "sql"
                                            else "") + ":")
                md.append("```sql\n" + recs[qid]["sql"] + "\n```")
                if kind == "full":
                    md.append("```text\n" + recs[qid]["explain"] + "\n```")
            md.append(f"**Question:** {it['question']}")
            md.append("")
            md.append(f"**Reference:** {it['answer']}")
            md.append("")
            ev = {}
            for kind, qid, label in it["parts"]:
                ev[qid] = evidence(qid, it["focus"])
            if it["kind"] in ("predict", "predict_divergence", "repair"):
                other = it["pair_id"] + (".q2" if it["id"].startswith(
                    it["pair_id"] + ".q1") else ".q1")
                ev[other] = evidence(other, it["focus"])
            for qid, lines in ev.items():
                md.append(f"Evidence {qid}:")
                md.append("```text\n" + ("\n".join(lines) or "(no events "
                          "about the focus index)") + "\n```")
            md.append("")
            f.write(json.dumps({"n": n, "id": it["id"], "split": sp,
                                "level": it["level"], "kind": it["kind"],
                                "family": it["family"],
                                "question": it["question"],
                                "reference": it["answer"],
                                "answer_short": it.get("answer_short"),
                                "evidence": ev}) + "\n")
    with open(os.path.join(out, f"eval_human.{fold}.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    return picked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("raw")
    ap.add_argument("out")
    ap.add_argument("--fold", action="append", required=True)
    ap.add_argument("--human-fold", help="fold for eval_human.*")
    args = ap.parse_args()
    items, recs, pairs, fates = build(args.raw, args.out, args.fold)
    if args.human_fold:
        vpt = interp_templates(pairs)
        picked = human_eval(items, recs, fates, args.human_fold, args.out, vpt)
        print(f"human eval: {len(picked)} cases, "
              f"{dict(Counter(p['kind'] for p in picked))}")
    with open(os.path.join(args.out, "manifest.json")) as f:
        print(f.read())


if __name__ == "__main__":
    main()
