-- Дерево ожиданий. Читать снизу вверх: у большинства в blocked_by
-- окажется один и тот же pid, а у него самого - pid настоящего виновника.
SELECT a.pid,
       a.state,
       date_trunc('second', now() - a.xact_start)   AS xact_age,
       a.wait_event_type, a.wait_event,
       pg_blocking_pids(a.pid)                      AS blocked_by,
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 50) AS query
FROM pg_stat_activity a
WHERE a.backend_type = 'client backend'
  AND a.pid <> pg_backend_pid()
ORDER BY cardinality(pg_blocking_pids(a.pid)), a.xact_start;
