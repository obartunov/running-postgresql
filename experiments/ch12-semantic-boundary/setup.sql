-- Стенд главы 12: проверка в приложении против инварианта в базе.
--
-- Задача: не бронировать один ресурс на пересекающиеся интервалы.
-- Две таблицы с одинаковым содержимым и разным местом инварианта.
CREATE EXTENSION IF NOT EXISTS btree_gist;

DROP TABLE IF EXISTS bookings_app, bookings_db;

-- Инвариант живёт в приложении: база согласится на что угодно.
CREATE TABLE bookings_app (
    id          bigserial PRIMARY KEY,
    resource_id bigint      NOT NULL,
    during      tstzrange   NOT NULL
);
CREATE INDEX ON bookings_app USING gist (resource_id, during);

-- Инвариант выражен в базе: пересечение по одному ресурсу невозможно.
CREATE TABLE bookings_db (
    id          bigserial PRIMARY KEY,
    resource_id bigint      NOT NULL,
    during      tstzrange   NOT NULL,
    EXCLUDE USING gist (resource_id WITH =, during WITH &&)
);
