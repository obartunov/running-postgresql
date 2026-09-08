#!/bin/bash
# Снять трассу add_path() для одного запроса.
#
#   ./probe.sh "SELECT ..." [лог сервера]
#
# Требуется кластер, собранный с 0001-path-probe-instrument-add_path.patch
# и log_min_messages = debug1.
set -euo pipefail
Q="${1:?укажите запрос}"
LOG="${2:-$PGDATA/../pg.log}"
mkdir -p results

: > "$LOG"
psql -X -q -c "EXPLAIN $Q" > /dev/null
grep PATHPROBE "$LOG" > results/raw.txt || { echo "нет строк PATHPROBE: сборка без патча или log_min_messages не debug1" >&2; exit 1; }
python3 decode.py "$LOG" "${NODETAGS:-/tmp/pgsrc/src/include/nodes/nodetags.h}" \
  | tee results/trace.txt
