-- NooData v0 schema.  Tables stay under 30000 rows so that ANALYZE reads
-- every row with the default statistics target and the statistics, hence the
-- plans and the traces, are deterministic.
DROP TABLE IF EXISTS t, u;

CREATE TABLE t (
    id  int PRIMARY KEY,
    a   int,        -- ~2 rows per value, uncorrelated with physical order
    s   int,        -- skewed: 90% zeros, the rest distinct
    b   int,        -- 100 distinct values
    c   text,       -- 1000 distinct values, 'c0'..'c999'
    d   int,        -- 97 distinct values, indexed only by a partial index
    n   int         -- 30% NULL
);

INSERT INTO t
SELECT g,
       (g * 7919) % 10000,
       CASE WHEN g % 10 < 9 THEN 0 ELSE g END,
       g % 100,
       'c' || (g % 1000),
       g % 97,
       CASE WHEN g % 10 < 3 THEN NULL ELSE g % 5000 END
FROM generate_series(1, 20000) g;

CREATE INDEX t_a_idx ON t (a);
CREATE INDEX t_s_idx ON t (s);
CREATE INDEX t_b_c_idx ON t (b, c);
CREATE INDEX t_lower_c_idx ON t (lower(c));
CREATE INDEX t_n_idx ON t (n);
CREATE INDEX t_d_partial_idx ON t (d) WHERE s <> 0;

CREATE TABLE u (
    id  int PRIMARY KEY,
    t_a int,        -- join key to t.a
    x   int         -- 2000 distinct values
);

INSERT INTO u
SELECT g, (g * 3) % 10000, g % 2000
FROM generate_series(1, 2000) g;

CREATE INDEX u_x_idx ON u (x);

VACUUM ANALYZE t;
VACUUM ANALYZE u;
