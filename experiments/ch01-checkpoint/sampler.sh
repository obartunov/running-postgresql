#!/bin/bash
# Посекундная выборка состояния во время прогона.
#
#   ./sampler.sh <файл> [секунд]
#
# ВНИМАНИЕ: запрос написан под PostgreSQL 16, где счётчики чекпойнтера
# ещё в pg_stat_bgwriter. Начиная с 17 они в pg_stat_checkpointer с
# другими именами (num_timed, num_requested, buffers_written).
#
# Пишет TSV: epoch, приросты счётчиков за секунду. Backlog считается не
# отсюда, а из лога pgbench (см. backlog.py): здесь только то, что видит
# сервер.
set -euo pipefail
OUT="${1:?укажите файл}"; DUR="${2:-300}"
DB=${PGDATABASE:-ckpt_bench}

printf 'epoch\txacts\twal_bytes\tckpt_timed\tckpt_req\tbuf_ckpt\tio_writes\tio_wtime\n' > "$OUT"
psql -X -At -d "$DB" -c "
  SELECT extract(epoch from now())::bigint,
         (SELECT sum(xact_commit+xact_rollback) FROM pg_stat_database),
         pg_current_wal_lsn() - '0/0',
         (SELECT checkpoints_timed FROM pg_stat_bgwriter),
         (SELECT checkpoints_req FROM pg_stat_bgwriter),
         (SELECT buffers_checkpoint FROM pg_stat_bgwriter),
         (SELECT coalesce(sum(writes),0) FROM pg_stat_io WHERE object='relation'),
         (SELECT coalesce(sum(write_time),0) FROM pg_stat_io WHERE object='relation')
" > /tmp/.sampler_prev

for _ in $(seq 1 "$DUR"); do
  sleep 1
  psql -X -At -d "$DB" -c "
    SELECT extract(epoch from now())::bigint,
           (SELECT sum(xact_commit+xact_rollback) FROM pg_stat_database),
           pg_current_wal_lsn() - '0/0',
           (SELECT checkpoints_timed FROM pg_stat_bgwriter),
           (SELECT checkpoints_req FROM pg_stat_bgwriter),
           (SELECT buffers_checkpoint FROM pg_stat_bgwriter),
           (SELECT coalesce(sum(writes),0) FROM pg_stat_io WHERE object='relation'),
           (SELECT coalesce(sum(write_time),0) FROM pg_stat_io WHERE object='relation')
  " > /tmp/.sampler_cur 2>/dev/null || continue
  python3 - "$OUT" <<'PY'
import sys
prev = open('/tmp/.sampler_prev').read().strip().split('|')
cur  = open('/tmp/.sampler_cur').read().strip().split('|')
if len(prev) == len(cur) == 8:
    d = [float(c) - float(p) for c, p in zip(cur, prev)]
    row = [cur[0]] + [f"{v:.0f}" for v in d[1:]]
    open(sys.argv[1], 'a').write("\t".join(row) + "\n")
PY
  cp /tmp/.sampler_cur /tmp/.sampler_prev
done
