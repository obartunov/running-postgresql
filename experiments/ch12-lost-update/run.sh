#!/bin/bash
# Сколько инкрементов теряется, когда инвариант живёт в приложении.
#
#   ./run.sh              # все четыре режима
#   ./run.sh rmw          # один режим
#
# Ожидаемая сумма всегда WORKERS * ITER. Всё, что меньше, - потерянные
# обновления.
set -euo pipefail
DB=${PGDATABASE:-orm_bench}
WORKERS=${WORKERS:-8}
ITER=${ITER:-50}
MODES="${*:-rmw rmw-rr forupdate sql}"
mkdir -p results

printf '%-12s %10s %10s %10s %8s\n' режим ожидалось получилось потеряно секунд \
  | tee results/run.txt

for MODE in $MODES; do
  psql -X -q -d "$DB" -f setup.sql
  RETRY_FILE=$(mktemp); export RETRY_FILE
  T0=$(date +%s.%N)
  for _ in $(seq 1 "$WORKERS"); do
    ./worker.sh "$MODE" "$ITER" &
  done
  wait
  T1=$(date +%s.%N)

  GOT=$(psql -X -At -d "$DB" -c "SELECT balance FROM accounts WHERE id = 1")
  WANT=$((WORKERS * ITER))
  RETRIES=$(awk '{s+=$1} END {print s+0}' "$RETRY_FILE"); rm -f "$RETRY_FILE"
  printf '%-12s %10s %10s %10s %8.1f  повторов: %s\n' \
    "$MODE" "$WANT" "$GOT" "$((WANT - GOT))" "$(echo "$T1-$T0" | bc)" "$RETRIES" \
    | tee -a results/run.txt
done

cat <<'TXT'

Потерянные обновления - не ошибка PostgreSQL и не гонка "иногда".
При read-modify-write в приложении каждая пара транзакций, прочитавшая
одно и то же значение, гарантированно теряет один инкремент: обе
запишут одно и то же число.

База при этом не сообщает ни о чём: обе транзакции завершились успешно.
TXT
