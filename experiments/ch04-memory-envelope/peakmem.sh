#!/bin/bash
# Пиковая память бэкенда (VmHWM) при разных work_mem.
#
#   ./peakmem.sh            # как настроен сервер
#   ./peakmem.sh serial     # без параллельных воркеров
#
# Требование: PostgreSQL работает на этой же машине - скрипт читает
# /proc/<pid>/status. В managed-окружении измерение так не сделать.
#
# Каждое измерение идёт в НОВОМ соединении: VmHWM не сбрасывается
# внутри живого процесса.
set -euo pipefail

DB=${PGDATABASE:-mem_bench}
MODE="${1:-parallel}"
SERIAL=false; [ "$MODE" = "serial" ] && SERIAL=true
STEPS=${STEPS:-"4MB 16MB 64MB 256MB"}
OUT="results/$MODE"; mkdir -p "$OUT"

printf 'work_mem\tVmHWM_kB\n' | tee "$OUT/peak.tsv"

for WM in $STEPS; do
  psql -X -q -d "$DB" -v wm="$WM" -v serial="$SERIAL" -f measure.psql \
       > /dev/null 2>&1 &
  JOB=$!

  PID=""
  for _ in $(seq 1 1200); do
    PID=$(psql -X -At -d "$DB" -c \
      "SELECT pid FROM pg_stat_activity
       WHERE application_name = 'ch04-peak'
         AND query LIKE '%pg_sleep%' LIMIT 1")
    [ -n "$PID" ] && break
    sleep 0.5
  done

  if [ -z "$PID" ]; then
    printf '%s\t?\n' "$WM" | tee -a "$OUT/peak.tsv"
  else
    HWM=$(awk '/VmHWM/ {print $2}' "/proc/$PID/status" 2>/dev/null || echo '?')
    printf '%s\t%s\n' "$WM" "$HWM" | tee -a "$OUT/peak.tsv"
  fi
  wait $JOB 2>/dev/null || true
done

cat <<'TXT'

Множитель = (прирост VmHWM) / (прирост work_mem), считать по крайним
точкам: на маленьких значениях шум больше самого эффекта.

Воркеры в эту цифру НЕ входят: у каждого свой процесс и свой VmHWM.
Разница между прогонами parallel и serial показывает вклад лидера;
полную картину даёт сумма по процессам одного запроса.
TXT
