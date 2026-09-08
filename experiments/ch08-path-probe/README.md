# Стенд главы 8: Path Probe

Вопрос: что происходит с Paths, когда EXPLAIN показывает, что индекс
"не использовался".

EXPLAIN показывает победителя. Path Probe показывает, какие кандидаты
создавались, какие приняты, какие отсеяны и какой Path кого вытеснил.

## Что нужно

Инструментованная сборка PostgreSQL: патч
`0001-path-probe-instrument-add_path.patch` добавляет в `add_path()`
одну строку лога на каждое решение.

```sh
git clone --depth 1 --branch REL_16_STABLE \
    https://github.com/postgres/postgres pgsrc
cd pgsrc && patch -p1 < .../0001-path-probe-instrument-add_path.patch
./configure --prefix=/tmp/pgprobe --without-icu --without-readline \
            --without-zlib CFLAGS="-O1"
make -j2 && make install
```

В `postgresql.conf` собранного кластера:

```text
log_min_messages = debug1
log_error_verbosity = terse
log_line_prefix = ''
```

Патч не является частью upstream и не предназначен для production:
`elog(DEBUG1)` в `add_path()` меняет стоимость планирования.

## Прогон

```sh
psql -f setup.sql
psql -f queries.sql          # три плана
./probe.sh "SELECT o.* FROM customers c JOIN orders o
            ON o.customer_id = c.id WHERE c.id BETWEEN 100 AND 4999"
```

`probe.sh` чистит лог, выполняет `EXPLAIN` и раскладывает строки
PATHPROBE в таблицу через `decode.py`. Номера узлов расшифровываются по
`nodetags.h` той же сборки: между версиями они не переносятся.

## Как читать трассу

```text
решение   rel  узел          startup    total     rows  pk  req_outer
accepted  2    T_IndexScan      0.43  87908.16  2000000   1  none
accepted  2    T_IndexScan      0.43     14.01      101   1  1
```

Это два Path одного индекса. Второй параметризован: `req_outer=1`
означает, что он имеет смысл только внутри join с отношением 1.
Сравнивать их между собой нельзя, они не конкуренты.

`pk` - число pathkeys. Path с pathkeys может выжить, будучи дороже:
у него есть свойство, которого нет у конкурента.

## Классификация результата

Каждый опыт полезно отнести к одному из трёх случаев:

**A.** Кандидат существовал и выжил на своём уровне, а проиграл выше.
Тогда "индекс не использовался" означает "join method над ним
оказался дешевле".

**B.** Кандидат был отсеян ещё в baseline, и нужный верхний Path
поэтому вообще не мог быть построен. Тогда каскадный эффект отсева
виден только в трассе, а в EXPLAIN выглядит как нелюбовь к индексу.

**C.** Нужную форму плана нельзя построить и под ограничением. Тогда
дело не в стоимости, а в том, что такого access path нет.

Различить A и B по EXPLAIN невозможно. Ради этого стенд и существует.

## Тот же опыт без локального патча

`hackers/` содержит серию v3 для pgsql-hackers: четыре события
(`accept`, `reject`, `displace`, `precheck-reject`), оформленные как
injection points, и действие `path-prune-notice` в тестовом модуле.

Серия собрана на master 20devel и прогнана целиком: патчи накладываются
на свежий клон, сборка чистая, `make check` модуля проходит, демо
воспроизводит все три требуемых признака. Трассы в
`hackers/demo/trace-observed.log` и
`hackers/demo/trace-observed-join.log`.

История версий: v1 - моя серия из трёх событий без `precheck-reject`;
v2 - серия @yoda с `precheck-reject`, но без `accept`; v3 - объединение,
плюс загрузка точек один раз за вызов планировщика и исправления,
перечисленные в `hackers/README.md`. Ревью v2 - в
`reviews/2026-09-08-planner-pruning-injection-v2.md`.

Порядок такой: книга породила эксперимент, эксперимент потребовал
инструмент, инструмент оформлен как минимальная observability в core.
Если серию примут, из стенда уйдут локальный патч и своя сборка, а
останется:

```text
hackers/demo/setup.sql
hackers/demo/demo.sql
path-prune-notice
hackers/demo/analyze.sh
```

Локальный патч `0001-path-probe-instrument-add_path.patch` и
`decode.py` остаются только как история: они работают на PostgreSQL 16 и
не требуют `--enable-injection-points`. Для новых прогонов пользоваться
надо серией из `hackers/`.

## Чего стенд не делает

Не заменяет `pg_plan_advice` (PG19): тот отвечает на другой вопрос -
можно ли получить желаемую форму плана, ограничив planner, и сообщает,
применилось ли ограничение. Здесь этого слоя нет, сборка сделана из
REL_16_STABLE. Подмена через `enable_*` не эквивалентна: GUC запрещает
альтернативу глобально и обратной связи не даёт.
