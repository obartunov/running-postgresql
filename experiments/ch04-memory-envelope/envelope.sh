#!/bin/bash
# Concurrency envelope: как ведёт себя память, когда одинаковых тяжёлых
# запросов становится N.
#
#   ./envelope.sh                 # 1 2 4 8 одновременных запросов
#   CONC="1 2 4" WM=128MB ./envelope.sh
#
# Требование: PostgreSQL на этой же машине (читаем /proc).
# ВНИМАНИЕ: доводить до отказа можно только на выбрасываемой машине или
# в контейнере с заданным лимитом памяти.
set -euo pipefail

DB=${PGDATABASE:-mem_bench}
CONC=${CONC:-"1 2 4 8"}
WM=${WM:-64MB}
OUT="results/envelope-$WM"; mkdir -p "$OUT"

printf 'одновременных\tсумма VmHWM, MB\tмакс, MB\tна запрос, MB\tсекунд\n' \
  | tee "$OUT/envelope.tsv"

for N in $CONC; do
  T0=$(date +%s.%N)
  for i in $(seq 1 "$N"); do
    psql -X -q -d "$DB" -v wm="$WM" -v serial=false -f measure.psql \
      > /dev/null 2>&1 &
  done

  # дождаться, пока все N сессий доберутся до паузы, и снять их VmHWM
  PIDS=""
  for _ in $(seq 1 1200); do
    PIDS=$(psql -X -At -d "$DB" -c "
      SELECT string_agg(pid::text, ' ')
        FROM pg_stat_activity
       WHERE application_name = 'ch04-peak' AND query LIKE '%pg_sleep%'")
    [ "$(echo $PIDS | wc -w)" -ge "$N" ] && break
    sleep 0.5
  done

  SUM=0; MAX=0
  for P in $PIDS; do
    K=$(awk '/VmHWM/ {print $2}' "/proc/$P/status" 2>/dev/null || echo 0)
    SUM=$((SUM + K)); [ "$K" -gt "$MAX" ] && MAX=$K
  done
  wait
  T1=$(date +%s.%N)

  printf '%s\t%s\t%s\t%s\t%.1f\n' "$N" $((SUM/1024)) $((MAX/1024)) \
    $((SUM/1024/N)) "$(echo "$T1-$T0" | bc)" | tee -a "$OUT/envelope.tsv"
done

cat <<'TXT'

Сумма VmHWM — только ведущие процессы. Память параллельных воркеров
сюда не входит: у каждого свой процесс. Полная картина одного запроса
даётся планом (см. explain.sh), а этот стенд отвечает на другой вопрос:
как растёт суммарная память, когда таких запросов становится больше.

Если хотите увидеть отказ, а не экстраполяцию, поднимайте кластер под
лимитом памяти на выбрасываемой машине:
  systemd-run --scope -p MemoryMax=2G --user pg_ctl -D "$PGDATA" start
TXT
