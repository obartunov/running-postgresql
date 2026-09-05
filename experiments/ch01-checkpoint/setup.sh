#!/bin/bash
# Однократная подготовка базы. Отдельно от прогонов, чтобы время
# наполнения не попадало в измерения.
set -euo pipefail
. "$(dirname "$0")/env.sh"

createdb "$PGDATABASE" 2>/dev/null || true
pgbench -i -s "$SCALE" "$PGDATABASE"
psql -c "SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size" "$PGDATABASE"
psql -c "SHOW shared_buffers"
echo "Проверьте: размер базы должен быть в 4-6 раз больше shared_buffers."
