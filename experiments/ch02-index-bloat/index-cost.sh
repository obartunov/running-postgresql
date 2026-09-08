#!/bin/bash
# Во что обходится лишний индекс: WAL на транзакцию и доля HOT.
# Четыре варианта одной таблицы, одна и та же нагрузка обновлений.
set -euo pipefail
DB=${DB:-${PGDATABASE:-bloat_bench}}
ROWS=${ROWS:-500000}
UPDATES=${UPDATES:-100000}
# Место на странице под новые версии строк. Без запаса HOT невозможен
# физически, и эксперимент измерит не индексы, а переполненные страницы.
FILLFACTOR=${FILLFACTOR:-80}
mkdir -p results

run_case() {
  local NAME="$1" IDX_SQL="$2"
  psql -X -q -d "$DB" <<SQL
DROP TABLE IF EXISTS cost_t;
CREATE TABLE cost_t (
    id      bigint PRIMARY KEY,
    status  text NOT NULL,      -- эту колонку обновляем
    region  text NOT NULL,      -- эту не трогаем
    amount  numeric(12,2) NOT NULL,
    payload text NOT NULL
) WITH (fillfactor = $FILLFACTOR);
INSERT INTO cost_t
SELECT g, 'state-' || (g % 50), 'region-' || (g % 30),
       (random()*1000)::numeric(12,2), md5(g::text)
FROM generate_series(1, $ROWS) g;
$IDX_SQL
ALTER TABLE cost_t SET (autovacuum_enabled = off);
VACUUM (ANALYZE) cost_t;
DO \$\$ BEGIN PERFORM pg_stat_reset_single_table_counters('cost_t'::regclass); END \$\$;
SQL

  local LSN0 LSN1 WAL HOT
  LSN0=$(psql -X -At -d "$DB" -c "SELECT pg_current_wal_lsn()")
  psql -X -q -d "$DB" -c "
    UPDATE cost_t SET status = 'state-' || (random()*50)::int
    WHERE id <= $UPDATES"
  LSN1=$(psql -X -At -d "$DB" -c "SELECT pg_current_wal_lsn()")

  WAL=$(psql -X -At -d "$DB" -c \
    "SELECT round(pg_wal_lsn_diff('$LSN1','$LSN0')::numeric / $UPDATES, 1)")
  HOT=$(psql -X -At -d "$DB" -c "
    SELECT CASE WHEN n_tup_upd = 0 THEN '-'
                ELSE round(100.0 * n_tup_hot_upd / n_tup_upd, 1)::text END
    FROM pg_stat_user_tables WHERE relname = 'cost_t'")

  printf '%-38s WAL/строку: %8s байт   HOT: %5s %%\n' "$NAME" "$WAL" "$HOT"
}

{
  echo "нагрузка: $UPDATES обновлений колонки status, fillfactor = $FILLFACTOR"
  echo
  run_case "без индексов (кроме PK)"          ""
  run_case "1 индекс по НЕизменяемой колонке" \
      "CREATE INDEX ON cost_t (region);"
  run_case "1 индекс по ИЗМЕНЯЕМОЙ колонке"  \
      "CREATE INDEX ON cost_t (status);"
  run_case "4 индекса, один по изменяемой"   \
      "CREATE INDEX ON cost_t (region);
       CREATE INDEX ON cost_t (amount);
       CREATE INDEX ON cost_t (payload);
       CREATE INDEX ON cost_t (status);"
} | tee results/index-cost.txt

cat <<'TXT'

Читать так:
  - второй случай против первого: индекс по неизменяемой колонке стоит
    относительно немного, HOT продолжает работать;
  - третий против второго: индекс ПО ОБНОВЛЯЕМОЙ колонке отключает HOT
    для этой таблицы - это скачок, а не приращение;
  - четвёртый: каждый дополнительный индекс добавляет свою запись в
    каждое не-HOT обновление.

Разница между первым и последним числом - цена решения 'добавим индекс
на всякий случай', выраженная в байтах WAL на каждое обновление.
TXT
