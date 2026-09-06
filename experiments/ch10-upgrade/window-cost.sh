#!/bin/bash
# Два числа, из которых состоит окно обновления.
# Меряются на текущей версии, вторая установка не нужна.
set -euo pipefail
DB=${PGDATABASE:-upg_bench}
mkdir -p results

t() { date +%s.%N; }
el() { echo "scale=1; $2 - $1" | bc; }

echo "=== подготовка данных ==="
# Ошибки подготовки не прячем: скрипт, который молча падает на -e,
# отнимает больше времени, чем экономит вывод.
if ! pgbench -i -s "${SCALE:-100}" "$DB" > results/pgbench-init.log 2>&1; then
  tail -5 results/pgbench-init.log >&2
  echo "подготовка данных не удалась, см. results/pgbench-init.log" >&2
  exit 1
fi
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
# нет. Воспроизводится честно: таблицы только что созданы и ни разу не
# анализировались. Прежняя версия стенда обнуляла цель статистики через
# SET STATISTICS 0 — при такой цели analyze-in-stages не собирает ничего,
# и измерялся пустой проход.
echo "=== база с данными и без статистики ==="
psql -X -At -d "$DB" -c "
  SELECT count(*) FILTER (WHERE last_analyze IS NULL
                            AND last_autoanalyze IS NULL) || ' таблиц без статистики'
  FROM pg_stat_user_tables"

T0=$(t)
vacuumdb -d "$DB" --analyze-in-stages > results/analyze-stages.log 2>&1
T1=$(t)

T2=$(t)
vacuumdb -d "$DB" --analyze > results/analyze-full.log 2>&1
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
  printf 'analyze-in-stages (три прохода):    %6s с\n' "$(el $T0 $T1)"
  printf 'ещё один полный ANALYZE:            %6s с\n' "$(el $T2 $T3)"
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
