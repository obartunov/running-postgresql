#!/bin/bash
# Два числа, из которых состоит окно обновления.
# Меряются на текущей версии, вторая установка не нужна.
set -euo pipefail
DB=${PGDATABASE:-upg_bench}
mkdir -p results

t() { date +%s.%N; }
el() { echo "scale=1; $2 - $1" | bc; }

echo "=== подготовка данных ==="
pgbench -i -s "${SCALE:-100}" "$DB" > /dev/null 2>&1
psql -X -q -d "$DB" <<'SQL'
DROP TABLE IF EXISTS texty;
CREATE TABLE texty AS
SELECT g AS id,
       md5(g::text) AS h,
       'наименование ' || (g % 10000) AS name,
       'city-' || (g % 500) AS city
FROM generate_series(1, 2000000) g;
CREATE INDEX ON texty (name);
CREATE INDEX ON texty (city, name);
CREATE INDEX ON texty (h);
SQL

# --- 1: сколько стоит статистика ---------------------------------------
# Состояние после обновления на версиях до PG18: данные есть, статистики
# нет. Воспроизводим, отбирая статистику у пользовательских таблиц.
echo "=== приводим базу в состояние 'данные есть, статистики нет' ==="
psql -X -q -d "$DB" -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid::regclass AS t, a.attname
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
            WHERE c.relkind = 'r' AND n.nspname = 'public' AND NOT a.attisdropped
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET STATISTICS 0', r.t, r.attname);
  END LOOP;
END \$\$;"
psql -X -q -d "$DB" -c "ANALYZE"   # собирает пусто: цель 0

T0=$(t)
vacuumdb -d "$DB" --analyze-in-stages > /dev/null 2>&1 || true
T1=$(t)

# вернуть цель по умолчанию и собрать полную статистику
psql -X -q -d "$DB" -c "
DO \$\$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.oid::regclass AS t, a.attname
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0
            WHERE c.relkind = 'r' AND n.nspname = 'public' AND NOT a.attisdropped
  LOOP
    EXECUTE format('ALTER TABLE %s ALTER COLUMN %I SET STATISTICS -1', r.t, r.attname);
  END LOOP;
END \$\$;"
T2=$(t)
psql -X -q -d "$DB" -c "ANALYZE" > /dev/null
T3=$(t)

# --- 2: сколько стоит перестроение текстовых индексов -------------------
IDX=$(psql -X -At -d "$DB" -c "
SELECT c.relname FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
WHERE a.atttypid IN ('text'::regtype,'varchar'::regtype)
  AND t.relname = 'texty'
GROUP BY c.relname ORDER BY c.relname")

TOTAL=0
for I in $IDX; do
  A=$(t); psql -X -q -d "$DB" -c "REINDEX INDEX CONCURRENTLY $I"; B=$(t)
  S=$(el $A $B); TOTAL=$(echo "$TOTAL + $S" | bc)
  printf '  REINDEX %-28s %6s с\n' "$I" "$S"
done

TEXT_SIZE=$(psql -X -At -d "$DB" -c "
SELECT pg_size_pretty(sum(pg_relation_size(c.oid)))
FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
WHERE a.atttypid IN ('text'::regtype,'varchar'::regtype) AND t.relname='texty'")

{
  echo
  printf 'analyze-in-stages (первая помощь):  %6s с\n' "$(el $T0 $T1)"
  printf 'полный ANALYZE:                     %6s с\n' "$(el $T2 $T3)"
  printf 'REINDEX текстовых индексов:         %6s с  (объём %s)\n' "$TOTAL" "$TEXT_SIZE"
} | tee results/window-cost.txt

cat <<'TXT'

Первое число — сколько времени база после обновления планирует запросы
вслепую, если не запустить analyze-in-stages. Второе — сколько занимает
полная статистика. Третье — ваша уязвимость к смене версии правил
сортировки, выраженная во времени.

Умножьте третье на отношение объёма ваших текстовых индексов в проде к
объёму в этом стенде: это порядок величины, на который надо
рассчитывать при обновлении образа операционной системы.
TXT
