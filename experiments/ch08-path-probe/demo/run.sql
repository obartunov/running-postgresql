SELECT injection_points_attach('path-pruning-reject', 'notice-path');
SELECT injection_points_attach('path-pruning-displace', 'notice-path');
EXPLAIN (COSTS OFF) SELECT o.* FROM customers c JOIN orders o
  ON o.customer_id = c.id WHERE c.id BETWEEN 100 AND 4999;
