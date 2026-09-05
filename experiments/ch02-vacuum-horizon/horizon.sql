-- Кто держит горизонт. Четыре источника, один заход.
\echo === 1. сессии ===
SELECT pid, state, backend_xmin, age(backend_xmin) AS xmin_age,
       now() - xact_start AS xact_age, left(query, 50) AS query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY age(backend_xmin) DESC LIMIT 5;

\echo === 2. слоты репликации ===
SELECT slot_name, slot_type, active, xmin, catalog_xmin,
       age(xmin) AS xmin_age
FROM pg_replication_slots ORDER BY age(xmin) DESC NULLS LAST;

\echo === 3. реплики ===
SELECT application_name, state, backend_xmin, age(backend_xmin) AS xmin_age
FROM pg_stat_replication ORDER BY age(backend_xmin) DESC NULLS LAST;

\echo === 4. подготовленные транзакции ===
SELECT gid, prepared, owner, database, age(transaction) AS xmin_age
FROM pg_prepared_xacts ORDER BY prepared;
