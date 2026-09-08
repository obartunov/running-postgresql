-- Стенд: один физический индекс в двух разных ролях.
DROP TABLE IF EXISTS orders, customers;

CREATE TABLE customers (id bigint PRIMARY KEY, segment int);
INSERT INTO customers SELECT g, g % 20 FROM generate_series(1, 20000) g;

CREATE TABLE orders (
    id          bigint PRIMARY KEY,
    customer_id bigint NOT NULL,
    amount      numeric(12,2)
);
INSERT INTO orders
SELECT g, (random() * 19999)::bigint + 1, (random() * 1000)::numeric(12,2)
FROM generate_series(1, 2000000) g;

CREATE INDEX orders_customer_idx ON orders (customer_id);
VACUUM (ANALYZE) customers, orders;

SELECT 'customers' AS t, count(*) FROM customers
UNION ALL SELECT 'orders', count(*) FROM orders;
