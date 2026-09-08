#!/bin/bash
# Три сценария главы 2.
#   ./scenario.sh A   -- никто не мешает
#   ./scenario.sh B   -- открытая транзакция REPEATABLE READ
#   ./scenario.sh C   -- брошенная PREPARE TRANSACTION
#
# Выполняется на выбрасываемой базе. Сценарий C оставляет
# подготовленную транзакцию до конца прогона и откатывает её сам;
# при прерывании проверьте pg_prepared_xacts руками.
set -euo pipefail

DB=${PGDATABASE:-vac_bench}
TAG="${1:?укажите сценарий: A, B или C}"
OUT="results/$TAG"; mkdir -p "$OUT"
ROUNDS=${ROUNDS:-5}

# Преflight: остатки прошлого прогона держат горизонт и блокируют
# DROP TABLE в setup.sql. Без этой уборки второй запуск висит навсегда.
psql -X -q -d "$DB" -c "
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity
   WHERE application_name = 'ch02-holder' AND pid <> pg_backend_pid()" > /dev/null
psql -X -At -d "$DB" -c "SELECT gid FROM pg_prepared_xacts WHERE gid LIKE 'ch02%'" \
  | while read -r g; do [ -n "$g" ] && psql -X -q -d "$DB" -c "ROLLBACK PREPARED '$g'"; done

# lock_timeout, чтобы подготовка падала с внятной ошибкой, а не висела
# (правило главы 3, применённое к собственному стенду)
if ! PGOPTIONS='-c lock_timeout=10s' psql -X -v ON_ERROR_STOP=1 -d "$DB" \
       -f setup.sql > "$OUT/setup.log" 2>&1; then
  cat "$OUT/setup.log"
  cat >&2 <<'HINT'

Подготовка не смогла взять блокировку на orders. Почти наверняка жив
держатель от прерванного прогона. Найти и снять:

  SELECT pid, state, application_name, now()-xact_start AS age,
         left(query, 60)
    FROM pg_stat_activity
   WHERE backend_type = 'client backend' AND pid <> pg_backend_pid();

  SELECT pg_terminate_backend(<pid>);
  SELECT gid FROM pg_prepared_xacts;   -- и ROLLBACK PREPARED для остатков
HINT
  exit 1
fi 
psql -X -d "$DB" -f measure.sql > "$OUT/00-before.txt"
# Файлы накапливаются построчно по раундам - обнуляем, иначе прогоны
# склеиваются и таблица размеров врёт.
: > "$OUT/size.txt"; : > "$OUT/horizon.txt"

HOLDER_FD=""
cleanup() {
  # Закрываем канал: сессия сама завершает транзакцию и выходит.
  [ -n "$HOLDER_FD" ] && eval "exec $HOLDER_FD>&-" 2>/dev/null || true
  psql -X -q -d "$DB" -c "ROLLBACK PREPARED 'ch02_orphan'" 2>/dev/null || true
  # Страховка: kill клиента не убивает бэкенд, если тот спит внутри
  # сервера, поэтому снимаем его явно.
  psql -X -q -d "$DB" -c "
    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
     WHERE application_name = 'ch02-holder' AND pid <> pg_backend_pid()" > /dev/null 2>&1 || true
}
trap cleanup EXIT

case "$TAG" in
  A) : ;;
  B) # Держатель горизонта: открытая транзакция, которая ничего не
     # делает. Пауза держится НА КЛИЕНТЕ через канал: сессия остаётся
     # в состоянии idle in transaction, как в сцене главы, и умирает
     # вместе со скриптом. Серверный pg_sleep() сделал бы её active и
     # пережил бы скрипт, отравив следующий прогон.
     FIFO=$(mktemp -u); mkfifo "$FIFO"
     psql -X -q -d "$DB" -f - < "$FIFO" > "$OUT/holder.txt" 2>&1 &
     exec {HOLDER_FD}>"$FIFO"; rm -f "$FIFO"
     printf "SET application_name='ch02-holder';\nBEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT count(*) FROM orders;\n" >&$HOLDER_FD
     sleep 3 ;;
  C) # держатель горизонта: подготовленная транзакция.
     # Сессии нет, в pg_stat_activity пусто. В этом весь смысл.
     psql -X -q -d "$DB" <<'SQL'
BEGIN;
UPDATE orders SET status = 'prep' WHERE id = 1;
PREPARE TRANSACTION 'ch02_orphan';
SQL
     ;;
esac

for i in $(seq 1 "$ROUNDS"); do
  psql -X -q -d "$DB" -f load.sql
  psql -X -d "$DB" -c "VACUUM (VERBOSE) orders" > "$OUT/vacuum-$i.txt" 2>&1
  psql -X -d "$DB" -f measure.sql   >> "$OUT/size.txt"
  psql -X -d "$DB" -f horizon.sql   >> "$OUT/horizon.txt"
  # Именно строка tuples:, а не pages: - нас интересуют версии строк,
  # а не страницы. Формулировки различаются между версиями сервера,
  # поэтому берём обе, если нашлись.
  echo "round $i: $(grep -oE 'tuples: .*' "$OUT/vacuum-$i.txt" | head -1)"
  grep -oE 'removable cutoff:.*|oldest xmin:.*' "$OUT/vacuum-$i.txt" \
    | head -1 | sed 's/^/         /'
done

psql -X -d "$DB" -f measure.sql > "$OUT/99-after.txt"
echo "готово: $OUT"
