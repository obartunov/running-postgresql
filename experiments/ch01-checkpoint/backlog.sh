#!/bin/bash
# Диагностический прогон главы 1: темп поступления, темп завершения,
# накопленный backlog и дельты счётчиков - раз в секунду.
#
#   ./backlog.sh <тег> [длительность] [темп] [клиентов]
#
# Ничего не доказывает про чекпойнт сам по себе. Даёт величины, без
# которых утверждение 'чекпойнт снижает пропускную способность и
# порождает очередь' не проверяется ни в какую сторону.
set -euo pipefail
DB=${PGDATABASE:-ckpt_bench}
TAG="${1:?укажите тег прогона}"
DUR=${2:-240}; RATE=${3:-150}; CLIENTS=${4:-4}
OUT="results/backlog-$TAG"; mkdir -p "$OUT"

psql -X -d "$DB" -c "SHOW checkpoint_timeout" -c "SHOW max_wal_size" \
     -c "SHOW fsync" > "$OUT/settings.txt"
date +%s > "$OUT/start.epoch"

# посекундный сбор счётчиков рядом с нагрузкой
(
  echo -e "epoch\txact_commit\tckpt_timed\tckpt_req\tbuf_ckpt\twal_bytes\twal_records"
  while :; do
    psql -X -At -F $'\t' -d "$DB" -c "
      SELECT extract(epoch from now())::bigint,
             (SELECT sum(xact_commit) FROM pg_stat_database),
             (SELECT num_timed FROM pg_stat_checkpointer),
             (SELECT num_requested FROM pg_stat_checkpointer),
             (SELECT buffers_written FROM pg_stat_checkpointer),
             (SELECT wal_bytes FROM pg_stat_wal),
             (SELECT wal_records FROM pg_stat_wal)" 2>/dev/null || true
    sleep 1
  done
) > "$OUT/counters.tsv" &
SAMPLER=$!
trap 'kill $SAMPLER 2>/dev/null || true' EXIT

# -R задаёт расписание поступления; --latency-limit не ставим, чтобы
# опоздавшие транзакции не отбрасывались, а копились
pgbench -c "$CLIENTS" -j 1 -T "$DUR" -R "$RATE" -n \
        -l --log-prefix="$OUT/pg" "$DB" > "$OUT/pgbench.out" 2>&1

kill $SAMPLER 2>/dev/null || true
grep -E 'checkpoint (starting|complete)' "${PGLOG:-/dev/null}" > "$OUT/checkpoints.log" 2>/dev/null || \
  echo "лог сервера не скопирован: задайте PGLOG=<путь>" > "$OUT/checkpoints.log"

echo "готово: $OUT"
echo "разбор: python3 backlog.py $OUT"
