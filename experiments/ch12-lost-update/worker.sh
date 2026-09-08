#!/bin/bash
# Один воркер: N раз прибавляет 1 к балансу выбранным способом.
#   $1 = режим, $2 = число итераций
set -euo pipefail
MODE="$1"; ITER="$2"
DB=${PGDATABASE:-orm_bench}

case "$MODE" in
  # 1. Read-modify-write в приложении, READ COMMITTED.
  #    Ровно то, что делает ORM: SELECT, +1 в языке, UPDATE.
  rmw)
    for _ in $(seq 1 "$ITER"); do
      psql -X -q -d "$DB" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
BEGIN;
SELECT balance AS b FROM accounts WHERE id = 1 \gset
UPDATE accounts SET balance = :b + 1, version = version + 1 WHERE id = 1;
COMMIT;
SQL
    done ;;

  # 2. То же, но с optimistic locking по колонке version —
  #    так делает ORM, когда ему объяснили.
  optimistic)
    for _ in $(seq 1 "$ITER"); do
      while :; do
        OUT=$(psql -X -At -d "$DB" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
SELECT balance, version FROM accounts WHERE id = 1 \gset acc_
UPDATE accounts SET balance = :acc_balance + 1, version = :acc_version + 1
 WHERE id = 1 AND version = :acc_version;
SELECT CASE WHEN pg_catalog.pg_stat_get_xact_tuples_updated('accounts'::regclass) > 0
            THEN 'ok' ELSE 'retry' END;
COMMIT;
SQL
        ) || true
        echo "$OUT" | grep -q ok && break
      done
    done ;;

  # 3. Инвариант выражен в SQL: база сама читает и пишет.
  sql)
    for _ in $(seq 1 "$ITER"); do
      psql -X -q -d "$DB" -c \
        "UPDATE accounts SET balance = balance + 1, version = version + 1
          WHERE id = 1" >/dev/null
    done ;;

  # 4. Тот же read-modify-write, но под явной блокировкой строки.
  forupdate)
    for _ in $(seq 1 "$ITER"); do
      psql -X -q -d "$DB" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
BEGIN;
SELECT balance AS b FROM accounts WHERE id = 1 FOR UPDATE \gset
UPDATE accounts SET balance = :b + 1, version = version + 1 WHERE id = 1;
COMMIT;
SQL
    done ;;

  # 5. Тот же read-modify-write, но на REPEATABLE READ.
  #    Потерь не будет: база откажется применять второе обновление.
  #    Цена переезжает из тихой порчи данных в видимые повторы.
  rmw-rr)
    RETRIES=0
    for _ in $(seq 1 "$ITER"); do
      until psql -X -q -d "$DB" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null 2>&1
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT balance AS b FROM accounts WHERE id = 1 \gset
UPDATE accounts SET balance = :b + 1, version = version + 1 WHERE id = 1;
COMMIT;
SQL
      do RETRIES=$((RETRIES+1)); done
    done
    echo "$RETRIES" >> "${RETRY_FILE:-/dev/null}" ;;

  *) echo "неизвестный режим: $MODE" >&2; exit 2 ;;
esac
