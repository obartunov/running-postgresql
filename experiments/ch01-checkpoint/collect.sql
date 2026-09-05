-- Снимок счётчиков. Вызывается до и после прогона.
-- Версионная ветка разведена явно: начиная с PG17 счётчики
-- чекпойнтера переехали из pg_stat_bgwriter в pg_stat_checkpointer.

SELECT current_setting('server_version_num')::int >= 170000 AS pg17plus \gset

SELECT now() AS ts,
       pg_current_wal_lsn() AS wal_lsn,
       (SELECT sum(xact_commit + xact_rollback) FROM pg_stat_database) AS xacts;

\if :pg17plus
SELECT num_timed, num_requested, write_time, sync_time, buffers_written
FROM pg_stat_checkpointer;
\else
SELECT checkpoints_timed     AS num_timed,
       checkpoints_req       AS num_requested,
       checkpoint_write_time AS write_time,
       checkpoint_sync_time  AS sync_time,
       buffers_checkpoint    AS buffers_written
FROM pg_stat_bgwriter;
\endif
