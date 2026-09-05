-- Новые входные данные для планировщика, а не подсказка по плану.
-- dependencies: функциональные зависимости между колонками (PG10+)
-- mcv:          многоколоночный список частых значений (PG12+)
CREATE STATISTICS IF NOT EXISTS customers_geo (dependencies, mcv)
    ON city, region FROM customers;
ANALYZE customers;

SELECT stxname, stxkeys, stxkind FROM pg_statistic_ext
WHERE stxname = 'customers_geo';
