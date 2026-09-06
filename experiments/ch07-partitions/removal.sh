#!/bin/bash
# Что вы покупаете: удаление месяца двумя способами.
# Меряем время, WAL, размер после и работу, оставленную для VACUUM.
set -euo pipefail
DB=${PGDATABASE:-part_bench}
mkdir -p results

MONTH=$(psql -X -At -d "$DB" -c \
  "SELECT to_char(date_trunc('month', now()) - interval '11 months', 'YYYY_MM')")
LO=$(psql -X -At -d "$DB" -c \
  "SELECT (date_trunc('month', now()) - interval '11 months')::date")
HI=$(psql -X -At -d "$DB" -c \
  "SELECT (date_trunc('month', now()) - interval '10 months')::date")

measure() {  # $1 = метка, $2 = SQL
  local lsn0 lsn1 t0 t1
  lsn0=$(psql -X -At -d "$DB" -c "SELECT pg_current_wal_lsn()")
  t0=$(date +%s.%N)
  psql -X -q -d "$DB" -c "$2"
  t1=$(date +%s.%N)
  lsn1=$(psql -X -At -d "$DB" -c "SELECT pg_current_wal_lsn()")
  local wal
  wal=$(psql -X -At -d "$DB" -c \
    "SELECT pg_size_pretty(pg_wal_lsn_diff('$lsn1','$lsn0'))")
  printf '%s\tвремя %.2f с\tWAL %s\n' "$1" "$(echo "$t1-$t0"|bc)" "$wal"
}

{
  echo "=== до ==="
  psql -X -d "$DB" -c "
    SELECT 'plain' AS t, pg_size_pretty(pg_total_relation_size('events_plain')) AS size
    UNION ALL
    SELECT 'part', pg_size_pretty(sum(pg_total_relation_size(i.inhrelid)))
      FROM pg_inherits i WHERE i.inhparent = 'events_part'::regclass"

  echo "=== удаление месяца $MONTH ==="
  measure "DELETE (обычная)  " \
    "DELETE FROM events_plain WHERE created >= '$LO' AND created < '$HI'"
  measure "DETACH+DROP (секц)" \
    "ALTER TABLE events_part DETACH PARTITION events_part_$MONTH;
     DROP TABLE events_part_$MONTH"

  echo "=== сразу после ==="
  psql -X -d "$DB" -c "
    SELECT relname, n_dead_tup,
           pg_size_pretty(pg_total_relation_size(relid)) AS size
    FROM pg_stat_user_tables
    WHERE relname IN ('events_plain') OR relname LIKE 'events_part%'
    ORDER BY relname"

  echo "=== работа, оставленная для VACUUM (только обычная таблица) ==="
  psql -X -d "$DB" -c "VACUUM (VERBOSE) events_plain" 2>&1 \
    | grep -E 'removed|removable' || true

  echo "=== после VACUUM ==="
  psql -X -d "$DB" -c "
    SELECT pg_size_pretty(pg_total_relation_size('events_plain')) AS plain_after"
} | tee results/removal.txt

cat <<'TXT'

Размер обычной таблицы после VACUUM почти не уменьшится: место
освобождено внутрь таблицы, а не отдано системе (глава 2, раздел 2.7).
У секционированной таблицы место вернулось в момент DROP.
TXT
