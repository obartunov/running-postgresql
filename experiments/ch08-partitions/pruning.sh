#!/bin/bash
# Чем вы платите: время планирования при разном числе секций,
# с ключом секционирования в условии и без.
set -euo pipefail
DB=${PGDATABASE:-part_bench}
mkdir -p results

for N in 12 365 1095; do
  psql -X -q -d "$DB" <<SQL
DROP TABLE IF EXISTS p_test;
CREATE TABLE p_test (created timestamptz NOT NULL, kind int, payload text)
  PARTITION BY RANGE (created);
DO \$\$
DECLARE i int; lo date; hi date;
BEGIN
  FOR i IN 0..$((N-1)) LOOP
    lo := (date '2020-01-01' + i);
    hi := lo + 1;
    EXECUTE format('CREATE TABLE p_test_%s PARTITION OF p_test
                    FOR VALUES FROM (%L) TO (%L)', i, lo, hi);
  END LOOP;
END \$\$;
ANALYZE p_test;
SQL

  WITH_KEY=$(psql -X -At -d "$DB" -c \
    "EXPLAIN (ANALYZE, FORMAT JSON)
     SELECT count(*) FROM p_test WHERE created = '2020-01-05'" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Planning Time'])")

  NO_KEY=$(psql -X -At -d "$DB" -c \
    "EXPLAIN (ANALYZE, FORMAT JSON)
     SELECT count(*) FROM p_test WHERE kind = 5" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Planning Time'])")

  printf '%s секций\tпланирование с ключом: %s мс\tбез ключа: %s мс\n' \
    "$N" "$WITH_KEY" "$NO_KEY" | tee -a results/pruning.txt
done

psql -X -q -d "$DB" -c "DROP TABLE IF EXISTS p_test"

cat <<'TXT'

Секции здесь пустые: измеряется именно планирование, не выполнение.

С ключом в условии время планирования почти не зависит от числа
секций — отсечение убирает их рано. Без ключа растёт: это цена, которую
платит каждый запрос, не попавший в отсечение.

Отдельно посмотрите на блокировки такого запроса:
  BEGIN;
  SELECT count(*) FROM p_test WHERE kind = 5;
  SELECT count(*) FROM pg_locks WHERE pid = pg_backend_pid();
  COMMIT;
TXT
