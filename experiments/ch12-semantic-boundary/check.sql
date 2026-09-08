-- Сколько пар пересекающихся бронирований оказалось в базе.
SELECT count(*) AS overlapping_pairs
FROM bookings a
JOIN bookings b
  ON a.resource_id = b.resource_id
 AND a.id < b.id
 AND tstzrange(a.starts_at, a.ends_at) && tstzrange(b.starts_at, b.ends_at);
