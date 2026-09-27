# Planner injection points for path pruning

Instrumentation only: the points observe planner decisions, they do not
change them.

## Problem

EXPLAIN shows the plan that survived.  It does not show why an alternative
Path is absent, and the possible fates are different in kind:

```text
generated
   |
   +--> rejected by add_path_precheck()   (before a Path object exists)
   |
   +--> rejected by add_path()            (dominated by a surviving Path)
   |
   +--> accepted
          |
          +--> displaces another Path     (the older one leaves the list)
```

A surviving Path produces no event at all, so the deaths alone cannot tell
"pruned early" from "survived and lost later".  That is why acceptance is
reported too.

One more distinction matters and is invisible at add_path(): a candidate
that was never built.  When an index does not appear in a plan,

```text
IndexPath was generated        (and then lost, somewhere)
IndexPath was never generated  (no usable clause, no useful order, ...)
```

are different problems for the user, and add_path() cannot tell them apart,
because it only ever sees paths that exist.

## Patch series

    0001-planner-add-injection-points-for-path-pruning.patch

Four points in `optimizer/util/pathnode.c`:
`planner-add-path-accept`, `planner-add-path-reject`,
`planner-add-path-displace`, `planner-add-path-precheck-reject`.  Payload
structs `PlannerPathComparisonInjectionData` and
`PlannerPathPrecheckInjectionData` in `optimizer/pathnode.h`.  Each point
fires while the Path it describes is still live, before the list cell is
deleted and before `pfree()`.  The precheck payload describes the proposed
path by its properties, because no Path exists at that boundary.  The points
are loaded once per planner invocation with `INJECTION_POINT_LOAD` in
`planner()`, before `planner_hook` is consulted, and consulted through the
process-local cache.

    0002-injection_points-add-planner-path-prune-notice-actio.patch

A `path-prune-notice` action in the existing `injection_points` test module
that understands those payloads and prints one NOTICE per event, plus a TAP
test asserting structural facts only (not costs).  The existing `notice`
action would print garbage for a typed payload.

    ../noodata/0003-planner-add-injection-points-for-index-path-generati.patch

Two points at the end of `build_index_paths()`:
`planner-index-path-generated`, `planner-index-path-not-generated`, with
`PlannerIndexPathInjectionData` in `optimizer/paths.h`.  The payload carries
the inputs of the build decision (index clauses, useful order forward and
backward, useful predicate, index-only scan), so "not generated" comes with
its reason instead of being inferred from a missing Path.  Every IndexPath
built while planning a query comes from this function.  Indexes skipped
before the decision (unproven partial index predicate, scan type not
supported, `amoptionalkey` without a leading-column clause, OR arms with no
matching clause) produce no event: a consumer must read that as "not
examined", not as "not generated".

`0001` + `0002` are the upstream candidate; the cover letter for them is in
`0000-cover-letter.txt`, review notes in `NOTES-v3.md`, and a runnable demo
in `demo/`.  `0003` is a separate follow-up and can be discussed
independently of them.

## Invariant

Payload structs and point calls exist only under `USE_INJECTION_POINTS`; a
build without `--enable-injection-points` compiles none of them and the
planner is unchanged.  This was checked, not assumed, in two ways: a
production build without injection points, and EXPLAIN (with costs) of 54
queries compared between unpatched master, the patched build with nothing
attached, and the patched build with all points attached and tracing on —
identical in all three.

## Status

```text
PostgreSQL base:                c62b330 (master, 20devel)
reconstructed PostgreSQL HEAD:  b9c5d58
research branch:                r2d2/noodata-v0 (this repository)
```

Reproduce the tree:

```sh
git clone https://git.postgresql.org/git/postgresql.git pg && cd pg
git checkout -b planner-injection-points c62b330
R=<this repo>/experiments/ch08-path-probe
git am $R/hackers/0001-*.patch $R/hackers/0002-*.patch $R/noodata/0003-*.patch
./configure --enable-injection-points --enable-tap-tests --enable-cassert
make && make -C src/test/modules/injection_points check
```

The patch files are generated against `c62b330` and apply with plain
`git am`; the resulting tree is identical to `b9c5d58`, which is how the
repository stays the canonical source now that the PostgreSQL tree is gone.

The points are used by the trajectory experiment in `../noodata/`, which is
a consumer of this instrumentation, not part of it.
