-- Стенд главы 4. Данные должны быть заметно больше work_mem,
-- иначе ни одна операция не упрётся в бюджет и множитель выйдет 1.0
-- по причине, не имеющей отношения к вашей нагрузке.
DROP TABLE IF EXISTS orders, customers;

CREATE TABLE customers (
    id   bigint PRIMARY KEY,
    city text NOT NULL,
    name text NOT NULL
);
INSERT INTO customers
SELECT g, 'city-' || (g % 500), md5(g::text)
FROM generate_series(1, 500000) g;

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount      numeric(12,2) NOT NULL,
    created     timestamptz NOT NULL,
    note        text NOT NULL
);
INSERT INTO orders
SELECT g,
       (random() * 499999)::bigint + 1,
       (random() * 10000)::numeric(12,2),
       now() - (random() * 365) * interval '1 day',
       md5(g::text) || md5((g+1)::text)
FROM generate_series(1, 5000000) g;

VACUUM (ANALYZE) customers, orders;

SELECT pg_size_pretty(pg_total_relation_size('orders'))    AS orders,
       pg_size_pretty(pg_total_relation_size('customers')) AS customers;
