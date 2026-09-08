#!/bin/bash
# Один воркер: ITER попыток забронировать ресурс на пересекающийся
# интервал. Проверка "свободно ли" делается в приложении — именно так,
# как её пишут поверх ORM.
#
#   worker.sh <режим> <итераций> <resource_id>
set -euo pipefail
MODE="$1"; ITER="$2"; RES="$3"
DB=${PGDATABASE:-sem_bench}
OKFILE=${OKFILE:-/dev/null}
ERRFILE=${ERRFILE:-/dev/null}

ok=0; err=0
for i in $(seq 1 "$ITER"); do
  # все воркеры целятся в один и тот же час: пересечение гарантировано
  SLOT="2026-10-01 10:00:00+00"
  END="2026-10-01 11:00:00+00"

  case "$MODE" in
    # Проверка в приложении: сначала SELECT, потом INSERT.
    precheck)
      OUT=$(psql -X -At -d "$DB" <<SQL 2>&1
BEGIN;
SELECT count(*) AS busy FROM bookings
 WHERE resource_id = $RES
   AND tstzrange(starts_at, ends_at) && tstzrange('$SLOT', '$END');
SQL
      ) || true
      BUSY=$(echo "$OUT" | tail -1)
      # пауза между проверкой и вставкой — то самое окно, которое в
      # приложении существует всегда, просто обычно короче
      sleep 0.05
      if [ "$BUSY" = "0" ]; then
        if psql -X -q -d "$DB" -c \
             "INSERT INTO bookings (resource_id, starts_at, ends_at)
              VALUES ($RES, '$SLOT', '$END')" >/dev/null 2>&1
        then ok=$((ok+1)); else err=$((err+1)); fi
      fi ;;

    # Тот же код приложения, но инвариант объявлен в базе.
    constraint)
      OUT=$(psql -X -At -d "$DB" <<SQL 2>&1
BEGIN;
SELECT count(*) AS busy FROM bookings
 WHERE resource_id = $RES
   AND tstzrange(starts_at, ends_at) && tstzrange('$SLOT', '$END');
SQL
      ) || true
      BUSY=$(echo "$OUT" | tail -1)
      sleep 0.05
      if [ "$BUSY" = "0" ]; then
        if psql -X -q -d "$DB" -c \
             "INSERT INTO bookings (resource_id, starts_at, ends_at)
              VALUES ($RES, '$SLOT', '$END')" >/dev/null 2>&1
        then ok=$((ok+1)); else err=$((err+1)); fi
      fi ;;

    *) echo "неизвестный режим: $MODE" >&2; exit 2 ;;
  esac
done
echo "$ok" >> "$OKFILE"
echo "$err" >> "$ERRFILE"
