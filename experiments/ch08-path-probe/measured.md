```text
Experiment:   path-probe
Chapter:      глава 8 (planner)
PostgreSQL:   16.15, собран из исходников REL_16_STABLE с патчем
              0001-path-probe-instrument-add_path.patch
Machine/OS:   см. ../ENVIRONMENT.md; отдельный кластер, shared_buffers 128MB
Date:         2026-09-08
Question:     что происходит с Paths одного физического индекса, когда
              EXPLAIN показывает, что индекс "не использовался"
Result:       parameterized Index Scan не отсеивался; он выжил на уровне
              base relation и был вытеснен уже на уровне join вместе со
              всем Nested Loop
Scripts:      setup.sql, queries.sql, probe.sh, decode.py
Raw evidence: trace-baseline.txt
```

Данные: `customers` 20 000 строк, `orders` 2 000 000 строк, один индекс
`orders_customer_idx (customer_id)`.

## Observed

### Три плана

Standalone scan, где индекс плох:

```text
SELECT * FROM orders WHERE customer_id > 0;
Seq Scan on orders  (cost=0.00..37739.00 rows=2000000)
```

Join, baseline:

```text
SELECT o.* FROM customers c JOIN orders o ON o.customer_id = c.id
 WHERE c.id BETWEEN 100 AND 4999;

Hash Join  (cost=215.54..38205.65 rows=490000)
  ->  Seq Scan on orders o  (cost=0.00..32739.00 rows=2000000)
```

Тот же join при `enable_hashjoin = off`, `enable_mergejoin = off`:

```text
Nested Loop  (cost=0.71..73766.55 rows=490000)
  ->  Index Only Scan using customers_pkey on customers c
  ->  Index Scan using orders_customer_idx on orders o
        (cost=0.43..14.01 rows=101)
```

### Трасса add_path() для baseline

Полностью в `trace-baseline.txt`. Существенные строки (rel=2 это
`orders`, rel=1 это `customers`):

```text
решение   rel    узел                  startup        total      rows  pk req_outer
accepted  2      T_SeqScan                0.00     32739.00   2000000   0      none
accepted  2      T_IndexScan              0.43     87908.16   2000000   1      none  index=16395
accepted  2      T_IndexScan              0.43        14.01       101   1         1  index=16395
rejected  2      T_BitmapHeapScan         2.63        15.75       101   0         1
...
accepted  1,2    T_NestLoop               0.71     73766.55    490000   0      none
removed   1,2    T_NestLoop               0.71     73766.55    490000   0      none
accepted  1,2    T_HashJoin             215.54     38205.65    490000   0      none
```

## Derived

Один физический индекс дал на уровне base relation **два разных Path**:

- unparameterized Index Scan, `req_outer=none`, total 87908.16;
- parameterized Index Scan, `req_outer=1` (то есть `customers`),
  total 14.01, rows 101.

Оба **приняты**. Unparameterized путь выжил при total-cost в 2.7 раза
хуже, чем Seq Scan (87908 против 32739), потому что у него есть
pathkeys (`pk=1`), а у Seq Scan нет: сравниваются не только costs.

Nested Loop с параметризованным путём внутри был построен и принят с
total 73766.55, а затем удалён, когда появился Hash Join с 38205.65.

Стоимость принудительного плана (`enable_hashjoin=off`) совпадает с
той, что записана в трассе для вытесненного кандидата: 73766.55. То
есть принудительный план и удалённый кандидат - один и тот же Path.

## Interpretation

Фраза "индекс проиграл Seq Scan" в этом опыте неверна дважды.

Во-первых, unparameterized Index Scan вообще не проигрывал: он выжил,
потому что даёт порядок. Во-вторых, тот Path, который действительно
нужен для join, - это другой Path того же индекса, с
`req_outer={customers}`, и он тоже выжил.

Индекса нет в финальном EXPLAIN не потому, что его путь отсеян на
уровне сканирования, а потому, что join method над ним оказался
дороже: вытеснен весь Nested Loop, а не Index Scan.

## Классификация опыта

По схеме A/B/C (см. README):

**Случай A.** Кандидат существовал и выжил на своём уровне, проиграл
выше. Именно это и наблюдается.

Случаи B (кандидат был отсеян в baseline, но появляется под
ограничением) и C (нужную форму нельзя построить даже под
ограничением) в этом наборе данных не воспроизведены. Отдельный подбор
данных под B - следующий шаг, см. `docs/provenance-gaps.md`.

## Полнота переноса точек

Локальная инструментовка Path Probe имела три точки в `add_path()`:
принят, отклонён, вытеснен. В серию перенесены все три и добавлена
четвёртая - отказ в `add_path_precheck()`, которого в Path Probe не
было и на который приходится половина событий.

Не покрыты `add_partial_path()` и `add_partial_path_precheck()`: там та
же логика отсева для параллельных путей. Это осознанный пропуск,
оговорённый в cover letter; демонстрация выключает параллелизм, и точки
стоит добавлять тогда, когда появится опыт, которому они нужны.

При слиянии версий из вывода callback пропали два поля, которые были в
источниках: оценка строк (была в Path Probe) и стоимости вытесняемого
пути (были в v2). Восстановлены.

## Продолжение: те же события через injection points

Локальный патч из этого каталога решает задачу книги, но не годится как
общий инструмент: он жёстко пишет в лог и требует собственной сборки.
Поэтому те же три события оформлены как injection points и собраны в
серию для pgsql-hackers: `hackers/`.

Серия прошла три версии; текущая - v3 в `hackers/`, собрана на master
20devel и прогнана целиком.

Мотивирующий запрос (индекса в финальном плане нет), master 20devel,
`pp_customers` 10 тыс. строк, `pp_orders` 1 млн:

```text
Hash Join  (cost=210.28..31730.39 rows=497216)
  ->  Seq Scan on pp_orders o  (cost=0.00..28894.00 rows=1000000)

event=accept   rel={2}   IndexScan index=32826 total=86426.48 rows=1000000 required_outer={}
event=accept   rel={2}   IndexScan index=32826 total=16.19    rows=99      required_outer={1}
event=accept   rel={1,2} NestLoop  total=56961.08
event=displace rel={1,2} HashJoin  total=31730.39  old_type=NestLoop
```

Вывод тот же, что дал локальный патч на 16.15 на своих данных: оба
кандидата по индексу приняты, вытеснен Nested Loop над параметризованным
путём, а не сам путь. Полные трассы в `hackers/demo/`.

Оценка строк отделяет двух кандидатов нагляднее всего: 1 000 000 против
99 при одном и том же oid индекса.

Дополнительно на master стало видно то, чего не показывала первая
инструментовка: на уровне join за один прогон лидер меняется несколько
раз (MergeJoin, NestLoop, HashJoin, снова NestLoop, снова HashJoin).
Без события `accept` видны только смерти, и картина выглядит короче,
чем она есть.

Найдено при сборке демонстрации: существующий callback `notice` в модуле
`injection_points` считает аргумент строкой и на типизированном
аргументе печатает мусор. Поэтому в 0002 добавлено отдельное действие
`path-prune-notice`. Это записано в cover letter как вопрос к рецензентам:
либо аргументы остаются строками и мы теряем `required_outer`, либо
принимается типизированный payload.

Если серию примут, локальный патч из этого каталога станет не нужен, а
стенду останутся `setup.sql`, `demo/run.sql` и разбор вывода.

## Чего в этом опыте нет

**pg_plan_advice не участвовал.** Модуль появился в PG19, а
инструментованная сборка сделана из REL_16_STABLE, потому что патч
Path Probe писался под доступные здесь исходники. Поэтому слой "можно
ли вообще построить такую форму плана и что ответит модуль про
matched/failed" не проверен.

Замена через `enable_hashjoin = off` **не эквивалентна** advice:
GUC глобально запрещает альтернативу для всего запроса, тогда как
advice ограничивает выбор адресно и возвращает обратную связь о том,
применилось ли ограничение. Одинаковая стоимость плана здесь означает
только, что это тот же Path, и ничего не говорит о поведении модуля.

Соответственно, утверждение "успешный advice не доказывает, что этот
Path выжил в исходном planning run" этим опытом не проверялось: оно
остаётся тезисом до прогона на PG19.

## Замечание о валидности

Патч добавляет `elog(DEBUG1)` в `add_path()`. Это меняет стоимость
планирования и не годится для измерения времени: снимать этой сборкой
можно только структуру решений, но не latency.

Номера узлов (`node=318`) зависят от версии; `decode.py` берёт таблицу
из `nodetags.h` той же сборки. Переносить расшифровку между версиями
нельзя.
