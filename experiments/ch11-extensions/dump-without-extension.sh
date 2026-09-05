#!/bin/bash
# Что означает 'расширение стало частью формата данных'.
# Дамп базы с триграммным индексом восстанавливается туда, где
# расширения нет.
set -euo pipefail

SRC=${SRC:-ext_src}
DST=${DST:-ext_dst}
mkdir -p results

dropdb --if-exists "$SRC"; dropdb --if-exists "$DST"
createdb "$SRC"; createdb "$DST"

psql -X -q -d "$SRC" <<'SQL'
CREATE EXTENSION pg_trgm;
CREATE TABLE names (id bigserial PRIMARY KEY, name text NOT NULL);
INSERT INTO names (name)
SELECT 'наименование ' || g FROM generate_series(1, 50000) g;
CREATE INDEX names_trgm ON names USING gin (name gin_trgm_ops);
SQL

echo "=== в исходной базе индекс работает ==="
psql -X -d "$SRC" -c "EXPLAIN (COSTS OFF)
  SELECT * FROM names WHERE name LIKE '%менован%'" | head -5

pg_dump -d "$SRC" -f results/dump.sql

echo
echo "=== восстанавливаем туда, где расширения нет ==="
if psql -X -v ON_ERROR_STOP=1 -d "$DST" -f results/dump.sql \
     > results/restore.log 2>&1; then
  echo "восстановилось (значит, расширение уже было установлено в $DST)"
else
  echo "ОТКАЗ. Первые строки ошибки:"
  grep -m3 -E 'ERROR|ОШИБКА' results/restore.log || tail -5 results/restore.log
fi

cat <<'TXT'

Дамп содержит CREATE EXTENSION, но не саму библиотеку. На сервере, где
расширения нет, восстановление останавливается — и остановится оно в
любой момент, когда вам понадобится поднять копию: на репетиции, при
переезде, в аварии.

Убрать за собой:
  dropdb ext_src; dropdb ext_dst
TXT
