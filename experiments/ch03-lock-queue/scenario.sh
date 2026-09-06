#!/bin/bash
# Три сессии, ни одна из которых по отдельности ничего не ломает.
#
#   ./scenario.sh naive       -- DDL без ограничителя: встаёт вся таблица
#   ./scenario.sh timeout     -- DDL с lock_timeout: падает только DDL
#   ./scenario.sh cancel-ddl  -- очередь строится, затем снимается DDL;
#                                A остаётся жива, C проходит немедленно
#
# Выбрасываемая база. Скрипт убирает за собой все сессии.
set -euo pipefail

DB=${PGDATABASE:-lock_bench}
MODE="${1:?укажите режим: naive, timeout или cancel-ddl}"
OUT="results/$MODE"; mkdir -p "$OUT"

# Преflight: держатель от прерванного прогона блокирует DROP TABLE в
# setup.sql. lock_timeout превращает вечное ожидание во внятную ошибку —
# то самое правило, которое доказывает эта глава.
psql -X -q -d "$DB" -c "
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE application_name = 'ch03-holder' AND pid <> pg_backend_pid()" > /dev/null
if ! PGOPTIONS='-c lock_timeout=10s' psql -X -q -v ON_ERROR_STOP=1 -d "$DB" \
       -f setup.sql; then
  echo "Подготовка не смогла взять блокировку: жив держатель от прерванного" >&2
  echo "прогона. Найдите его в pg_stat_activity и снимите pg_terminate_backend." >&2
  exit 1
fi

PIDS=()
FIFO=$(mktemp -u); mkfifo "$FIFO"
cleanup() {
  exec 9>&- 2>/dev/null || true
  rm -f "$FIFO"
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

# --- A: читатель, забывший закрыть транзакцию -------------------------
# Пауза держится на КЛИЕНТЕ: сессия остаётся в состоянии
# 'idle in transaction', как в реальном инциденте. pg_sleep() внутри
# сервера сделал бы её 'active' и подменил бы историю главы.
psql -X -q -d "$DB" -f - < "$FIFO" > "$OUT/session-a.txt" 2>&1 &
PIDS+=($!)
exec 9>"$FIFO"
printf "SET application_name='ch03-holder';\nBEGIN;\nSELECT count(*) FROM orders;\n" >&9
sleep 2

psql -X -d "$DB" -c \
  "SELECT state, now()-state_change AS in_state FROM pg_stat_activity
   WHERE pid <> pg_backend_pid() AND state LIKE 'idle in%'" \
  > "$OUT/session-a-state.txt"

# --- B: миграция -------------------------------------------------------
DDL="ALTER TABLE orders ADD COLUMN promo_code text DEFAULT '' NOT NULL;"
[ "$MODE" = "timeout" ] && DDL="SET lock_timeout = '2s'; $DDL"
( psql -X -d "$DB" -c "$DDL" > "$OUT/ddl.txt" 2>&1 ) &
B_JOB=$!; PIDS+=($B_JOB)
sleep 2

# --- C: обычный SELECT, совместимый с A, но пришедший после B ----------
# Время меряется ВНУТРИ подоболочки: иначе в него попадут паузы самого
# скрипта, и в режиме timeout мы намеряем свой же sleep вместо ожидания.
(
  cs=$(date +%s.%N)
  psql -X -q -d "$DB" -c "SELECT count(*) FROM orders" > "$OUT/select.txt" 2>&1
  ce=$(date +%s.%N)
  echo "$ce - $cs" | bc > "$OUT/c_elapsed"
) &
C_JOB=$!; PIDS+=($C_JOB)
sleep 2

# --- снимок состояния во время затыка ----------------------------------
psql -X -d "$DB" -f blocked.sql > "$OUT/blocked.txt"
psql -X -d "$DB" -f locks.sql   > "$OUT/locks.txt"

# --- аварийное действие ------------------------------------------------
case "$MODE" in
  cancel-ddl)
    # Снимаем МИГРАЦИЮ, а не сессию A. Очередь должна разойтись сразу,
    # причём A остаётся жива и по-прежнему держит ACCESS SHARE.
    psql -X -q -d "$DB" -c \
      "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
       WHERE query LIKE 'ALTER TABLE orders%' AND pid <> pg_backend_pid()" \
      > "$OUT/cancel.txt"
    # Доказательство: A ЖИВА и держит ACCESS SHARE, а новый читатель
    # проходит немедленно. Значит, очередь создавала не A, а миграция.
    ds=$(date +%s.%N)
    psql -X -q -d "$DB" -c "SELECT count(*) FROM orders" > /dev/null 2>&1
    de=$(date +%s.%N)
    echo "$de - $ds" | bc > "$OUT/d_elapsed"
    psql -X -d "$DB" -c \
      "SELECT pid, state, now()-xact_start AS xact_age
       FROM pg_stat_activity WHERE state = 'idle in transaction'" \
      > "$OUT/holder-still-alive.txt"
    ;;
  naive)
    # Без ограничителя очередь не разойдётся сама: B ждёт A, C ждёт B.
    # Отпускаем A — это и есть 'нашли и сняли виновника'.
    printf 'COMMIT;\n' >&9
    ;;
esac

wait $C_JOB 2>/dev/null || true
wait $B_JOB 2>/dev/null || true

# A закрывается штатно, если ещё не закрыта: видно, что она никуда не делась
printf 'COMMIT;\n' >&9 2>/dev/null || true
exec 9>&- 2>/dev/null || true

{
  echo "режим:                    $MODE"
  printf 'ожидание SELECT (C):      %s с\n' "$(cat "$OUT/c_elapsed" 2>/dev/null || echo '?')"
  if [ -f "$OUT/d_elapsed" ]; then
    printf 'новый SELECT после снятия DDL: %s с\n' "$(cat "$OUT/d_elapsed")"
    echo "--- а сессия A всё ещё держит блокировку ---"
    cat "$OUT/holder-still-alive.txt"
  fi
  echo "--- состояние сессии A перед миграцией ---"; cat "$OUT/session-a-state.txt"
  echo "--- результат DDL ---";    cat "$OUT/ddl.txt"
  echo "--- результат SELECT ---"; cat "$OUT/select.txt"
} | tee "$OUT/summary.txt"

echo
echo "дерево ожиданий во время затыка: $OUT/blocked.txt"
