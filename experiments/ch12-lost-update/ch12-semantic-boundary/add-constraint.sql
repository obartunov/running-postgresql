-- Тот же инвариант, выраженный в базе: диапазон плюс ограничение
-- исключения. Требуется btree_gist, чтобы сочетать равенство по
-- resource_id с пересечением по интервалу.
CREATE EXTENSION IF NOT EXISTS btree_gist;

ALTER TABLE bookings
  ADD CONSTRAINT bookings_no_overlap
  EXCLUDE USING gist (
      resource_id WITH =,
      tstzrange(starts_at, ends_at) WITH &&
  );
