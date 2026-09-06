-- Стенд главы 5. Две ситуации: связанные колонки и край гистограммы.
DROP TABLE IF EXISTS orders, customers, events;

-- Часть 1: регион однозначно определяется городом.
-- Планировщик об этой связи не знает и перемножает селективности.
CREATE TABLE customers (
    id     bigint PRIMARY KEY,
    city   text NOT NULL,
    region text NOT NULL,
    name   text NOT NULL
);
INSERT INTO customers
SELECT g,
       'city-'   || (g % 400),
       'region-' || ((g % 400) / 20),   -- 20 городов на регион
       md5(g::text)
FROM generate_series(1, 400000) g;
CREATE INDEX ON customers (city, region);

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount      numeric(12,2) NOT NULL
);
INSERT INTO orders
SELECT g, (random() * 399999)::bigint + 1, (random() * 1000)::numeric(12,2)
FROM generate_series(1, 4000000) g;
CREATE INDEX ON orders (customer_id);

-- Часть 2: растущая колонка даты.
CREATE TABLE events (
    id      bigserial PRIMARY KEY,
    created timestamptz NOT NULL,
    payload text NOT NULL
);
INSERT INTO events (created, payload)
SELECT now() - (random() * 30 + 1) * interval '1 day', md5(g::text)
FROM generate_series(1, 3000000) g;
CREATE INDEX ON events (created);

VACUUM (ANALYZE) customers, orders, events;
