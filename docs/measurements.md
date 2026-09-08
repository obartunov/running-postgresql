# Измеренное: указатель по текущей рукописи

Карта связывает `book/Running-PostgreSQL.md` с воспроизводимыми стендами.
Все числа получены на PostgreSQL 16.15 в одном контейнере, если в самом
`measured.md` не сказано иное. Общие ограничения среды — в
`experiments/ENVIRONMENT.md`.

| место в рукописи | стенд | состояние |
|---|---|---|
| гл. 1 — checkpoint / tail | `experiments/ch01-checkpoint` | прогнан; центральный p99/checkpoint overlay ещё не построен (PG-012) |
| гл. 2 — VACUUM horizon | `experiments/ch02-vacuum-horizon` | прогнан |
| интермеццо после гл. 2 — index bloat / HOT / WAL | `experiments/ch02-index-bloat` | прогнан |
| гл. 3 — lock queue | `experiments/ch03-lock-queue` | прогнан |
| гл. 4 — per-query work_mem | `experiments/ch04-memory-envelope`, часть 1 | прогнан |
| гл. 4 — concurrency envelope | `experiments/ch04-memory-envelope`, часть 2 | прогнан 2026-09-06 |
| гл. 6 — connections / starvation | `experiments/ch06-connections` | прогнан |
| гл. 7 — partition pruning / lifecycle removal | `experiments/ch07-partitions` | прогнан |
| гл. 8 — estimates / extended statistics | `experiments/ch08-estimates` | прогнан |
| интермеццо после гл. 8 — upgrade window | `experiments/ch08-upgrade-window` | прогнан частично: measured post-upgrade work, не сам `pg_upgrade` |
| гл. 11 — extensions | `experiments/ch11-extensions` | прогнан; один заявленный negative case не покрыт (PG-014) |
| гл. 12 — semantic boundary (пересечение интервалов) | `experiments/ch12-semantic-boundary` | прогнан 2026-09-06 |
| гл. 12 — потерянное обновление | `experiments/ch12-lost-update` | прогнан 2026-09-06 |
| гл. 1 — тень чекпойнта в p99 | `experiments/ch01-checkpoint`, часть 2 | прогнан, результат отрицательный (PG-015, PG-016) |
| гл. 1 — backlog и опыт на причинность | `experiments/ch01-checkpoint`, часть 3 | прогнан, причинность не установлена |
| гл. 14 — startup / recovery milestones | `experiments/ch16-restore` | прогнан |
| гл. 15 — physical standby | `experiments/ch15-standby` | прогнан; один промежуточный режим не прогнан (PG-011) |
| гл. 15 — logical replication | `experiments/ch15-logical` | прогнан частично (PG-010) |
| гл. 16 — restore / archive chain | `experiments/ch16-restore` | прогнан |

## Стенды, обслуживающие несколько мест книги

`ch16-restore` даёт два разных результата.

Для главы 14:

- *first response* — первый нулевой exit code от `psql -c "SELECT 1"`, polling 0.2 s;
- *replay finished* — первый `false` от `pg_is_in_recovery()`, polling 0.5 s;
- обе точки отсчитываются от одного `pg_ctl start`;
- measured: 0.62 s против 3.82 s.

Для главы 16 тот же стенд воспроизвёл другой failure mode: простой
`archive_command` с прямым `cp` был прерван при `pg_ctl -m immediate`,
и в final archive name остался partial WAL file 851,968 bytes вместо
16,777,216. Точный сценарий — в `experiments/ch16-restore/measured.md`.

## Числа, которые уже вошли в canonical text

| число | источник |
|---|---|
| index density 89.9 → 61.6 → 89.7 % | `ch02-index-bloat`, часть 1 |
| WAL/update 145.7 → 537.0 B; HOT 68.1 → 1.3 % | `ch02-index-bloat`, часть 2 |
| statistics ~0.5 s; REINDEX ~9.3 s | `ch08-upgrade-window` |
| DELETE old month ~13 MB WAL; ~245k dead rows | `ch07-partitions` |
| whole-partition lifecycle operation ~7 KB WAL; 0 dead rows | `ch07-partitions` |
| first response 0.62 s; replay finished 3.82 s | `ch16-restore`, часть 1 |
| `backend_xmin = NULL`, slot `xmin = 757` | `ch15-standby` |
| partial WAL file after interrupted direct `cp` | `ch16-restore`, часть 2 |

Числа — observed properties конкретных стендов, не нормативы PostgreSQL.
Derived ratios и causal interpretation должны оставаться отдельно в
соответствующих `measured.md`.

## Что прогоны уже сломали в самих экспериментах

Семь дефектов были найдены потому, что стенд печатал правдоподобный
результат, но измерял не заявленный механизм. Самые показательные:

- extension dump восстанавливался там, где ожидался failure, потому что
  `CREATE EXTENSION` успешно выполнялся в окружении с `contrib`;
- первая версия upgrade-window фактически измеряла пустой ANALYZE path;
- index-bloat без page headroom физически не мог показать HOT contrast;
- restore completion первоначально принимался за первый ответ сервера;
- standby conflict мог быть унаследован от предыдущего прогона.

Это часть методологии книги: expected shape результата не является
доказательством, что механизм был задействован.
