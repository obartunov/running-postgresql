-- Опись расширений: что установлено, на какой глубине и где вы уже за
-- точкой невозврата.

\echo === установленные расширения ===
SELECT e.extname, e.extversion,
       n.nspname AS schema,
       (SELECT max(version) FROM pg_available_extension_versions v
         WHERE v.name = e.extname) AS available
FROM pg_extension e
JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY 1;

\echo === загружаемые при старте (уровень 3 и глубже) ===
SELECT name, setting FROM pg_settings
WHERE name IN ('shared_preload_libraries',
               'session_preload_libraries',
               'local_preload_libraries');

\echo === фоновые процессы, которые сейчас работают (уровень 4) ===
SELECT backend_type, count(*)
FROM pg_stat_activity
WHERE backend_type NOT IN ('client backend', 'checkpointer',
                           'background writer', 'walwriter',
                           'autovacuum launcher', 'startup')
GROUP BY 1 ORDER BY 1;

\echo === ТОЧКА НЕВОЗВРАТА 1: колонки с типами из расширений ===
SELECT c.oid::regclass AS table_name, a.attname, t.typname, e.extname
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid AND c.relkind IN ('r','p','m')
JOIN pg_type  t ON t.oid = a.atttypid
JOIN pg_depend d ON d.objid = t.oid
                AND d.classid = 'pg_type'::regclass AND d.deptype = 'e'
JOIN pg_extension e ON e.oid = d.refobjid
WHERE a.attnum > 0 AND NOT a.attisdropped
ORDER BY 4, 1, 2;

\echo === ТОЧКА НЕВОЗВРАТА 2: индексы на классах операторов из расширений ===
SELECT i.indexrelid::regclass AS index_name,
       i.indrelid::regclass   AS table_name,
       e.extname,
       pg_size_pretty(pg_relation_size(i.indexrelid)) AS size
FROM pg_index i
CROSS JOIN LATERAL unnest(i.indclass::oid[]) AS opc(oid)
JOIN pg_depend d ON d.objid = opc.oid
                AND d.classid = 'pg_opclass'::regclass AND d.deptype = 'e'
JOIN pg_extension e ON e.oid = d.refobjid
GROUP BY 1, 2, 3, i.indexrelid
ORDER BY pg_relation_size(i.indexrelid) DESC;

\echo === ТОЧКА НЕВОЗВРАТА 3: индексы на методах доступа из расширений ===
SELECT c.oid::regclass AS index_name, am.amname, e.extname
FROM pg_class c
JOIN pg_am am ON am.oid = c.relam
JOIN pg_depend d ON d.objid = am.oid
                AND d.classid = 'pg_am'::regclass AND d.deptype = 'e'
JOIN pg_extension e ON e.oid = d.refobjid
WHERE c.relkind = 'i'
ORDER BY 3, 1;
