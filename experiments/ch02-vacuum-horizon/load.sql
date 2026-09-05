-- Нагрузка: обновление колонки, НЕ входящей ни в один индекс.
-- Каждый проход делает ~200k новых версий строк.
UPDATE orders
SET status = 'touched-' || (random() * 1000)::int, updated = now()
WHERE id % 5 = 0;
