-- Две таблицы одинакового содержания: обычная и секционированная по
-- месяцам. Год данных, чтобы было что удалять.
DROP TABLE IF EXISTS events_plain, events_part;

CREATE TABLE events_plain (
    id      bigserial,
    created timestamptz NOT NULL,
    kind    int NOT NULL,
    payload text NOT NULL
);

CREATE TABLE events_part (
    id      bigserial,
    created timestamptz NOT NULL,
    kind    int NOT NULL,
    payload text NOT NULL
) PARTITION BY RANGE (created);

-- 12 месячных секций назад от начала текущего месяца
DO $$
DECLARE
    start_month date := date_trunc('month', now())::date - interval '11 months';
    i int;
    lo date; hi date;
BEGIN
    FOR i IN 0..11 LOOP
        lo := (start_month + (i    || ' months')::interval)::date;
        hi := (start_month + (i+1  || ' months')::interval)::date;
        EXECUTE format(
          'CREATE TABLE events_part_%s PARTITION OF events_part
             FOR VALUES FROM (%L) TO (%L)',
          to_char(lo, 'YYYY_MM'), lo, hi);
    END LOOP;
END $$;

-- Одинаковые данные в обе таблицы: год, равномерно по месяцам.
INSERT INTO events_plain (created, kind, payload)
SELECT date_trunc('month', now()) - (random() * 330 + 1) * interval '1 day',
       (random() * 20)::int,
       md5(g::text) || md5((g * 7)::text)
FROM generate_series(1, 3000000) g;

INSERT INTO events_part (created, kind, payload)
SELECT created, kind, payload FROM events_plain;

CREATE INDEX ON events_plain (created);
CREATE INDEX ON events_plain (kind);
CREATE INDEX ON events_part  (created);
CREATE INDEX ON events_part  (kind);

VACUUM (ANALYZE) events_plain, events_part;

-- Размер секционированной таблицы считается по секциям: у родителя
-- своих файлов нет, и pg_total_relation_size на нём даёт ноль.
SELECT 'plain' AS t, pg_size_pretty(pg_total_relation_size('events_plain')) AS size
UNION ALL
SELECT 'part', pg_size_pretty(sum(pg_total_relation_size(i.inhrelid)))
  FROM pg_inherits i WHERE i.inhparent = 'events_part'::regclass;
