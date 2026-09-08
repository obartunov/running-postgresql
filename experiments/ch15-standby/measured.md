```text
Experiment:   standby-conflicts
Chapter:      глава 15 (replica)
PostgreSQL:   16.15 (Ubuntu), commit not recorded
Machine/OS:   см. ../ENVIRONMENT.md
Date:         2026-09-06
Question:     кто проигрывает при конфликте восстановления и где виден
              держатель горизонта при hot_standby_feedback
Result:       при delay=0 гибнет запрос на replica; при feedback=on
              VACUUM на primary не может освободить строки; держатель
              виден в слоте, а не в pg_stat_replication
Scripts:      make-cluster.sh, conflict.sh
Raw output:   results/run1, results/run3 (не версионируются)
```

Стенд: primary и physical standby на одной машине, физический слот,
`pgbench` scale 20. На standby идёт транзакция `REPEATABLE READ` с
`pg_sleep(20)`; на primary в это время `UPDATE` двух третей таблицы и
`VACUUM`.

## Observed

| прогон | настройка standby | запрос на standby | `confl_snapshot` | `VACUUM` на primary |
|---|---|---|---|---|
| 1 | `max_standby_streaming_delay = 0`, feedback off | отменён с `canceling statement due to conflict with recovery` | 1 | `666666 removed, 0 not yet removable` |
| 3 | `max_standby_streaming_delay = 0`, feedback **on** | дожил до `COMMIT` | 0 | `0 removed, 666666 not yet removable` |

Прогон 2 (`delay = 30s`, feedback off) не выполнялся.

### Где виден держатель горизонта

Снимок сделан на primary, пока запрос на standby ещё выполнялся,
прогон 3:

```text
pg_stat_replication.backend_xmin  = NULL
pg_replication_slots.xmin         = 757     (slot standby1, active = t)
```

`removable cutoff` в выводе `VACUUM` того же прогона — 757.

## Derived

Совпадение `pg_replication_slots.xmin` и `removable cutoff` показывает,
что удержание горизонта на primary соответствует именно слоту.
Отношение освобождённых строк: 666 666 против 0.

## Interpretation

Конфликт один, а расплата разная: либо запрос на standby, либо место
на primary. Практическое следствие для текста: при подключении через
слот держателя надо искать в `pg_replication_slots.xmin`, а не только
в `pg_stat_replication.backend_xmin`, который в этом прогоне был пуст.

Пустой `backend_xmin` при работающем feedback не является загадкой
стенда: документация PG19 прямо говорит, что при использовании
replication slot это поле остаётся NULL, а xmin standby виден в
`pg_replication_slots`. Утверждение заведено как VC-060 в
`docs/version-claims.md`.

## Замечание о валидности

Счётчики конфликтов не сбрасывались между прогонами: третий прогон
показывал `confl_snapshot = 1`, унаследованную от первого, то есть
обратное тому, что доказывает. Добавлен `pg_stat_reset()` на standby.

Снимок состояния делался после завершения запроса на standby, когда
держателя уже нет, и показывал пустоту. Теперь снимок берётся во время
работы запроса.
