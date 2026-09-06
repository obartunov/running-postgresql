```text
Experiment:   work-mem-multiplier
Chapter:      глава 4. ВНИМАНИЕ: рукопись ссылается на
              experiments/ch04-memory-envelope/, которого в репозитории
              нет; см. docs/provenance-gaps.md
PostgreSQL:   16.15 (Ubuntu), commit not recorded
Machine/OS:   см. ../ENVIRONMENT.md
Date:         2026-09-06
Question:     во сколько раз реально занятая память отличается от
              work_mem на одном отчётном запросе
Result:       около 740 MB на один запрос при work_mem = 256MB;
              при 4MB тот же запрос сбрасывает на диск и отрабатывает
Scripts:      peakmem.sh, explain.sh, measure.psql, query.sql
Raw output:   results/parallel, results/serial (не версионируются)
```

Данные: 5 млн заказов (748 MB) и 500 тыс. клиентов (51 MB). Запрос —
хеш-соединение, хеш-агрегация, сортировка.

## Observed

Пиковая память ведущего процесса, `VmHWM` из `/proc/<pid>/status`,
каждое измерение в новом соединении:

| `work_mem` | с параллелизмом | `max_parallel_workers_per_gather = 0` |
|---|---|---|
| 4 MB | 216 536 kB | 368 316 kB |
| 64 MB | 399 336 kB | 398 924 kB |
| 256 MB | 464 844 kB | 417 352 kB |

`EXPLAIN (ANALYZE)` того же запроса при `work_mem = 256MB`:

```text
Sort Method: quicksort  Memory: 236309kB
Worker 0:  Sort Method: quicksort  Memory: 237718kB
Worker 1:  Sort Method: quicksort  Memory: 236633kB
Buckets: 524288  Batches: 1  Memory Usage: 30752kB
Workers Launched: 2
```

При `work_mem = 4MB`:

```text
Sort Method: external merge  Disk: 170400kB
Worker 0:  Sort Method: external merge  Disk: 171008kB
Worker 1:  Sort Method: external merge  Disk: 169528kB
Buckets: 262144  Batches: 4  Memory Usage: 8736kB
```

## Derived

Сумма памяти сортировок и хеша при 256 MB:
236 + 238 + 237 + 31 ≈ **742 MB** на один выполняющийся запрос, то есть
примерно 2.9 × `work_mem`.

Прирост `VmHWM` ведущего процесса от 4 MB к 256 MB: 248 MB при
приросте `work_mem` 252 MB, то есть примерно 1.0 — но это только
лидер, память воркеров сюда не входит.

При 4 MB на диск ушло примерно 511 MB суммарно по трём процессам.

## Interpretation

`work_mem` — бюджет узла, а не запроса; число одновременных узлов и
воркеров даёт множитель. Сброс на диск — предохранитель: запрос при
4 MB отработал, только медленнее.

## Неожиданное наблюдение

При `work_mem = 4MB` ведущий процесс **без** параллелизма занял больше
(368 MB), чем с ним (216 MB). Работа не исчезла: при параллельном плане
её часть унесли отдельные процессы, память которых в этой таблице не
учтена. В тексте главы этого наблюдения нет.

## Не измерено

Concurrency envelope — поведение при N одновременных таких запросах и
точка, где машина перестаёт справляться. Именно эту часть, судя по
названию, ожидает рукопись от `ch04-memory-envelope`.
