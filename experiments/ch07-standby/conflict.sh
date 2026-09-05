#!/bin/bash
# Один и тот же конфликт при трёх настройках.
#
#   ./conflict.sh 1   max_standby_streaming_delay = 0    -> запрос убит
#   ./conflict.sh 2   max_standby_streaming_delay = 30s  -> запрос жив, реплика отстаёт
#   ./conflict.sh 3   hot_standby_feedback = on          -> запрос жив, пухнет primary
set -euo pipefail

BASE=${BASE:-/tmp/ch07}
PPORT=${PPORT:-55432}
SPORT=${SPORT:-55433}
RUN="${1:?укажите прогон: 1, 2 или 3}"
OUT="results/run$RUN"; mkdir -p "$OUT"

P="psql -X -h 127.0.0.1 -p $PPORT -d postgres"
S="psql -X -h 127.0.0.1 -p $SPORT -d postgres"

case "$RUN" in
  1) DELAY=0     ; FEEDBACK=off ;;
  2) DELAY=30s   ; FEEDBACK=off ;;
  3) DELAY=0     ; FEEDBACK=on  ;;
esac

$S -q -c "ALTER SYSTEM SET max_standby_streaming_delay = '$DELAY'"
$S -q -c "ALTER SYSTEM SET hot_standby_feedback = '$FEEDBACK'"
$S -q -c "SELECT pg_reload_conf()"
sleep 1
$S -c "SHOW max_standby_streaming_delay" > "$OUT/settings.txt"
$S -c "SHOW hot_standby_feedback"       >> "$OUT/settings.txt"

$S -q -c "SELECT pg_stat_reset_shared('recovery_prefetch')" 2>/dev/null || true

# --- длинный запрос на реплике ----------------------------------------
# Repeatable read: снимок держится всю транзакцию, конфликт гарантирован.
(
  $S -c "BEGIN ISOLATION LEVEL REPEATABLE READ;
         SELECT count(*) FROM pgbench_accounts;
         SELECT pg_sleep(20);
         SELECT count(*) FROM pgbench_accounts;
         COMMIT;" > "$OUT/standby-query.txt" 2>&1
) &
QJOB=$!
sleep 3

# --- на primary: обновление и очистка ----------------------------------
$P -q -c "UPDATE pgbench_accounts SET abalance = abalance + 1
          WHERE aid % 3 = 0"
$P -c "VACUUM (VERBOSE) pgbench_accounts" > "$OUT/primary-vacuum.txt" 2>&1

sleep 2
$P -c "SELECT application_name, state, replay_lag,
              backend_xmin, age(backend_xmin) AS xmin_age
       FROM pg_stat_replication" > "$OUT/replication.txt"

wait $QJOB 2>/dev/null || true

$S -c "SELECT confl_snapshot, confl_lock, confl_bufferpin, confl_deadlock
       FROM pg_stat_database_conflicts
       WHERE datname = 'postgres'" > "$OUT/conflicts.txt"

echo "=== настройки ===";            cat "$OUT/settings.txt"
echo "=== запрос на реплике ===";    tail -3 "$OUT/standby-query.txt"
echo "=== конфликты на реплике ==="; cat "$OUT/conflicts.txt"
echo "=== состояние репликации ==="; cat "$OUT/replication.txt"
echo "=== VACUUM на primary ==="
grep -E 'removed|removable|oldest xmin' "$OUT/primary-vacuum.txt" || true
