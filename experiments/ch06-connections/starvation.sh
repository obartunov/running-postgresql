#!/bin/bash
# Ёмкость, съеденная удержанием, а не работой.
#
# Открывает N транзакций, которые сделали один SELECT и ушли думать,
# и показывает состояние базы: сессии есть, работы нет.
#
# Если у вас поднят PgBouncer с pool_mode = transaction, запустите то
# же самое через него и посмотрите SHOW POOLS: cl_waiting будет расти
# при незагруженной базе. Это и есть диагноз из 6.6.
set -euo pipefail

DB=${PGDATABASE:-conn_bench}
N=${1:-10}
HOLD=${HOLD:-30}
mkdir -p results

FIFOS=(); PIDS=()
cleanup() {
  for f in "${FIFOS[@]:-}"; do rm -f "$f"; done
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

echo "открываю $N транзакций, которые ничего не делают..."
for i in $(seq 1 "$N"); do
  F=$(mktemp -u); mkfifo "$F"; FIFOS+=("$F")
  psql -X -q -d "$DB" -f - < "$F" > /dev/null 2>&1 &
  PIDS+=($!)
  exec {fd}>"$F"
  printf "SET application_name='holder-%s';\nBEGIN;\nSELECT 1;\n" "$i" >&$fd
  eval "exec $fd>&-"
done

sleep 3

psql -X -d "$DB" <<'SQL' | tee results/starvation.txt
SELECT state, count(*)
FROM pg_stat_activity
WHERE backend_type = 'client backend'
GROUP BY state ORDER BY 2 DESC;

SELECT count(*) AS active_queries
FROM pg_stat_activity
WHERE backend_type = 'client backend' AND state = 'active';
SQL

cat <<TXT

Слоты заняты, активных запросов почти нет. В прямом подключении это
съеденные max_connections; за пулером в режиме транзакций - съеденный
пул, и клиенты встают в cl_waiting при простаивающей базе.

Транзакции закроются через $HOLD с или при выходе из скрипта.
TXT
sleep "$HOLD"
