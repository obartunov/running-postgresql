#!/bin/bash
# Сколько узлов в плане претендуют на бюджет и сколько из них сбросилось
# на диск. Это то, что превращает work_mem в реальную цифру.
set -euo pipefail
DB=${PGDATABASE:-mem_bench}
WM="${1:-64MB}"
mkdir -p results

psql -X -d "$DB" <<SQL > "results/explain-$WM.txt"
SET work_mem = '$WM';
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
$(cat query.sql)
SQL

echo "--- потребители бюджета в плане ---"
grep -cE '^\s*->?\s*(Sort|Hash|HashAggregate|HashJoin|Memoize|GroupAggregate)' \
  "results/explain-$WM.txt" || true
grep -E 'Sort Method|Buckets:|Batches:|Disk:|Memory Usage|Workers Launched' \
  "results/explain-$WM.txt" || true
echo
echo "Batches > 1 или 'external merge' — узел не поместился и сбросился"
echo "на диск. Это предохранитель сработал, а не поломка."
