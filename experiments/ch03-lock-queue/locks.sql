-- Кто что держит и что не выдано. Картина затыка: одна выданная
-- AccessShareLock, одна невыданная AccessExclusiveLock, и за ней —
-- множество невыданных AccessShareLock.
SELECT l.pid, l.mode, l.granted, a.state,
       left(regexp_replace(a.query, '\s+', ' ', 'g'), 40) AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'orders'::regclass
ORDER BY l.granted DESC, l.pid;
