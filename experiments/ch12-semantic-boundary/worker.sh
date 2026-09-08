#!/bin/bash
# Один воркер: пытается забронировать интервал по шаблону, который
# используют почти все приложения — сначала проверка, потом вставка.
#
#   worker.sh <таблица> <итераций> <файл для счётчика отказов>
set -euo pipefail
TABLE="$1"; ITER="$2"; ERRFILE="$3"
DB=${PGDATABASE:-sem_bench}
ERRORS=0

for i in $(seq 1 "$ITER"); do
  # все воркеры целятся в один и тот же интервал одного ресурса:
  # это худший случай, а не редкий
  LO="2026-01-0$(( (i % 9) + 1 )) 10:00"
  HI="2026-01-0$(( (i % 9) + 1 )) 12:00"

  OUT=$(psql -X -q -d "$DB" -v ON_ERROR_STOP=1 2>&1 <<SQL || true
BEGIN;
SELECT count(*) AS busy FROM $TABLE
 WHERE resource_id = 1 AND during && tstzrange('$LO','$HI') \\gset
\\if :busy
  ROLLBACK;
\\else
  SELECT pg_sleep(0.02);
  INSERT INTO $TABLE (resource_id, during)
       VALUES (1, tstzrange('$LO','$HI'));
  COMMIT;
\\endif
SQL
  )
  echo "$OUT" | grep -qE 'ERROR|ОШИБКА' && ERRORS=$((ERRORS+1))
done
echo "$ERRORS" >> "$ERRFILE"
