CREATE EXTENSION IF NOT EXISTS injection_points;

-- Keep the injection points private to this backend, so a concurrent planner
-- cannot trigger our callback.
SELECT injection_points_set_local();

-- Attach all four points in a single statement.  Attaching them one by one
-- would mean that the planning of each subsequent attach statement is itself
-- observed by the points already attached, and those events would end up in
-- the trace of this demo.
SELECT injection_points_attach(name, 'path-prune-notice')
FROM (VALUES
    ('planner-add-path-accept'),
    ('planner-add-path-reject'),
    ('planner-add-path-displace'),
    ('planner-add-path-precheck-reject')
) AS p(name);

SET max_parallel_workers_per_gather = 0;

-- One physical index, two candidate identities.  The base restriction makes
-- an unparameterized path over pp_orders_customer_idx worth building; the
-- join makes a parameterized path over the same index possible.
--
-- No particular final plan is asserted here.  The point is the trace.
EXPLAIN (COSTS ON, VERBOSE OFF)
SELECT o.id, o.customer_id, o.amount
FROM pp_customers AS c
JOIN pp_orders AS o
  ON o.customer_id = c.id
WHERE c.id BETWEEN 100 AND 109
  AND o.customer_id > 0;

-- Second query, the motivating case: a wider outer relation.  Here the index
-- does not appear in the final plan at all, and the trace shows why.
--
-- Both candidates over pp_orders_customer_idx are accepted, including the
-- parameterized one; the Nested Loop built on top of it is accepted too, and
-- is then displaced at the join level by a cheaper Hash Join.  The index was
-- not pruned - the join method above it lost.
EXPLAIN (COSTS ON, VERBOSE OFF)
SELECT o.id, o.customer_id, o.amount
FROM pp_customers AS c
JOIN pp_orders AS o
  ON o.customer_id = c.id
WHERE c.id <= 5000
  AND o.customer_id > 0;
