#!/bin/bash
# Проверка в приложении против инварианта в базе.
set -euo pipefail
DB=${PGDATABASE:-sem_bench}
WORKERS=${WORKERS:-6}
ITER=${ITER:-9}
mkdir -p results

overlaps() {   # число пересекающихся пар в таблице
  psql -X -At -d "$DB" -c "
    SELECT count(*) FROM $1 a JOIN $1 b
      ON a.id < b.id AND a.resource_id = b.resource_id AND a.during && b.during"
}

printf '%-14s %8s %10s %14s\n' таблица строк отказов 'пересечений' \
  | tee results/run.txt

for T in bookings_app bookings_db; do
  psql -X -q -d "$DB" -f setup.sql
  ERRFILE=$(mktemp)
  for _ in $(seq 1 "$WORKERS"); do ./worker.sh "$T" "$ITER" "$ERRFILE" & done
  wait
  ERR=$(awk '{s+=$1} END {print s+0}' "$ERRFILE"); rm -f "$ERRFILE"
  ROWS=$(psql -X -At -d "$DB" -c "SELECT count(*) FROM $T")
  printf '%-14s %8s %10s %14s\n' "$T" "$ROWS" "$ERR" "$(overlaps "$T")" \
    | tee -a results/run.txt
done

cat <<'TXT'

Проверка в приложении не защищает: две транзакции, выполнившие её до
того, как любая из них записала, обе видят ресурс свободным и обе
успешно фиксируются. Ограничение в базе тот же самый порядок событий
переживает: вторая фиксация отклоняется.

Отказ — это не поломка. Это единственная форма, в которой приложение
узнаёт, что мир изменился между проверкой и записью.
TXT
