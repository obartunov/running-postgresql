-- Новые входные данные для планировщика, а не подсказка по плану.
--
-- Здесь намеренно только dependencies — функциональная зависимость
-- city -> region. Это ровно тот механизм, о котором глава.
--
-- ВНИМАНИЕ, наблюдение со стенда: если добавить сюда ещё и mcv,
-- результат становится неустойчивым. Многоколоночный список частых
-- значений ограничен целью статистики (по умолчанию 100 комбинаций), а
-- пар (city, region) здесь 400, и все примерно одинаковой частоты.
-- Попадёт ли ваша пара в список — дело случая при выборке. Когда
-- попадает, оценка хорошая; когда нет, она остаётся прежней, несмотря
-- на присутствующую функциональную зависимость.
-- Это не дефект PostgreSQL, а следствие того, что mcv описывает частые
-- комбинации, а не связь колонок.
DROP STATISTICS IF EXISTS customers_geo;
CREATE STATISTICS customers_geo (dependencies) ON city, region FROM customers;
ANALYZE customers;

SELECT stxname, stxkind,
       left(d.stxddependencies::text, 60) AS dependencies
FROM pg_statistic_ext s
JOIN pg_statistic_ext_data d ON d.stxoid = s.oid
WHERE s.stxname = 'customers_geo';
