-- Проверки, которые выполняются ДО окна, на живой базе.

\echo === 1. что вы когда-то трогали в конфигурации ===
SELECT name, setting, boot_val, source
FROM pg_settings
WHERE source NOT IN ('default', 'override')
ORDER BY name;

\echo === 2. расширения: должны существовать и быть собраны под целевую версию ===
SELECT e.extname, e.extversion,
       (SELECT max(version) FROM pg_available_extension_versions v
         WHERE v.name = e.extname) AS available
FROM pg_extension e ORDER BY 1;

\echo === 3. расхождение версий правил сортировки (тихий пассажир) ===
SELECT datname, datcollate, datcollversion,
       pg_database_collation_actual_version(oid) AS actual
FROM pg_database WHERE datcollversion IS NOT NULL;

SELECT collname, collcollate, collversion,
       pg_collation_actual_version(oid) AS actual
FROM pg_collation
WHERE collversion IS NOT NULL
  AND collversion IS DISTINCT FROM pg_collation_actual_version(oid);

\echo === 4. расширенная статистика: НЕ переносится pg_upgrade даже в PG18 ===
SELECT stxnamespace::regnamespace AS schema, stxname, stxkind
FROM pg_statistic_ext ORDER BY 1, 2;

\echo === 5. индексы, зависящие от текстовых колонок (кандидаты на REINDEX) ===
SELECT c.relname AS index_name,
       t.relname AS table_name,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_attribute a ON a.attrelid = i.indrelid
                   AND a.attnum = ANY (i.indkey)
WHERE a.atttypid IN ('text'::regtype, 'varchar'::regtype, 'char'::regtype)
  AND t.relnamespace::regnamespace::text NOT IN ('pg_catalog','information_schema')
GROUP BY 1, 2, c.oid
ORDER BY pg_relation_size(c.oid) DESC;
