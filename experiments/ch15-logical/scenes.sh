#!/bin/bash
# Три сцены главы 13, воспроизводимые детерминированно.
set -euo pipefail
BASE=${BASE:-/tmp/ch13}
PPORT=${PPORT:-55462}; SPORT=${SPORT:-55463}
P="psql -X -h 127.0.0.1 -p $PPORT -d postgres"
S="psql -X -h 127.0.0.1 -p $SPORT -d postgres"
mkdir -p results

echo "=========== СЦЕНА 1: последовательности остались дома ==========="
$P -c "SELECT last_value AS pub_seq FROM orders_id_seq"
$S -c "SELECT last_value AS sub_seq FROM orders_id_seq"
$S -c "SELECT max(id) AS max_id_on_subscriber FROM orders"
echo "Строки приехали, счётчик последовательности - нет."

echo
echo "=========== СЦЕНА 4: таблица без первичного ключа ==========="
echo "--- INSERT доезжает ---"
$P -q -c "INSERT INTO nokey VALUES (99999, 'x')"; sleep 2
$S -c "SELECT count(*) AS nokey_rows FROM nokey"
echo "--- UPDATE падает на публикаторе ---"
# psql возвращает ненулевой код на ожидаемой ошибке - это часть
# демонстрации, а не сбой стенда.
$P -c "UPDATE nokey SET payload = 'y' WHERE id = 99999" 2>&1 | head -3 || true

echo "--- цена REPLICA IDENTITY FULL, измеренная на ОДНОЙ таблице ---"
# Сравнивать надо один и тот же UPDATE одной и той же таблицы до и
# после смены идентификатора реплики. Две разные таблицы сравнивать
# бессмысленно: разная ширина строки и разный набор индексов.
wal_for() {
  local L0 L1
  L0=$($P -At -c "SELECT pg_current_wal_lsn()")
  $P -q -c "$1"
  L1=$($P -At -c "SELECT pg_current_wal_lsn()")
  $P -At -c "SELECT pg_wal_lsn_diff('$L1','$L0')"
}
W_KEY=$(wal_for "UPDATE orders SET status='touched-a' WHERE id <= 5000")
$P -q -c "ALTER TABLE orders REPLICA IDENTITY FULL"
W_FULL=$(wal_for "UPDATE orders SET status='touched-b' WHERE id <= 5000")
$P -q -c "ALTER TABLE orders REPLICA IDENTITY DEFAULT"
printf 'та же таблица, тот же UPDATE 5000 строк:\n  по первичному ключу:   %s Б\n  REPLICA IDENTITY FULL: %s Б\n' \
  "$W_KEY" "$W_FULL" | tee results/replica-identity.txt

echo
echo "=========== СЦЕНА 5: тишина ==========="
# Ключ, которого заведомо нет ни на одной стороне: иначе повторный
# прогон стенда упирается в собственный прошлый конфликт.
NEXT=$(( $($P -At -c "SELECT max(id) FROM orders") + 1000 ))
$S -q -c "DELETE FROM orders WHERE id >= $NEXT" 2>/dev/null || true
echo "вставляем на ПОДПИСЧИКЕ строку с ключом $NEXT, который сейчас придёт"
$S -q -c "INSERT INTO orders (id, status) VALUES ($NEXT, 'local')"
$P -q -c "INSERT INTO orders (id, status) VALUES ($NEXT, 'from-publisher')" || true
sleep 5
$P -q -c "INSERT INTO orders (status) SELECT 'after' FROM generate_series(1,100)"
sleep 5

echo "--- публикатор: всё хорошо ---"
$P -c "SELECT count(*) AS rows_on_publisher FROM orders"
echo "--- подписчик: данные перестали приходить ---"
$S -c "SELECT count(*) AS rows_on_subscriber FROM orders"
$S -c "SELECT subname, apply_error_count, sync_error_count
       FROM pg_stat_subscription_stats"
echo "--- слот на публикаторе копит WAL ---"
$P -c "SELECT slot_name, active,
              pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
                AS wal_kept
       FROM pg_replication_slots"
echo "--- из лога подписчика ---"
grep -E 'ERROR|conflict|duplicate' "$BASE/sub.log" | tail -3 || true

cat <<'TXT'

Обратите внимание, что заметить это можно только со стороны подписчика
или по слоту публикатора. Ни одна метрика публикатора, кроме слота,
ничего не показывает.

Убрать за собой: ./make-pair.sh clean
TXT
