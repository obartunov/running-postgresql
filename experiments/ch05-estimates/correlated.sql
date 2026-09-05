-- Связанные колонки: условие на город И регион.
-- Регион следует из города, но планировщик считает условия независимыми.
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.customer_id, count(*), sum(o.amount)
FROM customers c
JOIN orders o ON o.customer_id = c.id
WHERE c.city = 'city-37' AND c.region = 'region-1'
GROUP BY o.customer_id;
