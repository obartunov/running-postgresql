#!/bin/bash
# Кривая пропускной способности и задержки от числа одновременных
# клиентов. Ищем точку, после которой добавленные клиенты уходят
# в ожидание, а не в работу.
#
#   ./sweep.sh            # чтение (упор в CPU и конкуренцию)
#   ./sweep.sh write      # чтение+запись
#
# Подключаемся НАПРЯМУЮ к PostgreSQL, без пулера: измеряется предел
# самой базы, а не настройки пула.
set -euo pipefail

DB=${PGDATABASE:-conn_bench}
MODE="${1:-read}"
CLIENTS=${CLIENTS:-"1 2 4 8 16 32 64 128 256"}
DURATION=${DURATION:-60}
OUT="results/$MODE"; mkdir -p "$OUT"

FLAGS="-S"                      # только чтение
[ "$MODE" = "write" ] && FLAGS=""

CORES=$(nproc 2>/dev/null || echo '?')
{
  echo "# ядер: $CORES   режим: $MODE   длительность шага: ${DURATION}s"
  psql -X -At -d "$DB" -c "SELECT version()"
  psql -X -At -d "$DB" -c "SHOW shared_buffers"
  psql -X -At -d "$DB" -c "SHOW max_connections"
} > "$OUT/env.txt"

printf 'clients\ttps\tlat_avg_ms\tp99_ms\n' | tee "$OUT/sweep.tsv"

for C in $CLIENTS; do
  J=$(( C < 8 ? C : 8 ))
  rm -f "$OUT/pg-$C".*
  RES=$(pgbench $FLAGS -c "$C" -j "$J" -T "$DURATION" -n \
        -l --log-prefix="$OUT/pg-$C" "$DB" 2>&1)

  TPS=$(awk '/^tps =/ {print $3; exit}' <<<"$RES")
  LAT=$(awk '/^latency average/ {print $4; exit}' <<<"$RES")

  P99='-'
  if [ -x ../ch01-checkpoint/analyze.py ] || [ -f ../ch01-checkpoint/analyze.py ]; then
    P99=$(python3 ../ch01-checkpoint/analyze.py "$OUT/pg-$C" 3600 2>&1 >/dev/null \
          | awk -F'p99=' '/p99=/ {split($2,a," "); print a[1]}')
  fi

  printf '%s\t%s\t%s\t%s\n' "$C" "${TPS:-?}" "${LAT:-?}" "${P99:-?}" \
    | tee -a "$OUT/sweep.tsv"
done

cat <<'TXT'

Читать так:
  - точка, где tps перестаёт расти, — предел полезной одновременности;
  - после неё каждый добавленный клиент уходит в ожидание: tps стоит
    или падает, задержка растёт линейно;
  - разумный размер пула лежит около этой точки, а не около
    max_connections.

Если tps растёт до самого конца диапазона — увеличьте CLIENTS.
Если плато не наступает вовсе, а задержка растёт с первых шагов —
нагрузка упирается в диск, а не в конкуренцию; это другая глава.
TXT
