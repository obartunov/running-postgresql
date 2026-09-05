-- Одна строка состояния таблицы.
SELECT relname,
       pg_size_pretty(pg_relation_size(relid))       AS heap,
       pg_size_pretty(pg_total_relation_size(relid)) AS total,
       n_live_tup, n_dead_tup
FROM pg_stat_all_tables WHERE relname = 'orders';
