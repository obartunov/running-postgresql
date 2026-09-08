#!/bin/bash
# Как выглядит раздувание индекса и насколько оценка расходится с
# измерением.
set -euo pipefail
DB=${DB:-${PGDATABASE:-bloat_bench}}
ROWS=${ROWS:-2000000}
ROUNDS=${ROUNDS:-4}
mkdir -p results

psql -X -q -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS pgstattuple"

psql -X -q -d "$DB" <<SQL
DROP TABLE IF EXISTS churn;
CREATE TABLE churn (
    id      bigint PRIMARY KEY,
    status  text NOT NULL,     -- индексируется и обновляется
    payload text NOT NULL
);
INSERT INTO churn
SELECT g, 'state-' || (g % 50), md5(g::text)
FROM generate_series(1, $ROWS) g;
CREATE INDEX churn_status_idx ON churn (status);
-- автовакуум выключен, чтобы момент очистки задавался вручную
ALTER TABLE churn SET (autovacuum_enabled = off);
VACUUM (ANALYZE) churn;
SQL

report() {
  psql -X -d "$DB" -c "
    SELECT '$1' AS phase,
           pg_size_pretty(pg_relation_size('churn_status_idx')) AS idx_size,
           round(avg_leaf_density::numeric, 1)      AS leaf_density_pct,
           round(leaf_fragmentation::numeric, 1)    AS fragmentation_pct
    FROM pgstatindex('churn_status_idx')"
}

{
  report "1. после сборки"

  for i in $(seq 1 "$ROUNDS"); do
    psql -X -q -d "$DB" -c "
      UPDATE churn SET status = 'state-' || (random()*50)::int
      WHERE id % 4 = $((i % 4))"
    psql -X -q -d "$DB" -c "VACUUM churn"
  done

  report "2. после обновлений и VACUUM"

  psql -X -q -d "$DB" -c "REINDEX INDEX CONCURRENTLY churn_status_idx"
  report "3. после REINDEX CONCURRENTLY"

  echo "=== для сравнения: оценочный (скрининговый) расчёт ==="
  psql -X -d "$DB" -c "
    SELECT c.relname,
           pg_size_pretty(pg_relation_size(c.oid)) AS actual,
           pg_size_pretty(
             (s.n_live_tup * (sum(pg_column_size(t.status)) / count(*) + 12))::bigint
           ) AS naive_ideal
    FROM pg_class c
    JOIN pg_stat_user_indexes s ON s.indexrelid = c.oid
    CROSS JOIN LATERAL (SELECT status FROM churn LIMIT 1000) t
    WHERE c.relname = 'churn_status_idx'
    GROUP BY c.relname, c.oid, s.n_live_tup" 2>/dev/null \
    || echo "(упрощённая оценка не посчиталась - это тоже иллюстрация)"
} | tee results/bloat.txt

cat <<'TXT'

Плотность (leaf_density) - то самое измерение. Свежесобранный индекс
даёт около 90%, раздутый - 50-60%.

Сравните измеренное с любым оценочным запросом про bloat, который вы
используете в проде. Расхождение и есть цена того, что оценка выводится
из каталога, а не читает индекс.
TXT
