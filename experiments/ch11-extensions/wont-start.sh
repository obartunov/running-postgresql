#!/bin/bash
# Упражнение: сервер, который не стартует из-за preload-библиотеки,
# и восстановление без работающего сервера.
#
# Отдельный выбрасываемый кластер в /tmp/ch11. Вашу установку не трогает.
set -euo pipefail

BASE=${BASE:-/tmp/ch11}
DATA="$BASE/data"
PORT=${PORT:-55452}

if [ "${1:-}" = "clean" ]; then
  pg_ctl -D "$DATA" -m immediate stop 2>/dev/null || true
  rm -rf "$BASE"; echo "очищено"; exit 0
fi

rm -rf "$BASE"; mkdir -p "$BASE"
initdb -D "$DATA" -U "$USER" --no-sync > "$BASE/initdb.log"
cat >> "$DATA/postgresql.conf" <<EOF
port = $PORT
unix_socket_directories = '$BASE'
listen_addresses = 'localhost'
EOF

pg_ctl -D "$DATA" -l "$BASE/pg.log" -w start
echo "кластер поднят на порту $PORT"

echo
echo "=== ломаем: preload-библиотека, которой нет ==="
psql -X -q -h 127.0.0.1 -p "$PORT" -d postgres -c \
  "ALTER SYSTEM SET shared_preload_libraries = 'sometool_that_does_not_exist'"
pg_ctl -D "$DATA" -m fast stop

if pg_ctl -D "$DATA" -l "$BASE/pg.log" -w -t 10 start; then
  echo "неожиданно поднялся — посмотрите $BASE/pg.log"
else
  echo "сервер не поднялся, как и ожидалось. Из лога:"
  tail -3 "$BASE/pg.log"
fi

echo
echo "=== чинить нечем: psql подключиться некуда ==="
psql -X -h 127.0.0.1 -p "$PORT" -d postgres -c "SELECT 1" 2>&1 | head -2 || true

echo
echo "=== лечение: правка postgresql.auto.conf на диске ==="
echo "--- было ---"; cat "$DATA/postgresql.auto.conf"
grep -v shared_preload_libraries "$DATA/postgresql.auto.conf" > "$BASE/auto.tmp"
mv "$BASE/auto.tmp" "$DATA/postgresql.auto.conf"
echo "--- стало ---"; cat "$DATA/postgresql.auto.conf"

pg_ctl -D "$DATA" -l "$BASE/pg.log" -w start
psql -X -h 127.0.0.1 -p "$PORT" -d postgres -c "SELECT 'сервер вернулся' AS status"

cat <<TXT

Запомнить из этого упражнения:
  - ALTER SYSTEM пишет в \$PGDATA/postgresql.auto.conf;
  - при отказе старта чинится только правкой файла на диске;
  - значит, доступ к файловой системе сервера — часть плана
    восстановления. В управляемом окружении его нет.

Убрать за собой: ./wont-start.sh clean
TXT
