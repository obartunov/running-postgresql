#!/bin/bash
# Один прогон. Конфиг применяется вручную (см. README) - скрипт только
# фиксирует, что реально стоит в сервере на момент запуска.
#
#   ./run.sh A
set -euo pipefail
. "$(dirname "$0")/env.sh"

TAG="${1:?укажите тег прогона: A, B или C}"
OUT="$RESULTS/$TAG"
mkdir -p "$OUT"

# 1. Зафиксировать окружение: без этого результат не воспроизводим.
psql -X -c "SELECT version()"                        > "$OUT/version.txt"
psql -X -c "SELECT name, setting, source FROM pg_settings
            WHERE name IN ('shared_buffers','checkpoint_timeout',
                           'max_wal_size','min_wal_size',
                           'checkpoint_completion_target',
                           'full_page_writes','wal_compression',
                           'checkpoint_flush_after','wal_level')
            ORDER BY name"                           > "$OUT/settings.txt"
uname -a                                             > "$OUT/host.txt"
cat /proc/sys/vm/dirty_ratio /proc/sys/vm/dirty_background_ratio \
    >> "$OUT/host.txt" 2>/dev/null || true

# 2. Чистая точка отсчёта.
psql -X -q -c "SELECT pg_stat_reset_shared('checkpointer')" 2>/dev/null \
  || psql -X -q -c "SELECT pg_stat_reset_shared('bgwriter')"
psql -X -q -c "CHECKPOINT"
psql -X -f collect.sql                               > "$OUT/before.txt"

# 3. Нагрузка. -l пишет посырому каждую транзакцию: без этого
#    невозможно посчитать перцентили по окнам.
pgbench -c "$CLIENTS" -j "$JOBS" -T "$DURATION" -R "$RATE" -P 10 \
        -l --log-prefix="$OUT/pgbench" \
        "$PGDATABASE" 2>&1 | tee "$OUT/pgbench.out"

# 4. Итоговые счётчики и лог сервера.
psql -X -f collect.sql                               > "$OUT/after.txt"
echo "Скопируйте сюда строки 'checkpoint starting/complete' из лога сервера:"
echo "  grep checkpoint <postgresql.log> > $OUT/checkpoints.log"
