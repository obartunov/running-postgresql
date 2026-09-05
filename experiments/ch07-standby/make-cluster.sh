#!/bin/bash
# Primary и реплика на одной машине, на двух портах.
# Всё создаётся в BASE (по умолчанию /tmp/ch07) и удаляется одной
# командой: ./make-cluster.sh clean
set -euo pipefail

BASE=${BASE:-/tmp/ch07}
PRIMARY="$BASE/primary"
STANDBY="$BASE/standby"
PPORT=${PPORT:-55432}
SPORT=${SPORT:-55433}

if [ "${1:-}" = "clean" ]; then
  pg_ctl -D "$STANDBY" -m immediate stop 2>/dev/null || true
  pg_ctl -D "$PRIMARY" -m immediate stop 2>/dev/null || true
  rm -rf "$BASE"; echo "очищено"; exit 0
fi

rm -rf "$BASE"; mkdir -p "$BASE"

initdb -D "$PRIMARY" -U "$USER" --no-sync > "$BASE/initdb.log"

cat >> "$PRIMARY/postgresql.conf" <<EOF
port = $PPORT
wal_level = replica
max_wal_senders = 4
max_replication_slots = 4
log_checkpoints = off
listen_addresses = 'localhost'
unix_socket_directories = '$BASE'
EOF
echo "host replication all 127.0.0.1/32 trust" >> "$PRIMARY/pg_hba.conf"

pg_ctl -D "$PRIMARY" -l "$BASE/primary.log" start
psql -h 127.0.0.1 -p "$PPORT" -d postgres -c \
  "SELECT pg_create_physical_replication_slot('standby1')" > /dev/null

pg_basebackup -h 127.0.0.1 -p "$PPORT" -D "$STANDBY" -R -X stream -c fast

cat >> "$STANDBY/postgresql.conf" <<EOF
port = $SPORT
hot_standby = on
primary_slot_name = 'standby1'
unix_socket_directories = '$BASE'
# значения по умолчанию для прогона 1; меняются в conflict.sh
max_standby_streaming_delay = 0
hot_standby_feedback = off
EOF

pg_ctl -D "$STANDBY" -l "$BASE/standby.log" start
sleep 2

psql -h 127.0.0.1 -p "$PPORT" -d postgres -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication"
psql -h 127.0.0.1 -p "$SPORT" -d postgres -c "SELECT pg_is_in_recovery()"

pgbench -h 127.0.0.1 -p "$PPORT" -i -s "${SCALE:-20}" postgres > /dev/null 2>&1
psql -h 127.0.0.1 -p "$PPORT" -d postgres -c \
  "ALTER TABLE pgbench_accounts SET (autovacuum_enabled = off)"

cat <<TXT

primary:  порт $PPORT   каталог $PRIMARY
standby:  порт $SPORT   каталог $STANDBY
логи:     $BASE/*.log

Дальше: ./conflict.sh 1 | 2 | 3
Удалить всё: ./make-cluster.sh clean
TXT
