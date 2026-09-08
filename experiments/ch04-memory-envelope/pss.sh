#!/bin/bash
# Одновременный снимок памяти всех бэкендов: Pss из smaps_rollup.
#
#   ./pss.sh <число одновременных запросов> [work_mem]
#
# В отличие от VmHWM, здесь берётся мгновенное состояние: сумма Pss по
# всем процессам сервера в один момент. Pss делит разделяемые страницы
# между процессами, поэтому сумма не завышена повторным учётом.
#
# Требование: PostgreSQL на этой же машине.
set -euo pipefail
DB=${PGDATABASE:-mem_bench}
N=${1:-4}; WM=${2:-64MB}
OUT="results/pss"; mkdir -p "$OUT"

for i in $(seq 1 "$N"); do
  psql -X -q -d "$DB" -v wm="$WM" -v serial=false -f measure.psql >/dev/null 2>&1 &
done

BEST=0; BEST_N=0
for _ in $(seq 1 2400); do
  PIDS=$(psql -X -At -d "$DB" -c "
    SELECT string_agg(pid::text, ' ') FROM pg_stat_activity
     WHERE backend_type IN ('client backend','parallel worker')" 2>/dev/null || true)
  SUM=0; CNT=0
  for P in $PIDS; do
    K=$(awk '/^Pss:/ {s+=$2} END {print s+0}' "/proc/$P/smaps_rollup" 2>/dev/null || echo 0)
    SUM=$((SUM + K)); CNT=$((CNT + 1))
  done
  [ "$SUM" -gt "$BEST" ] && { BEST=$SUM; BEST_N=$CNT; }
  jobs -rp | grep -q . || break
  sleep 0.25
done
wait

printf 'одновременных: %s   work_mem: %s\n' "$N" "$WM" | tee "$OUT/pss-$N-$WM.txt"
printf 'пиковая сумма Pss по процессам сервера: %s MB (процессов в пике: %s)\n' \
  $((BEST/1024)) "$BEST_N" | tee -a "$OUT/pss-$N-$WM.txt"

cat <<'TXT'

Это мгновенный снимок, а не сумма исторических максимумов: в него
входят и параллельные воркеры, а разделяемые страницы не учитываются
повторно. Сравнивать с VmHWM из peakmem.sh напрямую нельзя — это
разные величины.
TXT
