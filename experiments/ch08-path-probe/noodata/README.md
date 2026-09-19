# NooData v0: траектория решений планировщика как датасет

Цель: из контролируемых пар запросов получить воспроизводимый датасет, в
котором кроме итогового EXPLAIN сохранена судьба альтернатив: что родилось,
что принято, отвергнуто, вытеснено, и что не родилось вовсе. Модель здесь не
обучается.

## Состав

```text
../hackers/0001, 0002      существующая серия (add_path, без изменений)
core 0003 (ветка noodata-v0 в дереве PostgreSQL)
                           planner-index-path-generated /
                           planner-index-path-not-generated
                           в конце build_index_paths()
noodata_trace/             внедеревный callback (PGXS): каждое событие -
                           одна JSON-строка в NOTICE; идентичность путей
gen.py                     генератор датасета
pairs.json                 27 пар (25 однотабличных, 2 join)
setup.sql                  схема; таблицы < 30000 строк, ANALYZE читает всё,
                           статистика и планы детерминированы
check.py                   структурные проверки (не стоимости)
data-v0/                   результат прогона, описанный ниже
```

Серия 0001/0002 не менялась. Callback вынесен из дерева, чтобы не
расширять тестовый модуль `injection_points` ради генератора данных.

## Почему граница рождения IndexPath - конец build_index_paths()

Все IndexPath при планировании запроса строятся в `build_index_paths()`
(`create_index_path()` вызывается ещё только из `plan_cluster_use_sort()`,
это CLUSTER). Решение строить путь там принимается по пяти входам:
индексные условия, полезный порядок вперёд, полезный порядок назад (шаг 5),
полезный предикат, возможность index-only scan. Точка стоит после шага 5,
поэтому «не построен» означает, что все пять ложны - это записано в payload,
а не выведено из отсутствия пути. `check.py` проверяет это для каждого
события: `GENERATED <=> npaths > 0 <=> хотя бы один флаг`.

Не покрыто, и потому в данных это `NOT_EXAMINED`, а не `NEVER_GENERATED`:

- ранние выходы `build_index_paths()`: AM не поддерживает нужный тип скана;
  `amoptionalkey = false` без условия на ведущую колонку (hash);
- индексы, отброшенные до вызова: частичный индекс с недоказанным
  предикатом (`create_index_paths()`), OR-ветви без подходящих условий
  (`build_paths_for_OR()`).

## Событие

```json
{"event":"REJECTED","plan":4,"seq":7,"rel_id":1,"rel_kind":"base","relids":[1],
 "path_id":2,"path_type":"IndexScan","index":"t_a_idx",
 "startup_cost":..,"total_cost":..,"rows":..,"disabled_nodes":0,
 "pathkeys":["v1.2 ASC"],"required_outer":[],"parallel_safe":false,"parallel_workers":0,
 "competitor_path_id":1,"competitor_path_type":"SeqScan", "competitor_...": ..}
```

Событие описывает судьбу субъекта: `ACCEPTED` и `REJECTED` - нового пути,
`DISPLACED` - вытесненного (конкурент - новый путь), `PRECHECK_REJECTED` -
предложенного пути, которого ещё нет (`path_id` и `path_type` - null).
`path_id` принадлежит объекту Path в пределах одного вызова планировщика;
«принят, потом вытеснен» - два события на одном id. Id снимается ровно там,
где `add_path()` делает `pfree`. `rel_id` различает upper rels, у которых
нет relids.

Индексные события: `INDEX_PATH_GENERATED` / `INDEX_PATH_NOT_GENERATED` с
флагами решения, `bitmap_only`, `required_outer`, `npaths`.

## Файлы data-v0

```text
baseline.jsonl     SQL + схема/статистика + EXPLAIN                  (A)
noodata.jsonl      то же + trajectory (сырые события)                 (B)
questions.jsonl    вопросы; ответы выведены только из траектории
index_fates.jsonl  выведенные факты по каждому индексу каждого запроса
pairs.jsonl        первая точка расхождения Q1/Q2: полная и структурная
actual.jsonl       EXPLAIN ANALYZE (TIMING OFF) - отдельно, в v0 не участвует
manifest.json      версия, GUC, счётчики
```

Разбиение train/test - по паре (sha1 от id), общее для A и B. Структурная
точка расхождения игнорирует стоимости, строки и path_id.

Вердикт индекса: `CHOSEN`, `SURVIVED_NOT_CHOSEN` (выжил в своём rel, проиграл
выше), `PRUNED` (все его пути отвергнуты или вытеснены),
`GENERATED_NOT_SUBMITTED` (построен только для bitmap и не дошёл до
add_path, отбор в `choose_bitmap_and()`/`generate_bitmap_or_paths()` не
инструментирован), `NEVER_GENERATED`, `NOT_EXAMINED`.

## Прогон v0

```text
PostgreSQL master c62b330 + 0001 + 0002 + 0003 (b9c5d58)
--enable-injection-points --enable-cassert, CFLAGS=-O1
max_parallel_workers_per_gather=0, jit=off, autovacuum=off, --no-locale

54 запроса, 673 события:
  ACCEPTED 215, DISPLACED 57, REJECTED 34, PRECHECK_REJECTED 28,
  INDEX_PATH_GENERATED 52, INDEX_PATH_NOT_GENERATED 287
1157 вопросов; 24 пары train, 3 test (P04, P13, P21)
```

Воспроизведение: `python3 gen.py --dsn "..." --out DIR && python3 check.py DIR`.
Два полных прогона (с пересозданием схемы) дают побайтно одинаковые файлы.

## Ограничения v0

- `PRECHECK_REJECTED` без типа пути и метода соединения: payload 0001 их не
  несёт, а add_path_precheck() вызывается только из joinpath.c.
- Частичные пути (`add_partial_path`) не инструментированы; параллелизм
  выключен.
- У join-путей не записаны id внешнего/внутреннего пути.
- Вопросы по индексам генерируются для всех индексов таблицы, поэтому
  `NEVER_GENERATED` для нерелевантных индексов доминирует (286 из 386).
