```text
Experiment:   lock-queue
Chapter:      глава 3
PostgreSQL:   16.15 (Ubuntu), commit not recorded
Machine/OS:   см. ../ENVIRONMENT.md
Date:         2026-09-06
Question:     кого именно ждёт обычный SELECT, пришедший после
              ожидающей DDL, и что даёт lock_timeout
Result:       читатель ждёт миграцию, а не другого читателя; ожидание
              2.05 s против 0.025 s с ограничителем
Scripts:      scenario.sh, blocked.sql, locks.sql, setup.sql
Raw output:   results/naive, results/timeout, results/cancel-ddl
```

Три сессии: A — открытая транзакция с `SELECT` (держит `ACCESS SHARE`,
пауза на клиенте, состояние `idle in transaction`); B — `ALTER TABLE
... ADD COLUMN ... DEFAULT '' NOT NULL`; C — обычный `SELECT count(*)`.

## Observed

| прогон | ожидание сессии C | что стало с DDL |
|---|---|---|
| `naive` | 2.05 s | выполнилась после ухода держателя |
| `timeout` (`lock_timeout = 2s`) | 0.025 s | `canceling statement due to lock timeout` |
| `cancel-ddl` | 2.05 s до отмены | снята вручную, очередь разошлась |

Дерево ожиданий в прогоне `cancel-ddl`:

```text
1746 | idle in transaction | Client | ClientRead | {}     | SELECT count(*) FROM orders;
1751 | active              | Lock   | relation   | {1746} | ALTER TABLE orders ADD COLUMN ...
1756 | active              | Lock   | relation   | {1751} | SELECT count(*) FROM orders
```

Состояние сессии A перед миграцией зафиксировано отдельно:
`idle in transaction`, 1.99 s в этом состоянии.

## Derived

Отношение ожиданий: 2.05 / 0.025 ≈ **82×**.
Ожидание C в прогоне `naive` совпадает с длительностью ожидания B
(обе сессии ждали до конца прогона), а не с длительностью самой DDL.

## Interpretation

`pg_blocking_pids()` показывает у C идентификатор миграции, а не
держателя `ACCESS SHARE`. Два `ACCESS SHARE` совместимы; C стоит из-за
того, кто встал между ними в очередь.

## Замечание о валидности

Добавлены уборка остатков прошлого прогона по `application_name` и
`lock_timeout` на подготовку: иначе прерванный прогон оставляет
держателя, и `DROP TABLE` в `setup.sql` висит без объяснений.
