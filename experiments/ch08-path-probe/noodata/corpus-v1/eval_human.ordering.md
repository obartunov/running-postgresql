# NooData human eval (fold ordering)

40 cases from test_interp/test_transfer. Reference answers are derived from the trace; 'evidence' lists the trajectory lines about the focus index. Repair answers are graded by planning the proposed SQL, not by string match.

## 1. P27.v0.q1:L0:fate — L0 fate (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t WHERE s = 19 ORDER BY a LIMIT 10
```
```text
Limit  (cost=8.31..8.32 rows=1 width=28)
  ->  Sort  (cost=8.31..8.32 rows=1 width=28)
        Sort Key: a
        ->  Index Scan using t_s_idx on t  (cost=0.29..8.30 rows=1 width=28)
              Index Cond: (s = 19)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built, kept in its relation, not used above it
Candidates on t_a_idx were built and 1 of them were kept for their relation, but the plan chosen above them does not use them.

Evidence P27.v0.q1:
```text
  9 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
 10 scan of t: keep IndexScan#4[t_a_idx] cost 0.29..1142.29 rows 1 (order v1.2 ASC)
 14 result level 2: keep IndexScan#4[t_a_idx] cost 0.29..1142.29 rows 1 (order v1.2 ASC)
```

## 2. P27.v1.q1:L0:fate — L0 fate (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t WHERE s = 1009 ORDER BY a LIMIT 20
```
```text
Limit  (cost=8.31..8.32 rows=1 width=28)
  ->  Sort  (cost=8.31..8.32 rows=1 width=28)
        Sort Key: a
        ->  Index Scan using t_s_idx on t  (cost=0.29..8.30 rows=1 width=28)
              Index Cond: (s = 1009)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built, kept in its relation, not used above it
Candidates on t_a_idx were built and 1 of them were kept for their relation, but the plan chosen above them does not use them.

Evidence P27.v1.q1:
```text
  9 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
 10 scan of t: keep IndexScan#4[t_a_idx] cost 0.29..1142.29 rows 1 (order v1.2 ASC)
 14 result level 2: keep IndexScan#4[t_a_idx] cost 0.29..1142.29 rows 1 (order v1.2 ASC)
```

## 3. P02.v2.q2:L0:fate — L0 fate (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 8000
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=15202 width=28)
  Filter: ((a >= 400) AND (a <= 8000))
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built, lost in its relation
Candidates existed and lost where they were compared: an IndexScan on t_a_idx was built and discarded in favour of SeqScan; a BitmapHeapScan on t_a_idx was built and discarded in favour of SeqScan.

Evidence P02.v2.q2:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: discard IndexScan#2[t_a_idx] cost 0.29..1048.33 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
  9 scan of t: discard BitmapHeapScan#3[t_a_idx] cost 312.11..687.14 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
```

## 4. P03.v2.q2:L0:fate — L0 fate (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE b < 95
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=19000 width=28)
  Filter: (b < 95)
```
**Question:** What happened to candidate paths on index t_b_c_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built, lost in its relation
Candidates existed and lost where they were compared: an IndexScan on t_b_c_idx was built and discarded in favour of SeqScan; a BitmapHeapScan on t_b_c_idx was built and discarded in favour of SeqScan.

Evidence P03.v2.q2:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..1000.73 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
  9 scan of t: discard BitmapHeapScan#3[t_b_c_idx] cost 227.54..612.04 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
```

## 5. P08.v2.q1:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE c LIKE 'c8%'
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=2182 width=28)
  Filter: (c ~~ 'c8%'::text)
```
**Question:** What happened to candidate paths on index t_b_c_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built, lost in its relation
Candidates existed and lost where they were compared: an IndexScan on t_b_c_idx was built and discarded in favour of SeqScan; a BitmapHeapScan on t_b_c_idx was built and discarded in favour of SeqScan.

Evidence P08.v2.q1:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..899.22 rows 2182, beaten by SeqScan#1 cost 0.00..397.00 rows 2182
  9 scan of t: discard BitmapHeapScan#3[t_b_c_idx] cost 284.83..458.83 rows 2182, beaten by SeqScan#1 cost 0.00..397.00 rows 2182
```

## 6. P10.v2.q2:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a = 5000 OR d = 60
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=208 width=28)
  Filter: ((a = 5000) OR (d = 60))
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built for bitmap scans only, never compared
Only bitmap-scan candidates on t_a_idx were built, and none of them reached the comparison of paths.

Evidence P10.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  8 index t_a_idx bitmap-only: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 7. P20.v2.q1:L0:fate — L0 fate (test_interp, family index_only)

**Query**:
```sql
SELECT s FROM t
```
```text
Seq Scan on t  (cost=0.00..347.00 rows=20000 width=4)
```
**Question:** What happened to candidate paths on index t_s_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: built, lost in its relation
Candidates existed and lost where they were compared: an IndexOnlyScan on t_s_idx was built and discarded in favour of SeqScan; a BitmapHeapScan on t_s_idx was built and discarded in favour of SeqScan.

Evidence P20.v2.q1:
```text
  5 index t_s_idx: built 1; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=yes
  6 scan of t: discard IndexOnlyScan#2[t_s_idx] cost 0.29..388.29 rows 20000, beaten by SeqScan#1 cost 0.00..347.00 rows 20000
  9 scan of t: discard BitmapHeapScan#3[t_s_idx] cost 193.29..540.29 rows 20000, beaten by SeqScan#1 cost 0.00..347.00 rows 20000
```

## 8. P13.v0.q2:L0:fate — L0 fate (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY d LIMIT 10
```
```text
Limit  (cost=779.19..779.22 rows=10 width=28)
  ->  Sort  (cost=779.19..829.19 rows=20000 width=28)
        Sort Key: d
        ->  Seq Scan on t  (cost=0.00..347.00 rows=20000 width=28)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_a_idx was ever built, so there was nothing to compare.

Evidence P13.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 9. P13.v1.q2:L0:fate — L0 fate (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY d LIMIT 3
```
```text
Limit  (cost=605.50..605.50 rows=3 width=28)
  ->  Sort  (cost=605.50..655.50 rows=20000 width=28)
        Sort Key: d
        ->  Seq Scan on t  (cost=0.00..347.00 rows=20000 width=28)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_a_idx was ever built, so there was nothing to compare.

Evidence P13.v1.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 10. P04.v2.q2:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a + 0 = 999
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=100 width=28)
  Filter: ((a + 0) = 999)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_a_idx was ever built, so there was nothing to compare.

Evidence P04.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 11. P05.v2.q2:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a::numeric = 999
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=100 width=28)
  Filter: ((a)::numeric = '999'::numeric)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_a_idx was ever built, so there was nothing to compare.

Evidence P05.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 12. P06.v2.q2:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a <> 999
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=19998 width=28)
  Filter: (a <> 999)
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_a_idx was ever built, so there was nothing to compare.

Evidence P06.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 13. P08.v2.q2:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE c LIKE '%c8'
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=2 width=28)
  Filter: (c ~~ '%c8'::text)
```
**Question:** What happened to candidate paths on index t_b_c_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_b_c_idx was ever built, so there was nothing to compare.

Evidence P08.v2.q2:
```text
  4 index t_b_c_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 14. P11.v2.q2:L0:fate — L0 fate (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a NOT IN (5000, 6000)
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=19996 width=28)
  Filter: (a <> ALL ('{5000,6000}'::integer[]))
```
**Question:** What happened to candidate paths on index t_a_idx while this query was planned? Did a candidate exist and lose, or did none exist? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered.

**Reference:** Verdict: never built
No candidate path on t_a_idx was ever built, so there was nothing to compare.

Evidence P11.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 15. P13.v0.q1:L2:divergence — L2 predict_divergence (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
```text
Limit  (cost=0.29..0.83 rows=10 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY d LIMIT 10
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a useful sort order; for the changed one no path on t_a_idx is built.

Evidence P13.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```
Evidence P13.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 16. P13.v1.q1:L2:divergence — L2 predict_divergence (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a LIMIT 3
```
```text
Limit  (cost=0.29..0.45 rows=3 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY d LIMIT 3
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a useful sort order; for the changed one no path on t_a_idx is built.

Evidence P13.v1.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```
Evidence P13.v1.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 17. P14.v0.q1:L2:divergence — L2 predict_divergence (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
```text
Limit  (cost=0.29..0.83 rows=10 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY a + 0 LIMIT 10
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a useful sort order; for the changed one no path on t_a_idx is built.

Evidence P14.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```
Evidence P14.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 18. P14.v1.q1:L2:divergence — L2 predict_divergence (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a LIMIT 3
```
```text
Limit  (cost=0.29..0.45 rows=3 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY a + 0 LIMIT 3
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a useful sort order; for the changed one no path on t_a_idx is built.

Evidence P14.v1.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```
Evidence P14.v1.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 19. P15.v0.q1:L2:divergence — L2 predict_divergence (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a DESC LIMIT 10
```
```text
Limit  (cost=0.29..0.83 rows=10 width=28)
  ->  Index Scan Backward using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx built
The first differing decision: for the original query a path on t_a_idx is built because of a useful sort order when scanned backward; for the changed one a path on t_a_idx is built because of a useful sort order.

Evidence P15.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=yes useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 DESC NULLS FIRST)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 DESC NULLS FIRST)
```
Evidence P15.v0.q2:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```

## 20. P02.v2.q1:L2:divergence — L2 predict_divergence (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 415
```
```text
Bitmap Heap Scan on t  (cost=4.62..82.45 rows=32 width=28)
  Recheck Cond: ((a >= 400) AND (a <= 415))
  ->  Bitmap Index Scan on t_a_idx  (cost=0.00..4.61 rows=32 width=0)
        Index Cond: ((a >= 400) AND (a <= 415))
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 8000
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: SeqScan replaced | IndexScan[t_a_idx] discarded
The first differing decision: for the original query a kept SeqScan path is replaced by IndexScan on t_a_idx; for the changed one an IndexScan on t_a_idx path is discarded in favour of SeqScan.

Evidence P02.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..447.00 rows 32, replaced by IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32, replaced by BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
```
Evidence P02.v2.q2:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: discard IndexScan#2[t_a_idx] cost 0.29..1048.33 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
  9 scan of t: discard BitmapHeapScan#3[t_a_idx] cost 312.11..687.14 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
```

## 21. P03.v2.q1:L2:divergence — L2 predict_divergence (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE b = 77
```
```text
Bitmap Heap Scan on t  (cost=5.84..163.07 rows=200 width=28)
  Recheck Cond: (b = 77)
  ->  Bitmap Index Scan on t_b_c_idx  (cost=0.00..5.79 rows=200 width=0)
        Index Cond: (b = 77)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE b < 95
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: SeqScan replaced | BitmapHeapScan[t_b_c_idx] discarded
The first differing decision: for the original query a kept SeqScan path is replaced by BitmapHeapScan on t_b_c_idx; for the changed one a BitmapHeapScan on t_b_c_idx path is discarded in favour of SeqScan.

Evidence P03.v2.q1:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..487.73 rows 200, beaten by SeqScan#1 cost 0.00..397.00 rows 200
  9 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 200, replaced by BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 10 scan of t: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 11 result level 2: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
```
Evidence P03.v2.q2:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..1000.73 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
  9 scan of t: discard BitmapHeapScan#3[t_b_c_idx] cost 227.54..612.04 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
```

## 22. P04.v2.q1:L2:divergence — L2 predict_divergence (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a = 999
```
```text
Bitmap Heap Scan on t  (cost=4.30..11.63 rows=2 width=28)
  Recheck Cond: (a = 999)
  ->  Bitmap Index Scan on t_a_idx  (cost=0.00..4.30 rows=2 width=0)
        Index Cond: (a = 999)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a + 0 = 999
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a query condition usable with the index; for the changed one no path on t_a_idx is built.

Evidence P04.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 2, replaced by IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2, replaced by BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
```
Evidence P04.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 23. P05.v2.q1:L2:divergence — L2 predict_divergence (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a = 999
```
```text
Bitmap Heap Scan on t  (cost=4.30..11.63 rows=2 width=28)
  Recheck Cond: (a = 999)
  ->  Bitmap Index Scan on t_a_idx  (cost=0.00..4.30 rows=2 width=0)
        Index Cond: (a = 999)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a::numeric = 999
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a query condition usable with the index; for the changed one no path on t_a_idx is built.

Evidence P05.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 2, replaced by IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2, replaced by BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
```
Evidence P05.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 24. P06.v2.q1:L2:divergence — L2 predict_divergence (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a = 999
```
```text
Bitmap Heap Scan on t  (cost=4.30..11.63 rows=2 width=28)
  Recheck Cond: (a = 999)
  ->  Bitmap Index Scan on t_a_idx  (cost=0.00..4.30 rows=2 width=0)
        Index Cond: (a = 999)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a <> 999
```
**Question:** Where will the planner's decisions for the changed query first differ from those for the original one? Start the answer with a line 'Divergence: X | Y' giving the first differing decision for the first and the second query, each as '<index> built', '<index> not built', '<PathType>[<index>] kept', '<PathType>[<index>] discarded', '<PathType>[<index>] replaced', 'join path discarded before construction' or 'end' (omit [<index>] for a path without one); or 'Divergence: none'.

**Reference:** Divergence: t_a_idx built | t_a_idx not built
The first differing decision: for the original query a path on t_a_idx is built because of a query condition usable with the index; for the changed one no path on t_a_idx is built.

Evidence P06.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 2, replaced by IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2, replaced by BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
```
Evidence P06.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 25. P13.v0.q1:L2:predict — L2 predict (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
```text
Limit  (cost=0.29..0.83 rows=10 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY d LIMIT 10
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: never built
Inputs: none
No candidate path on t_a_idx was ever built, so there was nothing to compare. When the planner decided whether to build a path on t_a_idx, none of the reasons to build one held: there was no query condition usable with the index, no useful sort order, no implied index predicate, and an index-only scan was not possible.

Evidence P13.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```
Evidence P13.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 26. P13.v0.q2:L2:predict — L2 predict (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY d LIMIT 10
```
```text
Limit  (cost=779.19..779.22 rows=10 width=28)
  ->  Sort  (cost=779.19..829.19 rows=20000 width=28)
        Sort Key: d
        ->  Seq Scan on t  (cost=0.00..347.00 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: used in the final plan
Inputs: useful order
A path on t_a_idx was built and is used in the final plan. A path on t_a_idx was built because of a useful sort order. Nothing it was compared with beat it.

Evidence P13.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```
Evidence P13.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```

## 27. P14.v0.q1:L2:predict — L2 predict (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
```text
Limit  (cost=0.29..0.83 rows=10 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1092.29 rows=20000 width=28)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY a + 0 LIMIT 10
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: never built
Inputs: none
No candidate path on t_a_idx was ever built, so there was nothing to compare. When the planner decided whether to build a path on t_a_idx, none of the reasons to build one held: there was no query condition usable with the index, no useful sort order, no implied index predicate, and an index-only scan was not possible.

Evidence P14.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```
Evidence P14.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 28. P14.v0.q2:L2:predict — L2 predict (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a + 0 LIMIT 10
```
```text
Limit  (cost=829.19..829.22 rows=10 width=32)
  ->  Sort  (cost=829.19..879.19 rows=20000 width=32)
        Sort Key: ((a + 0))
        ->  Seq Scan on t  (cost=0.00..397.00 rows=20000 width=32)
```
**Changed query** (not planned):
```sql
SELECT * FROM t ORDER BY a LIMIT 10
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: used in the final plan
Inputs: useful order
A path on t_a_idx was built and is used in the final plan. A path on t_a_idx was built because of a useful sort order. Nothing it was compared with beat it.

Evidence P14.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```
Evidence P14.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```

## 29. P26.v0.q1:L2:predict — L2 predict (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t WHERE b = 5 ORDER BY a LIMIT 10
```
```text
Limit  (cost=0.29..57.39 rows=10 width=28)
  ->  Index Scan using t_a_idx on t  (cost=0.29..1142.29 rows=200 width=28)
        Filter: (b = 5)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE b = 5 ORDER BY a + 0 LIMIT 10
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: never built
Inputs: none
No candidate path on t_a_idx was ever built, so there was nothing to compare. When the planner decided whether to build a path on t_a_idx, none of the reasons to build one held: there was no query condition usable with the index, no useful sort order, no implied index predicate, and an index-only scan was not possible.

Evidence P26.v0.q1:
```text
  7 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  8 scan of t: keep IndexScan#3[t_a_idx] cost 0.29..1142.29 rows 200 (order v1.2 ASC)
 12 result level 2: keep IndexScan#3[t_a_idx] cost 0.29..1142.29 rows 200 (order v1.2 ASC)
```
Evidence P26.v0.q2:
```text
  7 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 30. P02.v2.q1:L2:predict — L2 predict (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 415
```
```text
Bitmap Heap Scan on t  (cost=4.62..82.45 rows=32 width=28)
  Recheck Cond: ((a >= 400) AND (a <= 415))
  ->  Bitmap Index Scan on t_a_idx  (cost=0.00..4.61 rows=32 width=0)
        Index Cond: ((a >= 400) AND (a <= 415))
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 8000
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: built, lost in its relation
Inputs: usable condition
Candidates existed and lost where they were compared: an IndexScan on t_a_idx was built and discarded in favour of SeqScan; a BitmapHeapScan on t_a_idx was built and discarded in favour of SeqScan. A path on t_a_idx was built because of a query condition usable with the index. It lost on estimated cost: IndexScan was not better than SeqScan; BitmapHeapScan was not better than SeqScan.

Evidence P02.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..447.00 rows 32, replaced by IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32, replaced by BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
```
Evidence P02.v2.q2:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: discard IndexScan#2[t_a_idx] cost 0.29..1048.33 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
  9 scan of t: discard BitmapHeapScan#3[t_a_idx] cost 312.11..687.14 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
```

## 31. P02.v2.q2:L2:predict — L2 predict (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 8000
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=15202 width=28)
  Filter: ((a >= 400) AND (a <= 8000))
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 415
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: used in the final plan
Inputs: usable condition
A path on t_a_idx was built and is used in the final plan. A path on t_a_idx was built because of a query condition usable with the index. In the comparisons it won: SeqScan lost to the IndexScan on t_a_idx; IndexScan on t_a_idx lost to the BitmapHeapScan on t_a_idx.

Evidence P02.v2.q2:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: discard IndexScan#2[t_a_idx] cost 0.29..1048.33 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
  9 scan of t: discard BitmapHeapScan#3[t_a_idx] cost 312.11..687.14 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
```
Evidence P02.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..447.00 rows 32, replaced by IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32, replaced by BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
```

## 32. P03.v2.q1:L2:predict — L2 predict (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE b = 77
```
```text
Bitmap Heap Scan on t  (cost=5.84..163.07 rows=200 width=28)
  Recheck Cond: (b = 77)
  ->  Bitmap Index Scan on t_b_c_idx  (cost=0.00..5.79 rows=200 width=0)
        Index Cond: (b = 77)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE b < 95
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_b_c_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: built, lost in its relation
Inputs: usable condition
Candidates existed and lost where they were compared: an IndexScan on t_b_c_idx was built and discarded in favour of SeqScan; a BitmapHeapScan on t_b_c_idx was built and discarded in favour of SeqScan. A path on t_b_c_idx was built because of a query condition usable with the index. It lost on estimated cost: IndexScan was not better than SeqScan; BitmapHeapScan was not better than SeqScan.

Evidence P03.v2.q1:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..487.73 rows 200, beaten by SeqScan#1 cost 0.00..397.00 rows 200
  9 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 200, replaced by BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 10 scan of t: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 11 result level 2: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
```
Evidence P03.v2.q2:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..1000.73 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
  9 scan of t: discard BitmapHeapScan#3[t_b_c_idx] cost 227.54..612.04 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
```

## 33. P03.v2.q2:L2:predict — L2 predict (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE b < 95
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=19000 width=28)
  Filter: (b < 95)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE b = 77
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_b_c_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: used in the final plan
Inputs: usable condition
A path on t_b_c_idx was built and is used in the final plan. A path on t_b_c_idx was built because of a query condition usable with the index. In the comparisons it won: SeqScan lost to the BitmapHeapScan on t_b_c_idx.

Evidence P03.v2.q2:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..1000.73 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
  9 scan of t: discard BitmapHeapScan#3[t_b_c_idx] cost 227.54..612.04 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
```
Evidence P03.v2.q1:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..487.73 rows 200, beaten by SeqScan#1 cost 0.00..397.00 rows 200
  9 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 200, replaced by BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 10 scan of t: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 11 result level 2: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
```

## 34. P04.v2.q1:L2:predict — L2 predict (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a = 999
```
```text
Bitmap Heap Scan on t  (cost=4.30..11.63 rows=2 width=28)
  Recheck Cond: (a = 999)
  ->  Bitmap Index Scan on t_a_idx  (cost=0.00..4.30 rows=2 width=0)
        Index Cond: (a = 999)
```
**Changed query** (not planned):
```sql
SELECT * FROM t WHERE a + 0 = 999
```
**Question:** If the query is changed as shown, what will happen to candidate paths on t_a_idx, and why? Start the answer with a line 'Verdict: V', V being one of: used in the final plan; built, lost in its relation; built, kept in its relation, not used above it; built for bitmap scans only, never compared; never built; not considered. Then a line 'Inputs: L', L being the reasons a path on the index was built, from: usable condition, useful order, useful backward order, implied predicate, index-only scan (comma-separated), or 'none' if no path was built.

**Reference:** Verdict: never built
Inputs: none
No candidate path on t_a_idx was ever built, so there was nothing to compare. When the planner decided whether to build a path on t_a_idx, none of the reasons to build one held: there was no query condition usable with the index, no useful sort order, no implied index predicate, and an index-only scan was not possible.

Evidence P04.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 2, replaced by IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2, replaced by BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
```
Evidence P04.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```

## 35. P13.v0.q2:L2:repair — L2 repair (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY d LIMIT 10
```
```text
Limit  (cost=779.19..779.22 rows=10 width=28)
  ->  Sort  (cost=779.19..829.19 rows=20000 width=28)
        Sort Key: d
        ->  Seq Scan on t  (cost=0.00..347.00 rows=20000 width=28)
```
**Question:** What single change to this query would make the planner use index t_a_idx? Give the changed query. Start the answer with a line 'SQL: <the changed query>'.

**Reference:** SQL: SELECT * FROM t ORDER BY a LIMIT 10
A path on t_a_idx was built because of a useful sort order. Nothing it was compared with beat it.

Evidence P13.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```
Evidence P13.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```

## 36. P13.v1.q2:L2:repair — L2 repair (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY d LIMIT 3
```
```text
Limit  (cost=605.50..605.50 rows=3 width=28)
  ->  Sort  (cost=605.50..655.50 rows=20000 width=28)
        Sort Key: d
        ->  Seq Scan on t  (cost=0.00..347.00 rows=20000 width=28)
```
**Question:** What single change to this query would make the planner use index t_a_idx? Give the changed query. Start the answer with a line 'SQL: <the changed query>'.

**Reference:** SQL: SELECT * FROM t ORDER BY a LIMIT 3
A path on t_a_idx was built because of a useful sort order. Nothing it was compared with beat it.

Evidence P13.v1.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```
Evidence P13.v1.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```

## 37. P14.v0.q2:L2:repair — L2 repair (test_transfer, family ordering)

**Query**:
```sql
SELECT * FROM t ORDER BY a + 0 LIMIT 10
```
```text
Limit  (cost=829.19..829.22 rows=10 width=32)
  ->  Sort  (cost=829.19..879.19 rows=20000 width=32)
        Sort Key: ((a + 0))
        ->  Seq Scan on t  (cost=0.00..397.00 rows=20000 width=32)
```
**Question:** What single change to this query would make the planner use index t_a_idx? Give the changed query. Start the answer with a line 'SQL: <the changed query>'.

**Reference:** SQL: SELECT * FROM t ORDER BY a LIMIT 10
A path on t_a_idx was built because of a useful sort order. Nothing it was compared with beat it.

Evidence P14.v0.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```
Evidence P14.v0.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=no useful_pathkeys=yes useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
 10 result level 2: keep IndexScan#2[t_a_idx] cost 0.29..1092.29 rows 20000 (order v1.2 ASC)
```

## 38. P02.v2.q2:L2:repair — L2 repair (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE a BETWEEN 400 AND 8000
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=15202 width=28)
  Filter: ((a >= 400) AND (a <= 8000))
```
**Question:** What single change to this query would make the planner use index t_a_idx? Give the changed query. Start the answer with a line 'SQL: <the changed query>'.

**Reference:** SQL: SELECT * FROM t WHERE a BETWEEN 400 AND 415
A path on t_a_idx was built because of a query condition usable with the index. In the comparisons it won: SeqScan lost to the IndexScan on t_a_idx; IndexScan on t_a_idx lost to the BitmapHeapScan on t_a_idx.

Evidence P02.v2.q2:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: discard IndexScan#2[t_a_idx] cost 0.29..1048.33 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
  9 scan of t: discard BitmapHeapScan#3[t_a_idx] cost 312.11..687.14 rows 15202, beaten by SeqScan#1 cost 0.00..447.00 rows 15202
```
Evidence P02.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..447.00 rows 32, replaced by IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..120.93 rows 32, replaced by BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.62..82.45 rows 32
```

## 39. P03.v2.q2:L2:repair — L2 repair (test_interp, family selectivity)

**Query**:
```sql
SELECT * FROM t WHERE b < 95
```
```text
Seq Scan on t  (cost=0.00..397.00 rows=19000 width=28)
  Filter: (b < 95)
```
**Question:** What single change to this query would make the planner use index t_b_c_idx? Give the changed query. Start the answer with a line 'SQL: <the changed query>'.

**Reference:** SQL: SELECT * FROM t WHERE b = 77
A path on t_b_c_idx was built because of a query condition usable with the index. In the comparisons it won: SeqScan lost to the BitmapHeapScan on t_b_c_idx.

Evidence P03.v2.q2:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..1000.73 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
  9 scan of t: discard BitmapHeapScan#3[t_b_c_idx] cost 227.54..612.04 rows 19000, beaten by SeqScan#1 cost 0.00..397.00 rows 19000
```
Evidence P03.v2.q1:
```text
  4 index t_b_c_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  5 scan of t: discard IndexScan#2[t_b_c_idx] cost 0.29..487.73 rows 200, beaten by SeqScan#1 cost 0.00..397.00 rows 200
  9 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 200, replaced by BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 10 scan of t: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
 11 result level 2: keep BitmapHeapScan#3[t_b_c_idx] cost 5.84..163.07 rows 200
```

## 40. P04.v2.q2:L2:repair — L2 repair (test_interp, family index_matching)

**Query**:
```sql
SELECT * FROM t WHERE a + 0 = 999
```
```text
Seq Scan on t  (cost=0.00..447.00 rows=100 width=28)
  Filter: ((a + 0) = 999)
```
**Question:** What single change to this query would make the planner use index t_a_idx? Give the changed query. Start the answer with a line 'SQL: <the changed query>'.

**Reference:** SQL: SELECT * FROM t WHERE a = 999
A path on t_a_idx was built because of a query condition usable with the index. In the comparisons it won: SeqScan lost to the IndexScan on t_a_idx; IndexScan on t_a_idx lost to the BitmapHeapScan on t_a_idx.

Evidence P04.v2.q2:
```text
  6 index t_a_idx: not built; inputs index_clauses=no useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
```
Evidence P04.v2.q1:
```text
  6 index t_a_idx: built 1; inputs index_clauses=yes useful_pathkeys=no useful_backward_pathkeys=no useful_predicate=no index_only_scan=no
  7 scan of t: remove SeqScan#1 cost 0.00..397.00 rows 2, replaced by IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
  8 scan of t: keep IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2
 10 scan of t: remove IndexScan#2[t_a_idx] cost 0.29..12.32 rows 2, replaced by BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 11 scan of t: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
 12 result level 2: keep BitmapHeapScan#3[t_a_idx] cost 4.30..11.63 rows 2
```

