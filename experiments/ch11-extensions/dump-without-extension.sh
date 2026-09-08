#!/bin/bash
# Что означает 'расширение стало частью формата данных'.
#
# Две проверки, обе воспроизводимые на машине, где расширение есть:
#   1. расширение нельзя удалить - индекс от него зависит;
#   2. дамп не восстанавливается, если у восстанавливающего нет права
#      создать расширение (сценарий управляемых окружений и ролей).
#
# Третий случай - сервера, где библиотеки нет вовсе, - на этой машине
# не воспроизвести: дамп содержит CREATE EXTENSION, и на сервере с
# установленным contrib он просто выполнится. Отказ там наступает в той
# же строке дампа, только с другой ошибкой.
set -euo pipefail

SRC=${SRC:-ext_src}
DST=${DST:-ext_dst}
mkdir -p results

dropdb --if-exists "$SRC" >/dev/null; dropdb --if-exists "$DST" >/dev/null
createdb "$SRC"; createdb "$DST"

psql -X -q -d "$SRC" <<'SQL'
CREATE EXTENSION pg_trgm;
CREATE TABLE names (id bigserial PRIMARY KEY, name text NOT NULL);
INSERT INTO names (name)
SELECT 'наименование ' || g FROM generate_series(1, 50000) g;
CREATE INDEX names_trgm ON names USING gin (name gin_trgm_ops);
SQL

echo "=== 1. расширение больше не ваше решение ==="
# psql возвращает ненулевой код на ожидаемой ошибке - это часть
# демонстрации, а не сбой стенда.
psql -X -d "$SRC" -c "DROP EXTENSION pg_trgm" > results/drop.txt 2>&1 || true
head -4 results/drop.txt
echo
echo "--- что именно уедет вместе с ним ---"
psql -X -d "$SRC" -c "BEGIN; DROP EXTENSION pg_trgm CASCADE; ROLLBACK;" \
  >> results/drop.txt 2>&1 || true
grep -E 'drop cascades' results/drop.txt || true

echo
echo "=== 2. дамп в руках того, кто не может создать расширение ==="
pg_dump -d "$SRC" -f results/dump.sql
psql -X -q -d "$DST" <<'SQL'
DROP ROLE IF EXISTS ch11_restorer;
CREATE ROLE ch11_restorer LOGIN;
GRANT CREATE, USAGE ON SCHEMA public TO ch11_restorer;
SQL

if psql -X -U ch11_restorer -d "$DST" -v ON_ERROR_STOP=1 -f results/dump.sql \
     > results/restore.log 2>&1; then
  echo "восстановилось - у роли оказались права; проверьте GRANT"
else
  echo "ОТКАЗ на строке с расширением:"
  grep -m2 -E 'ERROR|ОШИБКА' results/restore.log
fi

psql -X -q -d "$DST" -c "DROP ROLE IF EXISTS ch11_restorer" 2>/dev/null || true

cat <<'TXT'

Первая проверка - главное. Индекс, построенный классом операторов из
расширения, делает расширение неудаляемым: сервер прямо называет
зависимость. Это и есть точка невозврата из 11.2, предъявленная
сервером, а не автором книги.

Убрать за собой:
  dropdb ext_src; dropdb ext_dst
TXT
