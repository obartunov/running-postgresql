#!/bin/bash
set -euo pipefail
DB=${PGDATABASE:-conn_bench}
# Масштаб небольшой намеренно: нужно, чтобы данные помещались в
# shared_buffers. Иначе кривая упрётся в диск, и мы измерим не то.
pgbench -i -s "${SCALE:-50}" "$DB"
psql -X -d "$DB" -c "SELECT pg_size_pretty(pg_database_size(current_database()))"
psql -X -d "$DB" -c "SHOW shared_buffers"
