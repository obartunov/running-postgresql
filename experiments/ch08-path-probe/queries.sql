-- Три вопроса про один и тот же физический индекс orders_customer_idx.

\echo === 1. standalone scan: индекс почти бесполезен ===
EXPLAIN SELECT * FROM orders WHERE customer_id > 0;

\echo === 2. join, baseline ===
EXPLAIN SELECT o.* FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE c.id BETWEEN 100 AND 4999;

\echo === 3. тот же join, если запретить hash и merge join ===
SET enable_hashjoin = off;
SET enable_mergejoin = off;
EXPLAIN SELECT o.* FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE c.id BETWEEN 100 AND 4999;
RESET enable_hashjoin;
RESET enable_mergejoin;
