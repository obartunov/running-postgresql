-- Сцена главы 12: бронирование ресурса на интервал времени.
-- Инвариант: два подтверждённых бронирования одного ресурса не могут
-- пересекаться во времени.
DROP TABLE IF EXISTS bookings;

CREATE TABLE bookings (
    id          bigserial PRIMARY KEY,
    resource_id bigint      NOT NULL,
    starts_at   timestamptz NOT NULL,
    ends_at     timestamptz NOT NULL,
    CHECK (ends_at > starts_at)
);
CREATE INDEX ON bookings (resource_id, starts_at);
