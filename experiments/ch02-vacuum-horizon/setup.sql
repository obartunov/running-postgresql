-- Стенд главы 2. Небольшая таблица, которую легко довести до роста.
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    id      bigint PRIMARY KEY,
    status  text   NOT NULL,
    payload text   NOT NULL,
    updated timestamptz NOT NULL DEFAULT now()
);

INSERT INTO orders (id, status, payload)
SELECT g, 'new', repeat('x', 200)
FROM generate_series(1, 1000000) g;

-- Autovacuum отключён на этой таблице намеренно: мы хотим управлять
-- моментом VACUUM руками, иначе результат будет зависеть от того,
-- успел ли фоновый воркер вклиниться между шагами.
ALTER TABLE orders SET (autovacuum_enabled = off);

VACUUM (FREEZE, ANALYZE) orders;
