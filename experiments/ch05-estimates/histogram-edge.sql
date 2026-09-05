-- Край гистограммы. Данные добавлены, ANALYZE намеренно не выполнен.
INSERT INTO events (created, payload)
SELECT now() - (random() * interval '12 hours'), md5(g::text)
FROM generate_series(1, 1000000) g;

\echo '=== вчера: внутри известного планировщику диапазона ==='
EXPLAIN (ANALYZE)
SELECT count(*) FROM events
WHERE created >= now() - interval '2 days'
  AND created <  now() - interval '1 day';

\echo '=== сегодня: за краем гистограммы ==='
EXPLAIN (ANALYZE)
SELECT count(*) FROM events WHERE created >= now() - interval '12 hours';

\echo '=== завтра: заведомо пусто, для сравнения формы оценки ==='
EXPLAIN (ANALYZE)
SELECT count(*) FROM events WHERE created >= now() + interval '1 day';
