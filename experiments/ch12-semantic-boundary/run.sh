#!/bin/bash
# Инвариант в приложении против инварианта в базе.
#
#   ./run.sh            # оба режима
#   WORKERS=8 ITER=5 ./run.sh
set -euo pipefail
DB=${PGDATABASE:-sem_bench}
WORKERS=${WORKERS:-8}
ITER=${ITER:-5}
mkdir -p results

printf '%-11s %9s %9s %9s %11s\n' режим вставлено отказано попыток пересечений \
  | tee results/run.txt

for MODE in precheck constraint; do
  psql -X -q -d "$DB" -f setup.sql
  [ "$MODE" = "constraint" ] && psql -X -q -d "$DB" -f add-constraint.sql

  OKFILE=$(mktemp); ERRFILE=$(mktemp); export OKFILE ERRFILE
  for _ in $(seq 1 "$WORKERS"); do ./worker.sh "$MODE" "$ITER" 1 & done
  wait

  OK=$(awk '{s+=$1} END {print s+0}' "$OKFILE")
  ERR=$(awk '{s+=$1} END {print s+0}' "$ERRFILE")
  rm -f "$OKFILE" "$ERRFILE"
  OVER=$(psql -X -At -d "$DB" -f check.sql)

  printf '%-11s %9s %9s %9s %11s\n' \
    "$MODE" "$OK" "$ERR" "$((WORKERS * ITER))" "$OVER" | tee -a results/run.txt
done

cat <<'TXT'

Ожидаемый инвариант: пересечений быть не должно ни при каком
чередовании. Столбец «пересечений» — прямая проверка мира, а не
поведения кода.

В режиме precheck проверка выполняется в приложении между SELECT и
INSERT. В режиме constraint тот же код приложения не меняется — меняется
только то, что инвариант объявлен в базе через EXCLUDE USING gist.
TXT
