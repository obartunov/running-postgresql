#!/bin/bash
# Три сценария главы 2.
#   ./scenario.sh A   -- никто не мешает
#   ./scenario.sh B   -- открытая транзакция REPEATABLE READ
#   ./scenario.sh C   -- брошенная PREPARE TRANSACTION
#
# Выполняется на выбрасываемой базе. Сценарий C оставляет
# подготовленную транзакцию до конца прогона и откатывает её сам;
# при прерывании проверьте pg_prepared_xacts руками.
set -euo pipefail

DB=${PGDATABASE:-vac_bench}
TAG="${1:?укажите сценарий: A, B или C}"
OUT="results/$TAG"; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-5}

psql -X -d "$DB" -f setup.sql > "$OUT/setup.log"
psql -X -d "$DB" -f measure.sql > "$OUT/00-before.txt"

BLOCKER_PID=""
cleanup() {
  [ -n "$BLOCKER_PID" ] && kill "$BLOCKER_PID" 2>/dev/null || true
  psql -X -q -d "$DB" -c "ROLLBACK PREPARED 'ch02_orphan'" 2>/dev/null || true
}
trap cleanup EXIT

case "$TAG" in
  A) : ;;
  B) # держатель горизонта: живая транзакция, видна в pg_stat_activity
     psql -X -q -d "$DB" -c \
       "BEGIN ISOLATION LEVEL REPEATABLE READ;
        SELECT count(*) FROM orders;
        SELECT pg_sleep(100000);" &
     BLOCKER_PID=$!
     sleep 3 ;;
  C) # держатель горизонта: подготовленная транзакция.
     # Сессии нет, в pg_stat_activity пусто. В этом весь смысл.
     psql -X -q -d "$DB" <<'SQL'
BEGIN;
UPDATE orders SET status = 'prep' WHERE id = 1;
PREPARE TRANSACTION 'ch02_orphan';
SQL
     ;;
esac

for i in $(seq 1 "$ROUNDS"); do
  psql -X -q -d "$DB" -f load.sql
  psql -X -d "$DB" -c "VACUUM (VERBOSE) orders" > "$OUT/vacuum-$i.txt" 2>&1
  psql -X -d "$DB" -f measure.sql   >> "$OUT/size.txt"
  psql -X -d "$DB" -f horizon.sql   >> "$OUT/horizon.txt"
  echo "round $i: $(grep -o '[0-9]* removed, .*' "$OUT/vacuum-$i.txt" | head -1)"
done

psql -X -d "$DB" -f measure.sql > "$OUT/99-after.txt"
echo "готово: $OUT"
