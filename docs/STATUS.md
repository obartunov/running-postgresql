# Статус

**6 сентября 2026.** Canonical manuscript -
`book/Running-PostgreSQL.md`: 18 глав, 6 интермеццо, пролог про измерение
и приложение с release-notes archaeology.

В canonical уже интегрированы три темы, которые в предыдущем review
считались выпавшими:

- index bloat / HOT / WAL cost - интермеццо после главы 2;
- maintenance side partitioning - раздел в главе 7;
- post-upgrade operating window - интермеццо после главы 8.

Расширенные варианты этих трёх текстов сохранены как редакторский
материал в `drafts/r2d2-expanded/`; canonical source ими не является.

## Что сейчас является хребтом книги

Во введении уже семь возвращающихся вопросов:

1. что накапливается;
2. где образовалась очередь;
3. где проходит boundary;
4. где и когда выполняется physical work;
5. где живёт truth;
6. permanent architecture это или временная опора;
7. какой threshold мы ещё не пересекли.

`development -> test -> production`, queueing network, temporary
architecture и convenient-abstraction thresholds теперь тоже являются
сквозными линиями, а не pending topics.

## Experimental provenance

Тринадцать `measured.md` имеют provenance header и разделение
`Observed / Derived / Interpretation`. Карта - в
`docs/measurements.md`.

`tools/check-experiments.py` проверяет experiment paths и registry.
После синхронизации canonical остаются два честных structural gaps:

- PG-001 - отсутствует `ch04-memory-envelope`;
- PG-002 - отсутствует semantic-boundary experiment для главы 12.

Они не закрываются переименованием существующих стендов.

## Version claims

Реестр - `docs/version-claims.md`. PostgreSQL 19 на дату этой редакции -
Beta 3; 19-specific claims должны быть пересверены после GA.

Отдельный release-notes appendix всё ещё требует построчного provenance
перед печатью (PG-004).

## Что делать дальше

Высший приоритет по evidence:

1. PG-012 - построить главный checkpoint/p99/backlog overlay главы 1;
2. PG-001 - написать и прогнать настоящий concurrency memory-envelope;
3. PG-002 - написать semantic-boundary stand с двумя concurrent writers;
4. PG-009 - повторить timing measurements и сохранить разброс;
5. PG-010/011 - закончить недостающие replication scenes.

Редакторский долг отдельно: унифицировать bilingual terminology, но не
вычищать наблюдаемые образы вроде "зубца", "затыка" и "тени очереди",
если они не заменяют название механизма.
