#!/bin/sh
set -eu

PSQL=${PSQL:-psql}
DB=${DB:-postgres}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TRACE=${TRACE:-"$HERE/trace.log"}

"$PSQL" -X -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/setup.sql"

"$PSQL" -X -v ON_ERROR_STOP=1 -d "$DB" -f "$HERE/demo.sql" \
    >"$TRACE" 2>&1

cat "$TRACE"
echo
"$HERE/analyze.sh" "$TRACE"
