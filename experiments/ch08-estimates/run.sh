#!/bin/bash
# Обе части подряд, с сохранением планов до и после.
set -euo pipefail
DB=${PGDATABASE:-est_bench}
mkdir -p results

psql -X -q -d "$DB" -f setup.sql

echo "=== часть 1: связанные колонки, до расширенной статистики ==="
psql -X -d "$DB" -f correlated.sql | tee results/correlated-before.txt \
  | grep -E 'rows=|Nested Loop|Hash Join|Execution Time' | head -20

psql -X -q -d "$DB" -f add-stats.sql > results/stats-created.txt

echo
echo "=== часть 1: после CREATE STATISTICS ==="
psql -X -d "$DB" -f correlated.sql | tee results/correlated-after.txt \
  | grep -E 'rows=|Nested Loop|Hash Join|Execution Time' | head -20

echo
echo "=== часть 2: край гистограммы ==="
psql -X -d "$DB" -f histogram-edge.sql | tee results/histogram-edge.txt \
  | grep -E '===|rows=|Execution Time'

cat <<'TXT'

Сравнивать надо rows= (ожидание) с actual rows= (факт) в узле по
customers, а не Execution Time. Время - следствие; предмет главы -
расхождение оценки.

В части 2 план за 'сегодня' построен на оценке, полученной за краем
гистограммы. Выполните ANALYZE events и повторите: оценка вернётся к
реальности без единого изменения запроса.
TXT
