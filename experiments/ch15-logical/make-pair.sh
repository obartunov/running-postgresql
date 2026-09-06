#!/bin/bash
# Публикатор и подписчик на одной машине. Всё в BASE (/tmp/ch13).
set -euo pipefail
BASE=${BASE:-/tmp/ch13}
PUB="$BASE/pub"; SUB="$BASE/sub"
PPORT=${PPORT:-55462}; SPORT=${SPORT:-55463}

if [ "${1:-}" = "clean" ]; then
  pg_ctl -D "$SUB" -m immediate stop 2>/dev/null || true
  pg_ctl -D "$PUB" -m immediate stop 2>/dev/null || true
  rm -rf "$BASE"; echo "очищено"; exit 0
fi

rm -rf "$BASE"; mkdir -p "$BASE"
for D in "$PUB" "$SUB"; do
  initdb -D "$D" -U "$USER" --no-sync > "$BASE/initdb.log"
done

cat >> "$PUB/postgresql.conf" <<EOF
port = $PPORT
wal_level = logical
listen_addresses = 'localhost'
unix_socket_directories = '$BASE'
EOF
cat >> "$SUB/postgresql.conf" <<EOF
port = $SPORT
wal_level = logical
listen_addresses = 'localhost'
unix_socket_directories = '$BASE'
EOF
echo "host all all 127.0.0.1/32 trust" >> "$PUB/pg_hba.conf"

pg_ctl -D "$PUB" -l "$BASE/pub.log" -w start
pg_ctl -D "$SUB" -l "$BASE/sub.log" -w start

P="psql -X -q -h 127.0.0.1 -p $PPORT -d postgres"
S="psql -X -q -h 127.0.0.1 -p $SPORT -d postgres"

# схема одинаковая с обеих сторон: DDL не реплицируется, переносим сами
SCHEMA="
CREATE TABLE orders (id bigserial PRIMARY KEY, status text NOT NULL);
CREATE TABLE nokey  (id bigint, payload text);"
$P -c "$SCHEMA"
$S -c "$SCHEMA"

$P -c "INSERT INTO orders (status) SELECT 'new' FROM generate_series(1,10000)"
$P -c "INSERT INTO nokey SELECT g, md5(g::text) FROM generate_series(1,10000) AS g"

$P -c "CREATE PUBLICATION pub_all FOR ALL TABLES"
$S -c "CREATE SUBSCRIPTION sub_all
       CONNECTION 'host=127.0.0.1 port=$PPORT dbname=postgres user=$USER'
       PUBLICATION pub_all"

sleep 3
echo "публикатор: $PPORT   подписчик: $SPORT   каталоги в $BASE"
psql -X -h 127.0.0.1 -p "$SPORT" -d postgres -c \
  "SELECT count(*) AS orders_on_subscriber FROM orders"
