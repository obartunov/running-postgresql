-- Стенд главы 3. Размер не важен: мы измеряем очередь, а не работу.
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (id bigint PRIMARY KEY, status text NOT NULL);
INSERT INTO orders SELECT g, 'new' FROM generate_series(1, 100000) g;
ANALYZE orders;
