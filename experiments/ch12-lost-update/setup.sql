-- Стенд главы 12: граница семантики между приложением и базой.
-- Счёт с балансом, который приложение любит менять "прочитал, посчитал,
-- записал" - то есть так, как это делает большинство ORM по умолчанию.
DROP TABLE IF EXISTS accounts;
CREATE TABLE accounts (
    id      bigint PRIMARY KEY,
    balance bigint NOT NULL,
    version bigint NOT NULL DEFAULT 0
);
INSERT INTO accounts VALUES (1, 0, 0);
