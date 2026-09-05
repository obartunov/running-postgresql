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

psql -X -q -d "$DB" -f setup.sql

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
printf 'BEGIN;\nSELECT count(*) FROM orders;\n' >&9
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
C_START=$(date +%s.%N)
( psql -X -q -d "$DB" -c "SELECT count(*) FROM orders" \
    > "$OUT/select.txt" 2>&1 ) &
C_JOB=$!; PIDS+=($C_JOB)
sleep 2

# --- снимок состояния во время затыка ----------------------------------
psql -X -d "$DB" -f blocked.sql > "$OUT/blocked.txt"
psql -X -d "$DB" -f locks.sql   > "$OUT/locks.txt"

# --- аварийное действие для третьего прогона ---------------------------
if [ "$MODE" = "cancel-ddl" ]; then
  psql -X -q -d "$DB" -c \
    "SELECT pg_cancel_backend(pid) FROM pg_stat_activity
     WHERE query LIKE 'ALTER TABLE orders%' AND pid <> pg_backend_pid()" \
    > "$OUT/cancel.txt"
fi

wait $C_JOB 2>/dev/null || true
C_END=$(date +%s.%N)
wait $B_JOB 2>/dev/null || true

# A закрывается штатно, чтобы было видно: она никуда не делась
printf 'COMMIT;\n' >&9; exec 9>&-

{
  echo "режим:                    $MODE"
  echo "ожидание SELECT (C):      $(echo "$C_END - $C_START" | bc) с"
  echo "--- состояние сессии A перед миграцией ---"; cat "$OUT/session-a-state.txt"
  echo "--- результат DDL ---";    cat "$OUT/ddl.txt"
  echo "--- результат SELECT ---"; cat "$OUT/select.txt"
} | tee "$OUT/summary.txt"

echo
echo "дерево ожиданий во время затыка: $OUT/blocked.txt"
