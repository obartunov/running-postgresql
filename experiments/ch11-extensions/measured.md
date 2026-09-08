```text
Experiment:   extension-boundary
Chapter:      глава 11
PostgreSQL:   16.15 (Ubuntu) с установленным contrib, commit not recorded
Machine/OS:   см. ../ENVIRONMENT.md
Date:         2026-09-06
Question:     что именно делает расширение неотделимым от данных
Result:       индекс на классе операторов расширения делает расширение
              неудаляемым; дамп останавливается у роли без права
              создать расширение
Scripts:      inventory.sql, dump-without-extension.sh, wont-start.sh
Raw output:   results/drop.txt, results/restore.log
```

## Observed

Таблица с GIN-индексом `gin_trgm_ops` из `pg_trgm`:

```text
ERROR:  cannot drop extension pg_trgm because other objects depend on it
DETAIL:  index names_trgm depends on operator class gin_trgm_ops
         for access method gin
```

`DROP EXTENSION ... CASCADE` в откатываемой транзакции:

```text
NOTICE:  drop cascades to index names_trgm
```

Восстановление дампа ролью без права создать расширение:

```text
psql:dump.sql:25: ERROR: permission denied to create extension "pg_trgm"
```

## Derived

Ничего не выводится: это наблюдения отказов, не измерения.

## Interpretation

Расширение перестаёт быть отделимым решением в момент, когда появляется
объект данных, зависящий от его класса операторов или типа. Дальше
`DROP` невозможен, а восстановление копии требует и наличия библиотеки,
и прав.

## Замечание о валидности

Первая версия стенда заявляла, что дамп "не восстановится там, где
расширения нет", и восстанавливала его в базу без установленного
`pg_trgm`. На машине с `contrib` он **восстановился**: дамп содержит
`CREATE EXTENSION`, и эта строка просто выполняется. Стенд доказывал не
то, что заявлял.

Случай "библиотеки нет на сервере" на машине с установленным contrib
воспроизвести нельзя; в скрипте это сказано явно, и вместо него
проверяются два случая, воспроизводимые всегда.

Побочно: `psql` возвращает ненулевой код на ошибке, которая является
частью демонстрации, и скрипт с `set -e` обрывался на середине.

## Не измерено

`wont-start.sh` (кластер не стартует из-за preload-библиотеки, лечение
правкой `postgresql.auto.conf`) написан, но в этой серии не
прогонялся. `inventory.sql` прогонялся только частично.
