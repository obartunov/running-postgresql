#!/bin/bash
# Три сессии, ни одна из которых по отдельности ничего не ломает.
#
#   ./scenario.sh naive      -- DDL без ограничителя: встаёт вся таблица
#   ./scenario.sh timeout    -- DDL с lock_timeout: падает только DDL
#
# Выбрасываемая база. Скрипт убирает за собой все три сессии.
set -euo pipefail

DB=${PGDATABASE:-lock_bench}
MODE="${1:?укажите режим: naive или timeout}"
OUT="results/$MODE"; mkdir -p "$OUT"

psql -X -q -d "$DB" -f setup.sql

PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

# --- A: безобидный читатель, забывший закрыть транзакцию -------------
psql -X -q -d "$DB" -c \
  "BEGIN; SELECT count(*) FROM orders; SELECT pg_sleep(60);" &
PIDS+=($!)
sleep 2

# --- B: миграция ------------------------------------------------------
B_START=$(date +%s.%N)
if [ "$MODE" = "timeout" ]; then
  ( psql -X -d "$DB" -c "SET lock_timeout = '2s';
                         ALTER TABLE orders ADD COLUMN promo_code text;" \
      > "$OUT/ddl.txt" 2>&1; echo "$(date +%s.%N)" > "$OUT/ddl_end" ) &
else
  ( psql -X -d "$DB" -c "ALTER TABLE orders ADD COLUMN promo_code text;" \
      > "$OUT/ddl.txt" 2>&1; echo "$(date +%s.%N)" > "$OUT/ddl_end" ) &
fi
PIDS+=($!)
sleep 2

# --- C: обычный SELECT, совместимый с A, но пришедший после B ---------
C_START=$(date +%s.%N)
psql -X -q -d "$DB" -c "SELECT count(*) FROM orders" > "$OUT/select.txt" 2>&1 &
C_PID=$!
PIDS+=($C_PID)
sleep 2

# --- снимок состояния во время затыка ---------------------------------
psql -X -d "$DB" -f blocked.sql > "$OUT/blocked.txt"
psql -X -d "$DB" -f locks.sql   > "$OUT/locks.txt"

wait $C_PID 2>/dev/null || true
C_END=$(date +%s.%N)

{
  echo "режим: $MODE"
  echo "ожидание SELECT (сессия C): $(echo "$C_END - $C_START" | bc) с"
  echo "--- вывод DDL ---"; cat "$OUT/ddl.txt"
  echo "--- вывод SELECT ---"; cat "$OUT/select.txt"
} | tee "$OUT/summary.txt"

echo
echo "дерево ожиданий во время затыка: $OUT/blocked.txt"
