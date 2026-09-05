---
title: "Работающий PostgreSQL"
subtitle: "Flight Edition — археология, рабочий день и прояснение PostgreSQL"
author: "Working research draft"
date: "5 сентября 2026"
lang: ru-RU
---



\newpage

# Работающий PostgreSQL — Flight Edition

**Рабочая версия для чтения в дороге. 5 сентября 2026.**

Это ещё не manuscript и не финальное оглавление. Это уже больше, чем набор заметок: здесь собран первый полный круг идей книги — от измерения одного запроса до рабочего дня, от VACUUM и NUMA до FTS, HTAP, failover и automation.

## Как это читать

Я бы читал не по номеру релиза и не как reference manual.

Сначала держать в голове три вопроса:

1. **Какую реальную боль мы видим?**
2. **Почему PostgreSQL ведёт себя именно так?**
3. **Как понять, что после нашего действия система действительно вернулась в устойчивое состояние?**

В книге постоянно появляются четыре языка:

### Debt

Работа, созданная сейчас, часто должна быть обслужена позже: request backlog, vacuum debt, WAL retention, replay, ETL, logging, warm-up.

### Boundary

Цена часто появляется на границе: PostgreSQL ↔ external search, core ↔ extension, producer ↔ consumer, primary ↔ replica, OLTP ↔ analytics.

### Placement of work

Важно не только сколько физической работы выполняется, но **где и когда** она выполняется. Checkpoint spreading, HOT, NUMA locality, online REPACK — всё об этом.

### Truth

В реальной системе есть PostgreSQL, replicas, caches, search, warehouse. Надо всегда понимать, какое состояние authoritative, а какое derived и как оно догоняет/перестраивается.

## Что в этой версии уже сильное

- tails → transaction debt и headroom;
- checkpoint archaeology;
- VACUUM/HOT/visibility-map evolution;
- NUMA как пример правильного causal experiment;
- FTS как выбор consistency boundary;
- extensions как способность научить PostgreSQL новой семантике;
- executor boundary и vectorization;
- logging как workload;
- warm-up как часть RTO;
- replica lag как очередь;
- truth/ETL/HTAP;
- security как decomposition superuser capabilities;
- online maintenance как перенос цены из blocking в catch-up;
- backup/failover как работа с историей;
- operational day как unit of performance;
- automation/AI через invariants и convergence.

## Где текст пока неоднороден

Первые два archaeology dossier писались как исследовательские рабочие документы и местами ещё слишком похожи на report. Более поздние части уже специально написаны ближе к практику — через ситуацию, вопрос и эксперимент. При следующем проходе ранние части надо переписать тем же голосом.

Это важное правило всей книги:

> **Мы не пишем академическую историю PostgreSQL. Мы сидим рядом с практиком, видим странное поведение работающей базы и вместе выясняем, почему оно такое.**

## PostgreSQL 19

На 5 сентября 2026 PostgreSQL 19 находится на Beta 3. GA ещё не объявлена. Всё, что относится к `REPACK`, autovacuum scoring/parallelism, `WAIT FOR LSN`, `pg_plan_advice` и другим PG19-specific деталям, перед печатью надо ещё раз проверить по GA release notes и документации.

Текущий статус:
https://www.postgresql.org/about/news/postgresql-186-1711-1615-1519-1424-and-19-beta-3-released-3365/

## Порядок чтения

1. `01-master-map.md` — карта всей книги.
2. `02-archaeology-checkpoint-vacuum-numa.md` — debt и physical placement of work.
3. `03-archaeology-fts-extensions-executor.md` — boundary внутри и вокруг PostgreSQL.
4. `04-logging-warmup-replication.md` — движение состояния и производные.
5. `05-truth-etl-htap.md` — истина и её копии.
6. `06-security-online-backup-failover.md` — контролируемое изменение живой системы.
7. `08-connections-locks-planner-upgrade.md` — скрытое operational state.
8. `07-capacity-incidents-automation.md` — рабочий день и финальная модель.
9. `09-release-notes-archaeological-index.md` — индекс для дальнейших раскопок.



\newpage

# Работающий PostgreSQL
## Археология 01: checkpoint tails, VACUUM debt, NUMA / multi-socket

Рабочий исследовательский dossier, 5 сентября 2026.

Цель этого документа — не пересказать историю фич. Для каждой темы мы пытаемся восстановить цепочку:

> **production pain → motivating workload → hackers discussion → architectural change → source boundary → evolution → what still matters in PG19 → reproducible experiment → chapter thesis**

Это первый глубокий проход по трём якорным историям книги.

---

# 1. Checkpoint tails: почему «одна секунда затыка» может испортить десять секунд после неё

## 1.1. Практический вход в главу

Пользовательская ситуация:

> Почти все запросы быстрые. Но раз в несколько минут p99 резко взлетает.  
> После самого затыка запросы ещё долго идут медленнее. Почему короткое событие оставляет длинный след?

На этом месте не надо начинать с определения checkpoint.

Сначала вводим простую модель очереди.

Если:
- arrival rate = 1000 tx/s;
- sustainable service capacity = 1100 tx/s;
- система на 1 секунду почти перестаёт завершать транзакции,

то за stall возникает примерно 1000 транзакций backlog.

После stall остаётся только:

`1100 - 1000 = 100 tx/s`

свободной мощности для погашения очереди.

Следовательно, одна секунда stall создаёт примерно десять секунд recovery.

Главный вывод:

> **Цена stall определяется не только его длительностью, а отношением текущей нагрузки к spare capacity.**

Поэтому p99 сам по себе ещё не описывает ущерб. Нужны:
- stall duration;
- stall frequency;
- backlog created;
- catch-up rate;
- time to baseline.

---

## 1.2. Что болело до PostgreSQL 8.3

7 декабря 2006 года ITAGAKI Takahiro начал hackers thread **“Load distributed checkpoint”**.

Формулировка проблемы почти готова для книги:

- во время checkpoint наблюдался заметный performance gap;
- причиной назывался burst записи;
- storage device перегружался checkpoint work;
- обычным транзакциям переставало хватать I/O capacity;
- самым тяжёлым шагом checkpoint был массовый write dirty pages из buffer pool.

Это важно: distributed checkpoint родился не из абстрактного желания «улучшить алгоритм checkpoint», а из **foreground latency/interference problem**.

Источник:
https://www.postgresql.org/message-id/20061207144843.6269.ITAGAKI.TAKAHIRO%40oss.ntt.co.jp

В феврале 2007 Greg Smith инструментировал pgbench и показал пример, где checkpoint database fsync занимал примерно **17.7 секунд**, а клиенты в этот период висели.

Источник:
https://www.postgresql.org/message-id/Pine.GSO.4.64.0702192155530.20153%40westnet.com

Это отличный исторический эпизод для книги: вместо графика «checkpoint плохой» у нас есть реальный замер, где внутренний maintenance phase становится пользовательским stall.

---

## 1.3. Как менялась постановка задачи

Первоначально обсуждались более сложные идеи:
- сортировать writes;
- дозировать скорость;
- разносить write и sync phases;
- использовать аналоги vacuum cost delay.

К июню 2007 Heikki Linnakangas сознательно упростил цель:

> сначала **просто spread the writes**, потому что этого уже достаточно, чтобы сгладить checkpoint I/O spike; сортировку можно оставить на дальнейшее развитие.

Источник:
https://www.postgresql.org/message-id/46726B2E.7060606%40enterprisedb.com

Это очень хороший урок проектирования:

> Когда известна production pain, сначала убрать главный причинный механизм, а не пытаться одновременно построить идеальный I/O scheduler.

В PostgreSQL 8.3 distributed checkpoints вошли как основная фича. Release notes объясняют её через тот же operational symptom: раньше modified buffers быстро сбрасывались, создавая I/O spike и снижая server performance; теперь writes растягиваются во времени.

Источник:
https://www.postgresql.org/docs/8.3/release-8-3.html

Исторический commit:
`867e2c91a0c341111b7a5257dc4c9a2659a022dc`
“Implement distributed checkpoints.”

---

## 1.4. Архитектурный смысл: долг не исчез, изменилось его распределение во времени

Это, пожалуй, важнее самой истории patch.

Checkpoint spreading **не удаляет обязательную запись**.

Если в buffer pool накоплено N dirty pages, их всё равно придётся довести до persistent storage.

Меняется:

- temporal concentration;
- queue depth;
- competition with foreground;
- вероятность длинного tail event.

То есть:

`same write debt → different scheduling`

Это одна из центральных идей всей книги:

> **Сколько работы сделано — недостаточный performance question. Надо знать, когда эта работа выполнена и с какой концентрацией.**

Именно поэтому:
- background work может разрушить foreground;
- average I/O throughput может выглядеть нормально;
- p99 и backlog могут быть плохими.

---

## 1.5. Почему smoothing одного слоя не гарантирует smoothing системы

В 2012 году в discussion **“Massive I/O spikes during checkpoint”** Jeff Janes указал очень важную границу:

PostgreSQL действительно мог равномерно писать data в kernel page cache, но kernel при этом накапливал dirty pages, а затем fsync-и всё равно приходили «как бомбы».

Источник:
https://www.postgresql.org/message-id/CAMkU%3D1zRS0fObMNyuH50UxA170GfqwvfRvc3s6gq-wgAhMtjog%40mail.gmail.com

Это замечательный сюжет для «прояснения PostgreSQL»:

```text
PostgreSQL schedules writes
        ↓
kernel buffers writes
        ↓
storage schedules actual I/O
```

Оптимизировать один слой недостаточно, если следующий снова собирает работу в burst.

Отсюда общий operational principle:

> **Очереди и smoothing надо прослеживать через всю service chain.**

Точно так же позже мы будем смотреть:
- WAL generation → archive transport;
- primary WAL → standby receive → flush → replay;
- log generation → shipper → collector;
- transactional change → ETL → warehouse.

---

## 1.6. Почему появился отдельный checkpointer

До PostgreSQL 9.2 background writer одновременно:
- занимался page cleaning;
- выполнял checkpoints.

Simon Riggs сформулировал проблему так: final checkpoint fsync останавливал background writing, то есть две разные service functions конкурировали внутри одного process loop.

Source discussion:
https://www.postgresql.org/message-id/CA%2BU5nMLv2ah-HNHaQ%3D2rxhp_hDJ9jcf-LL2kW3sE4msfnUw9gA%40mail.gmail.com

Commit:
`806a2aee3791244bf0f916729bfdb5489936e068`

Commit message:
https://www.postgresql.org/message-id/E1RLHwI-0007rE-MP%40gemulon.postgresql.org

PG9.2 release notes объясняют, что split делает обе задачи более predictable:
https://www.postgresql.org/docs/release/9.2.0/

Это опять не «ещё один process». Это разделение двух control loops:

```text
background cleaning
        ≠
checkpoint completion
```

---

## 1.7. Что осталось в PostgreSQL 19

В PG19 `checkpoint_completion_target` по умолчанию 0.9.

Документация прямо рекомендует растягивать checkpoint почти на весь доступный interval, потому что уменьшение target повышает I/O rate во время checkpoint, а затем оставляет период с меньшим I/O.

Источник:
https://www.postgresql.org/docs/19/runtime-config-wal.html

PG19 также различает manual fast/spread checkpoint:
`CHECKPOINT (MODE SPREAD)`.

Источник:
https://www.postgresql.org/docs/19/sql-checkpoint.html

То есть через почти двадцать лет исходный operational principle остаётся тем же:

> **Не концентрировать обязательную write work без необходимости.**

Но hardware и I/O stack изменились, поэтому chapter должен соединить эту историю с:
- AIO;
- NVMe queue depth;
- kernel dirty writeback;
- storage latency tails.

---

## 1.8. Эксперимент для книги: «Сколько долга создаёт checkpoint tail?»

### Hypothesis

При workload близком к sustainable capacity короткое ухудшение service rate во время checkpoint создаёт backlog, который живёт намного дольше самого checkpoint event.

### Setup

PG19, rate-limited `pgbench`, сначала определить sustainable throughput.

Например:
- max sustainable ≈ 1100 tx/s;
- experiment arrival ≈ 900–1000 tx/s;
- headroom намеренно небольшой, но не нулевой.

### Phases

1. baseline;
2. normal spread checkpoint;
3. intentionally more concentrated / forced checkpoint;
4. recovery.

### Measure

PostgreSQL:
- `pg_stat_checkpointer`;
- WAL generation;
- `pg_stat_io`;
- `pg_stat_activity` waits.

Client:
- arrival rate;
- completion rate;
- p50/p95/p99;
- schedule lag;
- per-transaction logs.

OS/storage:
- write bandwidth;
- write latency;
- queue depth;
- dirty pages.

### Derived metrics

`debt_created = arrivals - completions`

`catchup_capacity = completions_after_stall - arrivals_after_stall`

`recovery_time = time until backlog returns to baseline envelope`

### Figure for book

One graph with:
- transaction backlog;
- p99;
- checkpoint phase.

The main visual discovery should be:

> checkpoint event is short; its **shadow** in backlog is long.

---

## 1.9. Invariant

> **Checkpoint/write debt must be scheduled so that foreground SLA survives and any backlog created by normal checkpoint activity converges before the next disturbance.**

This is much stronger than:
“set `checkpoint_completion_target` to X.”

---

# 2. VACUUM archaeology: от неизбежного MVCC debt к всё более умному обслуживанию

## 2.1. Практический вход

> Мы просто UPDATE-или строку.  
> Почему PostgreSQL оставил старую версию?  
> Почему теперь отдельный daemon должен за нами убирать?

Это одна из тех тем, где плохая книга начинает с настройки autovacuum.

Наша должна сначала сделать VACUUM **неизбежным следствием выбранной concurrency model**.

PostgreSQL non-overwriting MVCC:
- update создаёт новую physical tuple version;
- старая version может ещё быть нужна старому snapshot;
- значит, её нельзя просто уничтожить в момент UPDATE;
- позже надо доказать, что она больше никому не нужна;
- это создаёт maintenance debt.

Основной invariant возникает ещё до autovacuum:

> **скорость обслуживания MVCC debt в достаточно длинном окне должна быть не меньше скорости его создания.**

---

## 2.2. История autovacuum: maintenance становится частью server control loop

В ранних версиях vacuum был задачей DBA/scheduler. К эпохе 7.4 autovacuum существовал как отдельный tool.

К PostgreSQL 8.1 integrated autovacuum стал частью server architecture.

Это эволюционный сдвиг:

```text
operator remembers maintenance
        ↓
external automation
        ↓
database observes its own change rate
        ↓
server schedules maintenance
```

Смысл не в удобстве daemon-а. PostgreSQL признал, что MVCC debt — **собственное внутреннее обязательство системы**, которое нельзя надёжно оставить на человеческий cron.

---

## 2.3. HOT: не ждать VACUUM для всей работы

В феврале 2007 Simon Riggs представил упрощённую модель Heap-Only Tuples.

Базовая идея:
- UPDATE не меняет indexed columns;
- новая tuple version помещается на ту же heap page;
- тогда можно избежать создания новых index tuples.

Источник:
https://www.postgresql.org/message-id/1170869906.3645.768.camel%40silverbirch.site

До этого существовала более сложная “Frequent Update Project” / Heap Overflow Tuple design.

Особенно интересны motivating benchmarks из design overview:
- pgbench/TPC-B: в благоприятном тесте заявлялось примерно 200–300% improvement;
- DBT-2/TPC-C: порядка 10%, измерить труднее;
- специальный `truckin`: около 500%.

Источник:
https://www.postgresql.org/message-id/1163092396.3634.461.camel%40silverbirch.site

Эти числа нельзя переносить в современную рекомендацию. Их ценность в другом:

> Разработчики искали workload, где **физическая цена frequent updates** действительно доминирует.

Release discussion подчёркивала два operational effects HOT:
- dead tuple space может становиться reusable раньше;
- duplicate index entries не создаются;
- performance становится более consistent.

Источник:
https://www.postgresql.org/message-id/200802072100.20093.dfontaine%40hi-media.com

---

## 2.4. Очень важный общий урок HOT: foreground vs background

HOT интересен для книги не только как оптимизация update.

Он показывает изменение **места выполнения maintenance work**.

Часть работы, которую раньше в большей степени приходилось делать VACUUM позже, переносится ближе к normal page activity / pruning.

То есть вопрос снова не:
“уменьшилось ли абсолютное число инструкций?”

А:

> **Какая часть долга обслуживается сразу, а какая откладывается?**

Это тот же performance principle, что checkpoint, только направление другое:
- checkpoint spreading переносит concentrated write work в distributed background;
- HOT позволяет часть reclamation делать локально раньше, уменьшая future vacuum/index debt.

Общий язык:

> **placement of work in time matters.**

---

## 2.5. Visibility map: потратить немного metadata, чтобы не делать огромную работу снова

В 2008 Heikki Linnakangas предложил visibility map:

- один bit на heap page;
- bit означает, что все tuples на page известны как visible to everyone;
- такую page не надо vacuum-ить ради dead tuple cleanup;
- эту же информацию можно использовать, чтобы skip visibility checks.

Он уже тогда отдельно писал, что это должно позволить **future index-only scans**.

Источник:
https://www.postgresql.org/message-id/4905AE17.7090305%40enterprisedb.com

Ещё раньше его rough plan был почти удивительно прямым:

1. map-fork infrastructure;
2. rewrite FSM;
3. visibility map for partial vacuums;
4. index-only scans using visibility map.

Источник:
https://www.postgresql.org/message-id/47FDA330.1080007%40enterprisedb.com

Это прекрасный сюжет эволюции:

> Metadata, созданные для уменьшения maintenance work, позже стали основой execution optimization.

То есть один architectural investment обслужил два разных control loops:
- VACUUM;
- query execution.

---

## 2.6. Но optimization столкнулась с safety invariant: XID wraparound

Как только VACUUM получил право пропускать all-visible pages, обнаружилась проблема.

Если pages пропускаются, нельзя автоматически продвигать `relfrozenxid`. Значит, partial vacuum сам по себе не гарантирует protection from XID wraparound.

Heikki сформулировал это очень явно в декабре 2008:
plain VACUUM, пропуская pages через visibility map, может не advance `relfrozenxid`; следовательно, периодически нужен full-scanning vacuum.

Источник:
https://www.postgresql.org/message-id/4948C911.7080901%40enterprisedb.com

Это почти идеальная история для нашей книги:

> Мы придумали metadata, чтобы безопасно **не делать работу**.  
> Но другой invariant требует иногда **намеренно проигнорировать optimization и всё-таки сделать полный проход**.

Общий принцип:

> **Optimization never outranks correctness/safety debt.**

---

## 2.7. PostgreSQL 17: даже структура памяти VACUUM стала debt bottleneck

PG17 заменил старое хранение dead TIDs более эффективным TIDStore.

Release notes:
- VACUUM теперь эффективнее хранит tuple references;
- исчезает старое молчаливое ограничение примерно в 1 GB для этого memory use при больших `maintenance_work_mem`/`autovacuum_work_mem`.

Источник:
https://www.postgresql.org/docs/17/release-17.html

Связанные commits:
- `ee1b30f12` — adaptive radix tree template;
- `30e144287` — TIDStore;
- `667e65aac` — use TIDStore for dead tuple TIDs during lazy vacuum;
- `6dbb49026` — combine freezing and pruning.

Источник со списком commits:
https://www.postgresql.org/message-id/ZjzUOdSTpEw4Dnyf%40momjian.us

Очень хорошая книга должна показать здесь ещё один слой:

> VACUUM может быть ограничен не только I/O или worker count. Даже representation собственного working state определяет, сколько debt он способен эффективно обслуживать за проход.

---

## 2.8. PostgreSQL 19: autovacuum начинает явно приоритизировать debt

В PG19 autovacuum больше не полагается только на прежний порядок eligible relations.

Теперь worker:
- формирует список eligible tables;
- вычисляет несколько component scores;
- сортирует по максимальному score.

Компоненты включают:
- XID age;
- multixact age;
- update/delete vacuum pressure;
- insert vacuum pressure;
- analyze pressure.

Документация:
https://www.postgresql.org/docs/19/routine-vacuuming.html

Release notes:
https://www.postgresql.org/docs/19/release-19.html

Commit, введший rudimentary table prioritization:
`d7965d65f`

PG19 также даёт `pg_stat_autovacuum_scores`, чтобы DBA мог видеть текущую оценку pressure.

Документация:
https://www.postgresql.org/docs/19/monitoring-stats.html

Но важная оговорка: view вычисляет score по **текущим** source values, а конкретный worker мог составить свой список раньше. Поэтому view — это evidence about pressure, а не deterministic oracle следующего действия autovacuum.

Это очень подходящая для книги формулировка:

> **Monitoring показывает модель scheduler-а, но не превращает scheduler в детерминированную машину.**

---

## 2.9. PG19 parallel autovacuum: parallelism тоже только часть service path

PG19 позволяет autovacuum использовать parallel workers для index vacuum/cleanup phases.

Но это не значит:
“autovacuum теперь полностью parallel”.

Надо разложить phases и показать, где parallelism действительно применён.

Это опять соответствует нашей книге:

> **Всегда спрашивай, какая именно часть service chain ускорилась.**

Иначе легко увидеть крупную фичу в release notes и сделать неверный operational вывод.

---

## 2.10. Эксперимент для книги: «Создаём vacuum debt и смотрим, может ли PostgreSQL его погасить»

### Dataset

Большая update-heavy table:
- primary key;
- один индекс по редко меняющемуся column;
- дополнительный column для HOT-friendly update;
- configurable `fillfactor`.

### Workloads

A. update only non-indexed column, enough same-page space → HOT-friendly.

B. update indexed column → HOT impossible.

C. как A/B, но держим старый transaction/snapshot.

D. intentionally constrain autovacuum service capacity.

### Observe

- `n_tup_upd`;
- `n_tup_hot_upd`;
- `n_dead_tup`;
- heap size;
- index size;
- WAL bytes;
- `pg_stat_progress_vacuum`;
- XID/freeze age;
- PG19 autovacuum score;
- user-workload p95/p99.

### Rate model

Measure:

`debt_creation_rate`

versus

`vacuum_repayment_rate`

Then stop/update-reduce foreground generation and observe whether vacuum debt converges.

### Important visual

Graph:
- dead tuples / estimated debt;
- autovacuum activity;
- foreground tail latency;
- old snapshot interval.

The reader should literally see:

> One old transaction can keep the debt alive even while autovacuum is working.

---

## 2.11. Invariant

> **MVCC debt and freeze debt remain bounded, and the maintenance system has enough capacity to reduce them after permitted peaks.**

Not:
“autovacuum runs often.”

---

# 3. NUMA / multi-socket: как хорошее правдоподобное объяснение может оказаться не главной причиной

## 3.1. Практический вход

> На большой multi-socket машине PostgreSQL масштабируется хуже, чем ожидалось.  
> Очевидно: remote NUMA memory медленнее. Значит, надо pin-ить процессы и память?

Эта глава должна быть построена как **детектив с неправильной первой гипотезой**.

Наша собственная важная наблюдаемая история:

> Было трудно получить сильное падение PostgreSQL workload, если экспериментировать только с ценой доступа к remote memory.

Это не значит, что NUMA не важна.

Это значит, что простая модель:

`remote RAM slower → PostgreSQL slow`

недостаточна.

---

## 3.2. Археология старых scalability fixes показывает, где реально болело

До современного “NUMA-aware PostgreSQL” community много лет исправляло multi-CPU scaling через shared-state contention.

Особенно показателен PG9.5/9.6 period.

### ProcArrayLock

В 2015 Amit Kapila исследовал contention вокруг `ProcArrayLock`.

На transaction end backend должен убрать advertised XID из ProcArray. При высокой concurrency множество committers конкурируют за exclusive lock.

Предложенное GroupClear:
- один backend получает lock;
- заодно очищает XID для группы ожидающих backends.

Hackers thread:
https://www.postgresql.org/message-id/CAA4eK1JbX4FzPHigNt0JSaz30a85BPJV%2Bewhk%2Bwg_o-T6xufEA%40mail.gmail.com

Мотивирующий benchmark:
- 8-socket machine;
- 64 cores / 128 hardware threads;
- 500 GB RAM;
- pgbench prepared TPC-B;
- scale 300;
- эффект становится особенно заметным при высокой client concurrency.

Очень важная оговорка самого обсуждения:
когда working set не в shared buffers и начинает доминировать I/O, lock optimization становится намного труднее увидеть.

Это textbook example для нашей methodology:

> **Чтобы увидеть concurrency bottleneck, сначала надо построить workload, где другой bottleneck его не маскирует.**

Commit:
`0e141c0fbb211bdd23783afa731e3eef95c9ad7a`

Идея этой истории гораздо шире ProcArrayLock:
performance bottleneck — это свойство workload + machine + shared architecture, а не label одного hardware feature.

---

## 3.3. PG9.6 multi-socket work: не «NUMA patch», а множество shared boundaries

В PG9.6 эволюция включала:
- reduction of `ProcArrayLock` contention;
- relocation/change of buffer content locking;
- replacement of some spinlock-protected state with atomics;
- changes in LWLock queue handling;
- more partitioning of shared structures/freelists;
- scaling CLOG buffers.

Это хорошо согласуется с реальной картиной multi-socket:

```text
local/remote latency
+
memory bandwidth
+
cache coherence
+
cache-line bouncing
+
lock ownership
+
shared-data layout
+
scheduler placement
+
working-set shape
```

Из этого нельзя вывести простое:
“NUMA не имеет значения.”

Можно вывести:

> **NUMA effects often manifest through shared-state topology and coherence, not only through one load from remote DRAM.**

---

## 3.4. Современная hackers дискуссия 2025–2026 почти повторяет наш экспериментальный путь

В июле 2025 Tomas Vondra опубликовал WIP patch series **“Adding basic NUMA awareness”** для shared memory, включая shared buffers и другие структуры.

Источник:
https://www.postgresql.org/message-id/099b9433-2855-4f1b-b421-d078a5d82017%40vondra.me

Это особенно ценно, потому что discussion ещё свежая и не превратилась в folklore.

### Что неожиданно выяснилось

В одном из более поздних разборов Tomas пишет, что:

- значительная часть observed benefit происходила от patches, которые **partition clocksweep NUMA-obliviously**;
- применение собственно NUMA-aware patches иногда даже **снижало throughput**.

Источник:
https://www.postgresql.org/message-id/0e1b997d-99c8-40f4-bc32-6c044bc7ed9a%40vondra.me

Это почти идеальная сцена для книги.

Исходная гипотеза:
“localize buffers by NUMA node → performance.”

Результат:
“часть выигрыша оказалась от уменьшения contention, даже без topology awareness.”

То есть эксперимент заставляет разделить две причины:

1. **less shared contention**;
2. **better NUMA locality**.

---

## 3.5. Но locality сама по себе тоже реальна

Andres Freund предложил другой тип workload:
- shared buffers уже физически размещены;
- relation больше shared buffers, но помещается в RAM;
- backend делает scan через circular/bulk buffer behavior;
- смотреть per-socket memory traffic и реально потребляемые tuples.

В обсуждении отдельно замечается, что query shape имеет значение: вариант, который фактически не деформирует tuples, может скрыть latency-sensitive path.

Источник:
https://www.postgresql.org/message-id/zndz3dlmp7xlypczxjbwdfrey3masto6vuwpnzjvgunslprv25%40rucfkdgfpb4p

Это тонкий, но очень важный lesson:

> **Даже «sequential scan» — недостаточно точное описание workload для NUMA experiment. Надо знать, что executor реально делает с каждой tuple.**

На некоторых machines измерения local/remote memory были почти одинаковыми — возникло подозрение на memory interleaving.

Источник:
https://www.postgresql.org/message-id/w2fqzrcwo6ofjy56e5pd7hsjdnlhc5tckgpsio77sqtgcylbvx%40eeknrzc7o7ov

То есть hardware topology, BIOS/cloud configuration и interleaving могут полностью изменить эксперимент.

---

## 3.6. Два разных NUMA риска, которые надо развести в книге

### A. Latency

Backend часто обращается к remote memory и платит более высокую access latency.

Особенно заметно на latency-sensitive pointer-heavy paths.

### B. Bandwidth / interconnect saturation

Даже если latency difference отдельного access умеренная, большой concurrent workload может упереться в aggregate cross-socket traffic/interconnect bandwidth.

Это совершенно разные experiments.

Именно поэтому microbenchmark “local pointer chase vs remote pointer chase” не доказывает production consequence.

---

## 3.7. Process vs thread естественно входит сюда

Современный scheduler относится к threads/processes гораздо ближе, чем старый folklore “process switch is huge”.

Но PostgreSQL backend-per-process сохраняет важные architectural boundaries:

- separate virtual address space;
- private memory/context;
- explicit shared-memory structures;
- copied/duplicated backend-local state;
- process-local allocator/cache behavior;
- connection lifecycle;
- extension APIs;
- scheduler/NUMA placement opportunities.

Следовательно, вопрос книги:

> **Какая из этих границ сегодня реально создаёт measurable cost?**

Переход на threads сам по себе не устраняет:
- shared cacheline contention;
- memory-bandwidth limit;
- poor shared-state partitioning;
- bad workload locality.

А некоторые границы, наоборот, radically change.

Поэтому “threads vs processes” должен быть не идеологической главой, а continuation NUMA methodology.

---

## 3.8. Экспериментальная лестница для книги

Нельзя начинать сразу с pgbench и заключать “NUMA matters/doesn’t matter”.

### Level 1 — raw memory

Measure local vs remote:
- latency;
- bandwidth.

Цель: понять hardware envelope.

### Level 2 — OS scheduling / placement

Pin CPU, vary memory placement/interleave.

Цель: доказать, что topology controls действительно работают.

### Level 3 — PostgreSQL shared memory

Inspect distribution of shared allocations / shared buffers where tooling permits.

Не poll-ить дорогие NUMA-introspection views как normal monitoring: само наблюдение может touch/page-in memory and perturb placement.

### Level 4 — shared contention

Run high-concurrency, fully-cached workload:
- ProcArray-like transaction end pressure;
- buffer pool hot paths;
- many clients.

Цель: увидеть coherence/lock/cacheline effects without storage masking.

### Level 5 — scan/locality

Working set > shared buffers but < RAM; controlled scan with tuple deformation/aggregation.

Цель: isolate memory locality and bandwidth path.

### Level 6 — mixed real workload

OLTP + analytic scan / many backends.

Цель: observe real interference.

Only after these levels:

> discuss pinning / memory policy / NUMA-aware partitioning.

---

## 3.9. Invariant

Не нужен invariant типа:
“all memory should be local.”

Более полезный:

> **A production workload must have enough locality and shared-state scalability that adding concurrency does not turn coherence/interconnect/shared-lock traffic into the dominant service bottleneck.**

И diagnostic invariant:

> **Нельзя объявлять NUMA причиной, пока workload не различает locality cost от shared contention и bandwidth saturation.**

---

# 4. Что объединяет эти три истории

На поверхности:
- checkpoint;
- VACUUM;
- NUMA

кажутся тремя совершенно разными главами.

На самом деле они показывают один и тот же стиль мышления.

## 4.1. Work placement

Checkpoint:
- same write obligation;
- changed distribution in time.

HOT:
- часть future vacuum/index work переносится ближе к page update/prune.

NUMA:
- same logical database work;
- radically different cost depending where shared state and execution are placed physically.

Общая формула:

> **Performance is not only the amount of logical work. It is where and when physical work happens.**

---

## 4.2. Hidden queue

Checkpoint:
- transaction backlog.

VACUUM:
- dead tuple/freeze debt.

NUMA:
- hardware queues, coherence traffic, lock waiters, interconnect pressure.

В каждом случае current state недостаточен.

Нужна производная:
- growing or shrinking?

---

## 4.3. One-layer optimization can move the problem

Checkpoint writes spread → kernel can still accumulate dirty pages.

HOT reduces index/vacuum debt → foreground page pruning/reclamation work increases.

NUMA-aware memory placement → contention on clocksweep/shared structures can still dominate; partitioning alone may produce most of the gain.

Общий урок:

> **Не останавливай причинную цепочку на первом слое, где метрика стала лучше.**

---

# 5. Как эти три истории должны выглядеть в самой книге

## Chapter opening: checkpoint

> В 10:03:12 PostgreSQL почти перестал отвечать на секунду.  
> В 10:03:13 всё уже «исправилось».  
> Но очередь вернулась к норме только в 10:03:24.  
> Какая из этих цифр — длительность проблемы?

После этого — queueing model, experiment, а WAL/checkpoint internals появляются только когда читателю уже нужно объяснение.

---

## Chapter opening: VACUUM

> Вчера таблицу сильно обновляли. Сегодня autovacuum работает часами.  
> Он лечит проблему или просто сообщает нам, что проблема уже произошла?

Сначала debt, потом MVCC, потом история HOT/VM, затем PG19 scheduling.

---

## Chapter opening: NUMA

> У нас двухсокетная машина. Remote memory медленнее local.  
> Мы специально заставили PostgreSQL ходить «не туда» — и почти ничего не произошло.  
> Значит, NUMA не важна?

И дальше именно **неудача первого эксперимента** ведёт читателя к настоящей архитектуре.

---

# 6. Что ещё надо докопать перед окончательным текстом этих глав

## Checkpoint

- source before/after commit `867e2c91...` — точная change map по checkpoint scheduling;
- evolution of write/sync separation after 8.3;
- current `pg_stat_checkpointer` fields in PG19;
- interaction with PG18/19 AIO and kernel writeback;
- reproducible PG19 benchmark on NVMe.

## VACUUM

- precise source evolution of HOT pruning boundary;
- when/how VM gained all-frozen semantics after initial one-bit design;
- index-only scan implementation lineage;
- exact PG19 autovacuum parallel phase behavior/defaults at GA;
- experiment comparing TIDStore-era PG17+ with older behavior may be historical only, not necessary for conference edition.

## NUMA

- reconstruct PG9.5/9.6 source diffs for ProcArray/buffer locks/atomics;
- reproduce GroupClear-style contention on current PG19;
- inspect current NUMA patch series status before publication;
- establish whether PG19 final ships any NUMA observability/patch pieces discussed in devel;
- develop one experiment where raw remote memory difference is visible but PostgreSQL effect is small, and another where shared contention/locality makes effect large.

---

# 7. Candidate figures

1. **Stall shadow**
   - one-second stall;
   - ten-second backlog recovery.

2. **Checkpoint work distribution**
   - same total write debt, burst vs spread.

3. **MVCC debt control loop**
   - update generates versions;
   - HOT/prune repays locally;
   - VACUUM repays globally;
   - long snapshot blocks repayment.

4. **Visibility map as knowledge**
   - one metadata bit avoids reading a whole page;
   - same knowledge later enables index-only scan.

5. **NUMA causal ladder**
   - remote latency → bandwidth → coherence → shared lock/cacheline → SQL workload.

6. **Wrong diagnosis**
   - “NUMA-aware patch helps”;
   - decomposition shows most benefit from topology-oblivious clocksweep partitioning.

---

# 8. Sources

## Checkpoint

- ITAGAKI Takahiro, “Load distributed checkpoint”, 2006  
  https://www.postgresql.org/message-id/20061207144843.6269.ITAGAKI.TAKAHIRO%40oss.ntt.co.jp
- Greg Smith, checkpoint fsync instrumentation, 2007  
  https://www.postgresql.org/message-id/Pine.GSO.4.64.0702192155530.20153%40westnet.com
- Heikki Linnakangas, revised distributed checkpoint patch, 2007  
  https://www.postgresql.org/message-id/46726B2E.7060606%40enterprisedb.com
- PostgreSQL 8.3 release notes  
  https://www.postgresql.org/docs/8.3/release-8-3.html
- Simon Riggs, separating bgwriter/checkpointer  
  https://www.postgresql.org/message-id/CA%2BU5nMLv2ah-HNHaQ%3D2rxhp_hDJ9jcf-LL2kW3sE4msfnUw9gA%40mail.gmail.com
- Checkpointer split commit message  
  https://www.postgresql.org/message-id/E1RLHwI-0007rE-MP%40gemulon.postgresql.org
- Jeff Janes, kernel dirty writeback / checkpoint spike  
  https://www.postgresql.org/message-id/CAMkU%3D1zRS0fObMNyuH50UxA170GfqwvfRvc3s6gq-wgAhMtjog%40mail.gmail.com
- PostgreSQL 19 WAL/checkpoint configuration  
  https://www.postgresql.org/docs/19/runtime-config-wal.html

## VACUUM / HOT / VM

- HOT for PostgreSQL 8.3  
  https://www.postgresql.org/message-id/1170869906.3645.768.camel%40silverbirch.site
- HOT design overview and motivating benchmark  
  https://www.postgresql.org/message-id/1163092396.3634.461.camel%40silverbirch.site
- Visibility map, partial vacuums  
  https://www.postgresql.org/message-id/4905AE17.7090305%40enterprisedb.com
- Earlier VM/FSM implementation plan  
  https://www.postgresql.org/message-id/47FDA330.1080007%40enterprisedb.com
- Visibility map and freezing  
  https://www.postgresql.org/message-id/4948C911.7080901%40enterprisedb.com
- PostgreSQL 17 release notes, VACUUM memory changes  
  https://www.postgresql.org/docs/17/release-17.html
- TIDStore commit lineage in PG17 release-note discussion  
  https://www.postgresql.org/message-id/ZjzUOdSTpEw4Dnyf%40momjian.us
- PostgreSQL 19 autovacuum prioritization  
  https://www.postgresql.org/docs/19/routine-vacuuming.html
- PostgreSQL 19 autovacuum score view  
  https://www.postgresql.org/docs/19/monitoring-stats.html
- PostgreSQL 19 release notes  
  https://www.postgresql.org/docs/19/release-19.html

## NUMA / multi-socket

- Amit Kapila, Reduce ProcArrayLock contention  
  https://www.postgresql.org/message-id/CAA4eK1JbX4FzPHigNt0JSaz30a85BPJV%2Bewhk%2Bwg_o-T6xufEA%40mail.gmail.com
- Tomas Vondra, Adding basic NUMA awareness  
  https://www.postgresql.org/message-id/099b9433-2855-4f1b-b421-d078a5d82017%40vondra.me
- NUMA discussion: benefit from topology-oblivious clocksweep partitioning  
  https://www.postgresql.org/message-id/0e1b997d-99c8-40f4-bc32-6c044bc7ed9a%40vondra.me
- NUMA scan/query-shape discussion  
  https://www.postgresql.org/message-id/zndz3dlmp7xlypczxjbwdfrey3masto6vuwpnzjvgunslprv25%40rucfkdgfpb4p
- Hardware interleaving discussion  
  https://www.postgresql.org/message-id/w2fqzrcwo6ofjy56e5pd7hsjdnlhc5tckgpsio77sqtgcylbvx%40eeknrzc7o7ov

---

# 9. Immediate next archaeology batch

Следующими логично разбирать:

1. **FTS inside PostgreSQL → external consistency boundary**
2. **Extensions → PostgreSQL as platform**
3. **Executor / ExecProcNode → tuple-at-a-time and vector boundary**
4. **Logging → observability as workload**
5. **Warm-up → system state after restart**
6. **Replication → lag as debt and consistency contract**

Это даст вторую половину «проясняющего» слоя книги: не maintenance/hardware, а boundaries between PostgreSQL and surrounding systems.


\newpage

# Работающий PostgreSQL
## Археология 02: поиск, расширяемость и executor

Рабочий dossier. Пишем не «историю PostgreSQL для истории», а пытаемся вместе с практиком понять три очень сегодняшних вопроса:

1. **Мне нужен хороший поиск. Почему бы сразу не вынести его во внешнюю систему?**
2. **Мне не хватает возможности PostgreSQL. Почему бы не написать отдельный сервис — или, наоборот, патч в core?**
3. **PostgreSQL медленнее современных аналитических движков. Правда ли, что достаточно “сделать vectorized scan”?**

Во всех трёх случаях ответ упирается в **границу**.

Поиск — граница между truth и derived index.

Extension — граница между ядром PostgreSQL и новой функциональностью.

Executor — граница между producer и consumer внутри самого PostgreSQL.

И всякий раз простое решение выглядит очевидным, пока мы не посмотрим, **что именно пересекает эту границу**.

---

# 1. Мне нужен поиск. Почему бы не вынести его во внешний search engine?

Представим обычную ситуацию.

У нас есть таблица документов. Пользователь изменил текст и права доступа. Через миллисекунду он делает поиск.

Если поиск внутри PostgreSQL, вопрос звучит довольно просто:

> Что видно моему snapshot и что мне разрешено видеть?

Если search index живёт в отдельной системе, неожиданно появляются ещё вопросы:

- дошло ли изменение до change stream?
- обработал ли его consumer?
- применился ли update в search index?
- дошло ли изменение ACL?
- в каком порядке применились изменения?
- что было после retry?
- можно ли заново построить индекс?
- из какого состояния истины его перестраивать?

Сам поиск от этого не становится плохим. Но мы создали **ещё одну систему со своей историей**.

Вот с этого я бы и начинал главу. Не с `tsvector`.

---

## 1.1. Почему FTS вообще хотелось сделать внутри PostgreSQL

В начале 2000-х проблема была очень земной: нужен быстрый полнотекстовый поиск по данным, которые уже живут в PostgreSQL.

Ранний `tsearch`/`tsearch2` рос как extension/contrib functionality. В 2002 в hackers уже можно увидеть рекомендацию использовать `tsearch`, потому что он работает с locale и даёт индексный поиск там, где простая строковая схема ломалась на non-C locale.

К 2005 обсуждение было уже не «может ли PostgreSQL искать текст», а **как должен физически работать индекс**. В письме о RD-tree/tsearch2 разбирались false drops, lossy representation, стоимость heap recheck и связь качества индекса с числом уникальных слов.

То есть FTS родился не как модная галочка «у базы должен быть search». Это была длинная инженерная работа над тем, как встроить другую семантику поиска в существующий executor/index framework.

Источники:
- https://www.postgresql.org/message-id/Pine.GSO.4.44.0207221129060.7568-100000%40ra.sai.msu.su
- https://www.postgresql.org/message-id/Pine.GSO.4.62.0501252217060.6363%40ra.sai.msu.su

---

## 1.2. Но даже мы пробовали вынести часть поиска наружу

Вот это в книге надо обязательно оставить, потому что оно разрушает слишком удобную легенду.

В 2004 обсуждался прототип `tsearchd` — внешний daemon со статическим inverted index.

Идея была гибридной:

- **archive/static** часть коллекции можно вынести в `tsearchd`;
- **online** часть, которая меняется и должна оставаться близко к metadata, остаётся в `tsearch2`.

То есть уже тогда реальный вопрос был:

> **Какая часть данных должна оставаться внутри transactional boundary, а какую можно превратить в более дешёвый derived index?**

Источник:
https://www.postgresql.org/message-id/Pine.GSO.4.58.0409291600370.14980%40ra.sai.msu.su

Мне это нравится намного больше, чем лозунг «PostgreSQL FTS лучше Elasticsearch».

Потому что правильный вывод другой:

> **Внешний поиск — это архитектурный trade. Иногда он оправдан. Но надо понимать, какую связь с истиной мы при этом разрываем.**

---

## 1.3. Что изменилось, когда tsearch2 вошёл в core

В PostgreSQL 8.3 full-text search из `contrib/tsearch2` был перенесён в core.

Release notes:
https://www.postgresql.org/docs/8.3/release-8-3.html

Интересно, что даже на последней прямой integration упёрлась не в алгоритм индекса, а в **семантику конфигурации**.

Bruce Momjian в августе 2007 описывал проблему:

- default text-search configuration через GUC легко mismatched;
- если требовать config в каждом вызове — ломается удобство casts;
- если зашивать config в type system — нужно больше инфраструктуры/typmod plumbing.

И вопрос звучал буквально: не отложить ли integration FTS из-за этого?

Источник:
https://www.postgresql.org/message-id/200708141900.l7EJ04g03722%40momjian.us

Это хороший урок для разработчика:

> **Когда фича становится частью ядра, трудная часть часто уже не алгоритм. Трудной становится её совместимость с общей семантикой системы.**

После integration конфигурация поиска стала нормальной частью SQL/system catalogs, а старый `tsearch2` остался compatibility layer.

---

## 1.4. FTS не застыл после 8.3

В 9.6 появился phrase search — новые операторы расстояния внутри `tsquery`.

Commit:
https://www.postgresql.org/message-id/E1aoCJy-0004bp-HI%40gemulon.postgresql.org

Это тоже полезная мысль для книги:

> Мы не однажды «встроили поиск». Мы расширили **язык семантики**, который planner/executor/indexes уже понимают как часть PostgreSQL.

И вот тут появляется настоящая разница между:
- внешним engine, который знает свою search semantics;
- PostgreSQL extension/core feature, которая может участвовать в SQL, JOIN, transactions, privileges и indexes.

---

## 1.5. Что сегодня должен спросить практик

Не:

> PostgreSQL FTS или внешний search?

А сначала:

### Какой freshness нужен?

- секунды?
- миллисекунды?
- read-your-writes?
- можно stale results?

### Где живут ACL?

Если document access изменился, когда search result должен перестать показывать документ?

### Что является truth?

Можно ли полностью удалить search cluster и построить его заново из PostgreSQL?

Если нельзя — у вас уже две истины.

### Что происходит при разрыве change stream?

Есть ли:
- offset/checkpoint;
- retry;
- idempotency;
- ordering;
- reconciliation?

### Что выигрываем снаружи?

Внешний search может дать:
- специализированное ranking;
- distributed indexing;
- масштабирование search workload;
- отдельную resource envelope;
- capabilities, которых нет или неудобно реализовать в PostgreSQL.

Это реальные плюсы. Просто их надо сравнивать не с «PostgreSQL search медленнее/быстрее», а с **ценой новой consistency boundary**.

---

## 1.6. Эксперимент для книги: «Два поиска»

Берём маленькую систему документов.

PostgreSQL:
- `documents`;
- `owner`;
- ACL;
- text;
- `tsvector`.

Вариант A:
- FTS внутри PostgreSQL.

Вариант B:
- change stream → простой внешний derived index.

Делаем четыре события:

1. insert document;
2. edit text;
3. revoke access;
4. stop consumer на 30 секунд и снова запустить.

И задаём человеку один и тот же вопрос:

> **Что должен увидеть пользователь прямо сейчас?**

Измеряем не только latency поиска, а:
- freshness lag;
- ACL lag;
- recovery backlog;
- rebuild path.

### Invariant

> **Every derived search index has an explicit authority, freshness bound, authorization contract and rebuild path.**

---

# 2. Мне нужна новая функциональность PostgreSQL. Где её правильная граница?

Представим другую ситуацию.

Нам нужна непальская дата.

Не просто красивый вывод строки, а настоящая семантика:
- parse/input;
- ordering;
- arithmetic;
- comparison;
- casts;
- индекс;
- возможно, преобразование в/из Gregorian date.

Существующий пакет почти подходит, но нам чего-то не хватает.

Что делать?

Написать сервис `nepali-date-service`?

Положить integer в таблицу и всю семантику держать в application?

Послать patch в PostgreSQL core?

Или научить сам PostgreSQL новому типу?

Вот тут надо прояснить одну вещь, которую многие пользователи PostgreSQL знают гораздо хуже, чем SELECT.

> **PostgreSQL с самого начала задумывался не только как готовая СУБД, но и как система, которую можно научить новой семантике данных.**

---

## 2.1. CREATE EXTENSION — не начало extensibility

Это важно исторически не перепутать.

В старой документации PostgreSQL 6.5 уже прямо написано, что система extensible потому, что она **catalog-driven**.

В catalogs описаны не только tables/columns, но:
- types;
- functions;
- access methods;
- operators и другая семантика.

И server может dynamically load user-written code.

Старая документация даже формулирует смысл почти идеально: эта способность делает Postgres удобным для быстрого прототипирования новых applications и storage structures.

Источники:
- https://www.postgresql.org/docs/6.5/extend.htm
- современная версия той же идеи:
  https://www.postgresql.org/docs/18/extend-how.html

То есть PostgreSQL был extensible задолго до команды `CREATE EXTENSION`.

---

## 2.2. Что тогда реально решил CREATE EXTENSION?

До PostgreSQL 9.1 extension обычно был набором:

- SQL scripts;
- functions;
- types;
- operators;
- casts;
- possibly shared library;
- install/uninstall scripts.

Для PostgreSQL эти objects существовали, но система плохо знала:

> **они вместе являются одной устанавливаемой сущностью.**

Это operational pain.

Dimitri Fontaine в patch 2010 описывал `Extension` как новый SQL object с OID, dependencies и pg_dump awareness.

Ключевая идея:
- создать объект extension;
- записать dependency всех принадлежащих ему objects;
- `pg_dump` понимает пакет как пакет;
- можно управлять lifecycle как одним целым.

Источник:
https://www.postgresql.org/message-id/m2mxqj2q9m.fsf%402ndQuadrant.fr

В 9.1 все contrib modules стали устанавливаться через `CREATE EXTENSION`, а не ручным запуском SQL scripts.

Источник:
https://www.postgresql.org/docs/9.1/release-9-1.html

Вот правильная формулировка:

> **PostgreSQL давно умел расширяться. CREATE EXTENSION сделал расширяемость эксплуатационно управляемой.**

Это как раз тема нашей книги.

---

## 2.3. Почему extension — это не «plugin API для пары функций»

Посмотрим на современную документацию Extending SQL.

Она перечисляет:

- functions;
- aggregates;
- data types;
- operators;
- operator optimization information;
- operator classes for indexes;
- package/lifecycle as extension.

Источник:
https://www.postgresql.org/docs/current/extend.html

Именно поэтому пример с непальской датой хороший.

Мы можем не просто хранить `207...` как opaque string.

Мы можем определить:

```text
nepali_date
    ↓
input/output
    ↓
comparison
    ↓
operators
    ↓
casts
    ↓
B-tree semantics
```

И для SQL/planner это уже **настоящий тип**, а не application convention.

Вот это надо дать практику почувствовать руками.

---

## 2.4. Потом extension boundary стала ещё шире

PostgreSQL 9.4 дал extensions/внешнему коду две очень важные возможности:

- dynamic background workers;
- dynamic shared memory.

Release notes:
https://www.postgresql.org/docs/9.4/release-9-4.html

То есть extension уже может быть не просто новой функцией внутри SQL.

Он может иметь:
- собственную background activity;
- shared state;
- server-side lifecycle.

В PostgreSQL 13 появляется понятие **trusted extension**: некоторые extensions можно устанавливать пользователю с database-level `CREATE`, не выдавая superuser.

Источник:
https://www.postgresql.org/docs/13/release-13.html

Это уже связывает extensibility с нашей security line:

> Чем мощнее extension boundary, тем важнее понимать capability, которую мы загружаем внутрь authoritative database process.

---

## 2.5. Но «без остановки» надо говорить аккуратно

Практический плюс extensions огромный:

```sql
CREATE EXTENSION ...
```

и новая SQL/data functionality появляется в работающей database.

Но не надо превращать это в миф:
«любой extension ставится без restart».

Некоторые компоненты требуют `shared_preload_libraries` или другой startup-time integration.

Современная документация прямо отделяет такие modules от обычных `CREATE EXTENSION` packages.

Источник:
https://www.postgresql.org/docs/current/contrib.html

То есть operational question:

> **Какая часть новой capability dynamic, а какая пересекает startup/process/shared-memory boundary?**

---

## 2.6. Когда extension лучше внешнего сервиса

Очень простой критерий.

Если новая capability тесно связана с:

- data type semantics;
- transactional visibility;
- SQL expressions;
- indexes;
- constraints;
- joins;
- access control;

то сначала надо серьёзно рассмотреть extension.

Иначе можно получить:

```text
PostgreSQL value
      ↓ serialize
network
      ↓ parse
external service
      ↓ result
network
      ↓
PostgreSQL/application
```

там, где вся семантика могла жить рядом с данными.

Но если capability:
- требует совершенно другой scaling model;
- имеет отдельный failure/resource domain;
- использует runtime, который опасно тащить в backend;
- логически является отдельным service;

тогда external boundary может быть правильной.

И снова мы не ищем универсальную религию. Мы **выбираем границу**.

---

## 2.7. Эксперимент для книги: «Nepali date за один вечер»

Это может быть прекрасная маленькая практическая глава/бокс.

Сначала плохой вариант:

```sql
CREATE TABLE events (
    nepali_date text
);
```

И сразу вопросы:

- какая строка больше?
- можно ли сделать range query?
- что значит + 1 day?
- индекс понимает chronology?

Потом маленький extension:

- internal representation;
- input/output;
- comparison operators;
- cast;
- B-tree operator class.

И запрос:

```sql
SELECT *
FROM events
WHERE nepali_date >= ...
ORDER BY nepali_date;
```

Начинает работать **с нашей новой семантикой как с родной**.

Главный wow-effect не производительность.

> **Мы не научили application обходить PostgreSQL. Мы научили PostgreSQL понимать новый кусок мира.**

---

## 2.8. Invariant для platform boundary

> **Before adding another system, ask whether the missing capability is data semantics that PostgreSQL can own transactionally and index natively.**

И обратный:

> **Do not load arbitrary capability into PostgreSQL merely because extension machinery allows it; the database is an authoritative failure domain.**

---

# 3. PostgreSQL медленнее на аналитике. Всё из-за tuple-at-a-time?

Здесь особенно легко написать плохую главу.

Плохая версия:

> PostgreSQL использует Volcano iterator model.  
> Vectorized databases работают batches.  
> Поэтому надо сделать PostgreSQL vectorized.

В этой истории сразу две проблемы.

Первая — историческая.

Вторая — архитектурная.

---

## 3.1. Исторически «PostgreSQL скопировал Volcano» не сходится

В нашей предыдущей source archaeology мы дошли до POSTGRES исходников начала 1990-х.

`ExecProcNode` и split `Init / Proc / End` уже видны в исходниках POSTGRES v3r1, 1991 года.

То есть next-style executor boundary существовал **до статьи Volcano 1994**.

В современном PostgreSQL `execProcnode.c` до сих пор описывает тот же общий contract:

> initialize, get a tuple, cleanup; child nodes call the same interface on subnodes.

Современный source:
https://github.com/postgres/postgres/blob/master/src/backend/executor/execProcnode.c

Это прекрасный кусок «ДНК POSTGRES».

Не потому, что код не менялся 35 лет.

А потому, что **граница между executor nodes оказалась невероятно живучей**.

---

## 3.2. Почему эта граница была хорошей

Iterator interface очень удобен.

Каждый node умеет сказать примерно:

> Дай мне следующую tuple.

Это даёт:
- composability;
- pipelining;
- простую локальную реализацию node;
- early stop для LIMIT;
- естественную demand-driven execution.

То есть нельзя рассказывать её как древнюю ошибку.

Она пережила десятилетия, потому что давала реальные архитектурные преимущества.

---

## 3.3. Когда цена стала заметнее

Современный CPU очень чувствителен к:
- function-call/indirection overhead;
- branch prediction;
- instruction cache locality;
- data layout;
- SIMD opportunities.

В 2016 Robert Haas вынес на hackers отдельную тему asynchronous/vectorized execution.

Он формулировал проблему очень конкретно: repeated trips through `ExecProcNode` могут мешать branch prediction и CPU cache behavior, потому что выполнение постоянно прыгает между маленькими кусками разных nodes.

Источник:
https://www.postgresql.org/message-id/CA%2BTgmobx8su_bYtAa3DgrqB%2BR7xZG6kHRj0ccMUUshKAQVftww%40mail.gmail.com

David Rowley в ответ расписал возможную batch architecture:
- batch scan API;
- batch-capable TupleTableSlot;
- batch-aware nodes;
- определить, способен ли весь plan tree жить в batch mode;
- иначе нужен de-batching boundary.

Источник:
https://www.postgresql.org/message-id/CAKJS1f_N16Chu-rEbFDVq1aw-dC%2BaOMqpb4XovuudRZ%2BPc9nYA%40mail.gmail.com

Вот здесь и находится наша главная мысль.

> **Vectorizing one scan is not the same as vectorizing execution.**

Если Scan родил batch, а следующий node тут же разложил его обратно в tuples, мы улучшили producer и потеряли выигрыш на boundary.

---

## 3.4. VOPS дал очень полезный экспериментальный ответ

В 2017 Konstantin Knizhnik сделал VOPS как extension/prototype.

Идея была радикально практической:

> Не менять PostgreSQL planner/executor/heap manager, а представить vectors как специальные SQL types и выполнять операции над ними.

На некоторых TPC-H Q1/Q6 workloads prototype показывал больше 10x improvement.

Источник:
https://www.postgresql.org/message-id/50877c0c-fb88-b601-3115-55a8c70d693e%40postgrespro.ru

Это число не надо превращать в обещание «vectorization = 10x».

Гораздо интереснее, что experiment показал:

> **Если достаточно работы удаётся перенести из per-tuple interpretation в operations over contiguous vectors, CPU cost radically changes.**

Но у подхода была и цена: специальная representation и ограничения applicability.

Позже в обсуждении прямо возник вывод, что vectorized executor особенно естественно сочетать с columnar representation.

Источник:
https://www.postgresql.org/message-id/CAFj8pRC6YcoLxG%2BRWqyTvctiUxK%3DgKaVeEth9g3BxiTWu7T%3DBA%40mail.gmail.com

То есть снова:

> representation → interface → consumer

нельзя рассматривать отдельно.

---

## 3.5. Очень полезно: тема жива прямо сейчас

В 2025–2026 Amit Langote снова работает над **batching in executor**.

Первый thread 2025 ставил цель передавать batches of tuples и уменьшать per-tuple overhead, открывая дорогу batch expression evaluation и SIMD.

Источник:
https://www.postgresql.org/message-id/CA%2BHiwqFfAY_ZFqN8wcAEMw71T9hM_kA8UtyHaZZEZtuT3UyogA%40mail.gmail.com

А к июлю 2026 design уже изменился.

Это важно для книги: после экспериментов автор patch series **отказался от более крупной RowBatch design и вернулся к меньшему incremental foundation**.

Источник:
https://www.postgresql.org/message-id/CA%2BHiwqHv1CggSbpn%3Dn%2BGU%3DCp1AqDD25%3Dhzx_PTYyqjMyZO2%2BmA%40mail.gmail.com

То есть even now community не говорит:
«вот правильный vector executor, осталось закоммитить».

Она ищет **границу изменения**, которую можно внедрять постепенно, не разрушая огромный существующий executor ecosystem.

Это прекрасная современная эволюционная сцена.

---

## 3.6. И современные цифры снова показывают: надо знать, что именно ускорили

В июле 2026 на одном из вариантов batching patch reported improvements для sequential count-like workloads были примерно:

- `count(*)` без qual: около 35–43% на all-visible data;
- меньше, когда появляется qual evaluation;
- ещё меньше, когда visibility work становится дороже.

Источник:
https://www.postgresql.org/message-id/CA%2BHiwqESTyLOPZ2s%3DTh1e-EpP7esrC%3D9uH1mBAhoPUU8CWhiGQ%40mail.gmail.com

Это замечательно ложится в нашу методологию.

Почему biggest win на простом `count(*)`?

Потому что там большая доля времени — именно тот per-tuple scan overhead, который patch уменьшает.

Когда появляется qual evaluation, patch эту часть пока не ускоряет — и относительный выигрыш уменьшается.

То есть:

> **Performance gain tells us which fraction of work we actually removed.**

Это гораздо полезнее, чем написать «batching ускоряет PostgreSQL на 40%».

---

## 3.7. Что нельзя делать в книге

Нельзя написать:

> Vectorized executor быстрее tuple-at-a-time.

Без условий эта фраза почти бессмысленна.

Надо спрашивать:

- какой node?
- какая expression work?
- row or column representation?
- где tuple deformation?
- где batch превращается обратно в rows?
- есть ли LIMIT?
- branchy ли workload?
- есть ли expensive function?
- memory-bound или instruction-bound?
- сколько consumers понимают batch?

Вот тогда начинает появляться causal model.

---

## 3.8. Эксперимент для книги: «Где исчез выигрыш batch scan»

Нам нужен собственный простой эксперимент, не огромный TPC-H.

### Phase A — scan baseline

Большая hot/frozen table.

```sql
SELECT count(*) FROM t;
```

Измеряем per-row overhead.

### Phase B — expression

```sql
SELECT count(*) FROM t WHERE cheap_expression(...);
```

Смотрим, как доля executor expression work уменьшает относительный эффект scan optimization.

### Phase C — tuple deformation

Нужен вариант, реально извлекающий несколько attributes.

### Phase D — consumer boundary

Producer умеет batch, consumer нет.

Измеряем стоимость:
- batch creation;
- de-batching;
- Slot representation conversion.

### Phase E — batch-aware consumer

Например aggregation over batch.

Только здесь появляется end-to-end vector/batch path.

Главная картинка:

```text
batch scan ──► row consumer
   win          boundary tax

batch scan ──► batch consumer
              end-to-end win
```

---

## 3.9. Invariant для performance architecture

Не operational invariant вроде WAL.

Скорее engineering rule:

> **An optimization is real only across the boundary that consumes its output.**

И второй:

> **Before changing an old abstraction, identify both the cost it imposes today and the useful semantics it still provides.**

Это очень «прояснение PostgreSQL».

---

# 4. Что неожиданно объединяет FTS, extensions и executor

Теперь самое интересное.

Сначала эти три темы выглядели случайной тройкой.

Но они все про одно:

> **Где провести границу так, чтобы не потерять важную семантику?**

---

## FTS

Граница:

```text
transactional truth | derived search
```

Если пересекли — получили freshness/reconciliation contract.

---

## Extension

Граница:

```text
PostgreSQL core | new data semantics
```

Если extension boundary достаточно богатая — не нужен fork и, возможно, не нужен внешний service.

---

## Executor

Граница:

```text
producer node | consumer node
```

Если representation не переживает границу — локальная optimization исчезает.

---

В трёх случаях плохой engineering question звучит:

> «Что быстрее/проще сделать локально?»

Хороший:

> **Что должно пройти через границу, и какую семантику/стоимость мы там теряем?**

Мне кажется, это ещё один leitmotif книги рядом с debt.

---

# 5. Как это должно звучать в книге

Не так:

> PostgreSQL full-text search was integrated into core in version 8.3.

А примерно так:

> Вам нужен поиск. Самый естественный современный ответ — поставить отдельный search engine. Иногда это действительно правильный ответ. Но сначала сделаем одну неприятную вещь: остановим consumer, который переносит изменения из PostgreSQL в индекс, на тридцать секунд. Теперь изменим текст документа и запретим пользователю к нему доступ. Что должен показать поиск?  
>
> Вот теперь у нас есть правильный вопрос. Не «кто быстрее ищет», а «где проходит граница истины».

---

Не так:

> PostgreSQL supports user-defined types and operator classes.

А:

> Допустим, нам нужна непальская дата. Можно хранить её строкой и следующие десять лет объяснять каждому приложению, как сравнивать две такие строки. А можно один раз научить PostgreSQL, что это за объект. После этого `ORDER BY`, range conditions и B-tree перестают быть нашими специальными случаями.

---

Не так:

> Tuple-at-a-time execution incurs function-call overhead.

А:

> Мы сделали Seq Scan на 30% быстрее. Отлично. Следующий node взял наш красивый batch и снова стал доставать из него строки по одной. Что именно мы тогда ускорили?  
>
> Вот здесь начинается настоящий разговор про vectorization PostgreSQL.

---

# 6. Следующий пакет

Теперь логично идти туда, где граница выходит **из PostgreSQL в реальный operating day**:

1. **logging / observability as workload** — включая нашу реальную аварию;
2. **warm-up after restart/failover** — что значит «база готова»;
3. **replication lag as debt** — generation/service/replay;
4. **truth → ETL/search/warehouse** — balances и reconciliation;
5. **OLTP + OLAP ≠ HTAP** — interference and freshness.

После него у нас уже будет почти весь язык книги:
- debt;
- boundary;
- placement of work;
- truth;
- evolution.


\newpage

# Работающий PostgreSQL
## Археология 03: логи, прогрев и репликация

Эти три темы удобно поставить рядом, потому что на первый взгляд они кажутся второстепенными. Логи — обслуживающая инфраструктура. Прогрев — неприятные первые минуты после рестарта. Репликация — где-то рядом живёт копия базы.

Но в работающей системе именно такие «второстепенные» механизмы очень быстро становятся главными. Они создают очереди, они имеют конечную пропускную способность, и они умеют портить foreground гораздо сильнее, чем отдельный медленный SQL.

---

# 1. Логи: наблюдение тоже создаёт нагрузку

Начнём с очень практичного вопроса.

> Сколько надо логировать?

Обычный ответ бесполезен: «достаточно для диагностики, но не слишком много».

Хорошо. А как понять, где находится это «слишком много»?

У меня был production-случай, когда включение prepared transactions в одном сервисе закончилось не тем, чего мы опасались. Мы думали про двухфазный commit, про зависшие prepared transactions, про locks. А упали на логах. Изменение поведения приложения резко увеличило поток сообщений; машина, которая должна была перевозить логи дальше, перестала справляться. Очередь стала расти, и в какой-то момент уже сама observability pipeline стала частью аварии.

Это хороший пример именно потому, что он ломает привычную картинку:

```text
application
    ↓
PostgreSQL
    ↓
logs   ← «это же просто диагностика»
```

На самом деле:

```text
log event generation
        ↓
formatting / serialization
        ↓
backend → logging collector / stderr
        ↓
local filesystem
        ↓
shipper
        ↓
network
        ↓
remote collector
        ↓
storage / indexing / retention
```

На каждом шаге есть finite service rate.

Если PostgreSQL генерирует 200 MB/s логов, а следующий этап устойчиво вывозит 120 MB/s, проблема уже произошла. То, что диск пока ещё не заполнен, означает только, что у нас есть время до её проявления.

## 1.1. Долг логирования

Для логов работает та же простая модель:

```text
log debt += generation rate - transport/service rate
```

Пока service rate выше generation rate, bursts допустимы.

Но важен второй вопрос: **за сколько мы их догоняем?**

Если ночной batch на десять минут создаёт 100 GB логов сверх обычной нагрузки, а spare capacity pipeline всего 20 MB/s, этот burst будет погашаться почти полтора часа. Следующий burst может прийти раньше.

И тогда проблема не в количестве логов за день. Проблема в том, что очередь не возвращается к baseline.

## 1.2. PostgreSQL сам постепенно признавал эту цену

История observability в PostgreSQL интересна не количеством views, а направлением.

Сначала главным способом понять, что произошло, были логи.

Потом появились всё более удобные runtime statistics.

В PostgreSQL 12 появился `log_transaction_sample_rate`: можно логировать полные transactions не для каждого запроса, а выборочно. В той же версии progress reporting появился для `CREATE INDEX`, `REINDEX`, `CLUSTER`, `VACUUM FULL`. Это важный сдвиг: вместо «пиши больше текста в лог, чтобы потом догадаться» система начинает показывать состояние операции напрямую.

Release notes PG12:
https://www.postgresql.org/docs/12/release-12.html

В PG15 статистика переехала из отдельного collector process в shared memory, появился `jsonlog`, а checkpoints и очень долгие autovacuum стали логироваться по умолчанию. И release notes сразу предупреждают: даже idle server теперь производит log output, что может создать проблемы на resource-constrained systems без нормальной rotation.

Release notes PG15:
https://www.postgresql.org/docs/release/15.0/

Это почти готовая фраза для нашей книги:

> **Наблюдаемость не бесплатна. PostgreSQL сам постепенно заменяет часть текстовой диагностики на структурированное состояние, потому что причинность лучше хранить как состояние, а не как лавину строк.**

К PG16 появляется `pg_stat_io`, в PG18 — per-backend I/O/WAL statistics. В текущей разработке даже обсуждают отдельные wait events для ситуации, когда backend реально стоит на записи в syslogger pipe или stderr: без них зависший на логировании backend может выглядеть как будто он «на CPU».

Современная hackers discussion:
https://www.postgresql.org/message-id/CACLU5mSNZEbLrwRLf_rsG1Y1D%2BJWnWKwvzwhpG73rjLjD3R1yA%40mail.gmail.com

И это не теоретическая угроза. Есть старые инциденты, где после смерти syslogger pipe заполнялся, postmaster блокировался на попытке написать сообщение, а новые подключения начинали висеть.

Пример:
https://www.postgresql.org/message-id/CACukRjOaR2_DY2tLzPe-ZJUActf8RcZ%3Dr1HimQxFgYBy%2B%2BaR8Q%40mail.gmail.com

## 1.3. Как я бы учил логам практика

Не с таблицы `log_*` GUC.

Сначала поставить эксперимент.

Берём workload с фиксированным arrival rate. Делаем три режима:

1. почти нет statement logging;
2. sampled logging;
3. намеренно много больших log messages.

Меряем одновременно:

- p50/p95/p99 foreground;
- log bytes/s;
- local log write rate;
- shipper backlog;
- CPU formatter/collector;
- disk queue;
- time to drain after burst.

А потом задаём вопрос:

> Где именно выросла очередь?

Это намного полезнее совета «не ставьте `log_statement = all` в production».

## 1.4. Invariant

> **Observability pipeline должна иметь достаточную устойчивую пропускную способность и bounded recovery time после разрешённого burst.**

И ещё:

> **Во время incident мы должны уметь временно повысить детализацию наблюдения, не превращая диагностику во вторую аварию.**

Отсюда естественно следуют sampling, dynamic logging, retention, structured logs и capacity planning для collector-а.

---

# 2. PostgreSQL запущен. Но готов ли он работать?

После рестарта есть очень соблазнительная метрика:

```text
pg_isready = accepting connections
```

С технической точки зрения база поднялась.

С точки зрения бизнеса это может быть неправдой.

Представим систему, где рабочий набор — 300 GB. Машина перезапустилась. PostgreSQL открывает порт через минуту. Клиенты сразу возвращаются с обычным production arrival rate.

Но вчера горячие 300 GB жили в RAM. Сегодня всё начинается почти с нуля.

Что происходит первые двадцать минут?

Не «PostgreSQL медленный после рестарта». Происходит **переход между состояниями системы**.

## 2.1. У базы несколько температур

Мы слишком часто говорим «cache» как об одной вещи.

На самом деле надо развести хотя бы:

- storage/device caches;
- OS page cache;
- PostgreSQL `shared_buffers`;
- backend-local state;
- prepared/plan/application caches;
- connection pool;
- JIT-compiled paths там, где они используются;
- реальные рабочие pages, которые workload ещё только начинает обнаруживать.

Поэтому эксперимент «первый SELECT медленный, второй быстрый» мало что говорит о production warm-up.

Первый SELECT мог прогреть десять pages. Рабочий день требует миллионы.

## 2.2. PostgreSQL давно знает, что cache state имеет историю

PG8.3 изменил поведение large sequential scans, чтобы они меньше выбрасывали часто используемые pages, и добавил synchronized scans: concurrent scans могут использовать уже идущую последовательность чтения, а не каждый начинать свою полностью независимую I/O работу.

Release notes:
https://www.postgresql.org/docs/8.3/release-8-3.html

В PG9.4 появился `pg_prewarm`. Тогда его прямо представляли как средство быстрее вернуть database cache к рабочему состоянию после restart.

Press kit PG9.4:
https://www.postgresql.org/about/press/presskit94/

Современный `pg_prewarm` умеет загружать relation либо через OS cache, либо прямо в PostgreSQL buffer cache. Autoprewarm периодически сохраняет список содержимого shared buffers и после restart двумя background workers загружает эти blocks обратно.

Документация:
https://www.postgresql.org/docs/current/pgprewarm.html

Но документация там же предупреждает о важной вещи: prewarming itself может вытеснить другие данные. Если прогреть больше, чем помещается в cache, мы просто начнём выбрасывать начало прогрева концом прогрева.

То есть «прогреть всё» — такой же плохой рецепт, как «поставить shared_buffers побольше».

## 2.3. Warm-up — это ещё один долг

После cold restart можно определить:

```text
warm-up debt = working state, который production ожидает,
              но система ещё не восстановила
```

Новый workload постепенно погашает этот долг, читая нужные pages.

Но если arrival rate сразу близок к normal capacity, возникает неприятная обратная связь:

```text
cold cache
   ↓
service capacity ↓
   ↓
request backlog ↑
   ↓
more concurrent reads
   ↓
storage pressure ↑
   ↓
tails ↑
```

То есть возвращение полного traffic сразу после «порт открылся» может само удлинить warm-up.

## 2.4. Что значит правильный RTO

Обычный RTO:

> сервер снова принимает соединения через 90 секунд.

Production RTO:

> через сколько система снова выдерживает обещанный arrival rate и tail SLA?

Это разные времена.

Для failover особенно важно. Новый primary может быть совершенно корректным и всё равно иметь другой cache state. Если routing мгновенно вывалил на него весь production, можно получить второй incident уже после успешного failover.

## 2.5. Эксперимент: четыре старта

Нужна одна и та же база и один workload.

**A. Cold machine.**

OS и PostgreSQL caches холодные.

**B. Warm OS, cold PostgreSQL.**

Например, data already in page cache, но shared buffers freshly initialized.

**C. `pg_prewarm`/autoprewarm.**

Прогреваем выбранный hot set.

**D. Real traffic ramp.**

Вместо immediate 100% arrival rate поднимаем трафик ступенями.

Меряем:

- p50/p99;
- I/O bytes/s;
- buffer hits/reads;
- backlog;
- время до stable SLA;
- какую часть working set реально стоило греть.

## 2.6. Invariant

> **После restart/failover система должна возвращаться в service envelope за ограниченное, измеренное время.**

А значит, readiness — это не boolean. Это trajectory.

---

# 3. Replica lag: число без производной почти бесполезно

Один из самых частых экранов мониторинга:

```text
replica lag: 400 GB
```

И начинается паника.

Но давайте сравним две системы.

**Система A:** lag 400 GB и каждую минуту уменьшается на 20 GB.

**Система B:** lag 5 GB и каждую минуту растёт ещё на 500 MB.

Какая из них здоровее?

Почти всегда A.

Потому что lag — это не состояние само по себе. Это **очередь**.

## 3.1. Разложим репликацию на service chain

У physical replication есть несколько разных точек:

```text
primary generates WAL
        ↓
WAL sender
        ↓ network
WAL receiver
        ↓
write
        ↓
flush
        ↓
replay
        ↓
visible state on standby
```

Если standby отстаёт, нам надо понять **на каком переходе service rate ниже generation rate**.

В PostgreSQL 9.0 streaming replication появилась именно потому, что file-based shipping целыми WAL segments давал слишком грубую задержку: раньше standby мог ждать заполнения очередного 16 MB segment. Streaming стал передавать WAL records по мере генерации.

Release notes PG9.0:
https://www.postgresql.org/docs/9.0/release-9-0.html

Документация PG9.0 прямо отмечала: replication остаётся asynchronous, небольшая задержка всё ещё есть, но при достаточной мощности standby она обычно намного меньше старого file shipping.

https://www.postgresql.org/docs/9.0/warm-standby.html

Вот важная часть: **«если standby достаточно мощный, чтобы успевать»**.

Вся наша модель уже спрятана в этой фразе.

## 3.2. Synchronous replication не уничтожает долг, а меняет контракт

PG9.1 добавляет synchronous replication: primary может не подтверждать commit, пока standby не запишет WAL на диск.

Release notes:
https://www.postgresql.org/docs/9.1/release-9-1.html

Это очень легко продать как «нулевой RPO» и забыть вторую половину.

Теперь network/standby latency вошли в transaction critical path.

Текущая документация прямо предупреждает: synchronous replication увеличивает response time, а locks транзакции продолжают удерживаться во время ожидания подтверждения. Значит, можно получить не только медленный COMMIT, но и вторичный lock contention.

PG19 docs:
https://www.postgresql.org/docs/19/warm-standby.html

То есть trade-off выглядит честно:

```text
async:
commit latency ниже
possible acknowledged-state gap exists

sync:
stronger durability contract
network/standby enters foreground latency
```

Нет «правильного» режима без business semantics.

## 3.3. Read-your-writes — отдельная задача

Очень хороший практический инцидент:

1. пользователь меняет профиль на primary;
2. application отправляет следующий read на replica;
3. видит старое имя.

Данные не потеряны. Реплика не сломана. Это нормальная async semantics.

До PG19 приложению приходилось решать это более внешними способами: sticky reads, routing, own LSN waiting logic.

PG19 добавляет `WAIT FOR LSN`. Приложение может сохранить LSN после своей записи и на standby дождаться именно replay до этого LSN.

Документация:
https://www.postgresql.org/docs/19/sql-wait-for.html

Особенно полезно, что `WAIT FOR` различает несколько meaning:

- `standby_replay` — изменение уже применено и будет видно reads;
- `standby_write` — WAL записан в OS buffers;
- `standby_flush` — WAL durable на standby;
- `primary_flush` — WAL flushed на primary.

Это отличный материал для книги, потому что одна команда заставляет практика развести три часто смешиваемых понятия:

> WAL приехал. WAL надёжно записан. Изменение уже видно SQL.

Это не одно и то же.

PG19 пока Beta 3; перед печатью эту часть надо проверить по GA docs.

## 3.4. Реплика для OLAP может вернуть долг обратно на primary

Кажется логичным: тяжёлые аналитические SELECT вынесем на standby и спасём primary.

Но PostgreSQL снова показывает, что boundary не бесплатна.

Длинный query на standby может конфликтовать с WAL replay, когда primary уже vacuum-ит версии, которые query всё ещё хочет видеть.

Есть два типичных ответа:

- отменять standby query;
- включить `hot_standby_feedback`, чтобы primary не удалял нужные версии.

Но документация прямо предупреждает: `hot_standby_feedback` может вызвать bloat на primary.

PG19 docs:
https://www.postgresql.org/docs/19/runtime-config-replication.html

Вот замечательная причинная цепочка:

```text
«уберём OLAP с primary»
        ↓
long snapshot on standby
        ↓
feedback to primary
        ↓
primary postpones cleanup
        ↓
MVCC debt grows on primary
```

Мы разгрузили CPU/I/O primary и одновременно вернули туда vacuum debt через semantic boundary.

Это идеальный пример для главы про HTAP позже.

## 3.5. Slots: гарантия доставки превращается в disk debt

Replication slot решает важную проблему: primary знает, какой WAL ещё нужен consumer-у, и не удаляет его раньше времени.

Это сильная гарантия.

Но гарантия формулируется так:

> Если consumer не забрал данные, PostgreSQL сохранит их для него.

А если consumer умер на неделю?

Тогда очередь физически остаётся на primary.

Современная документация прямо говорит, что slot удерживает WAL, пока он нужен standby/subscriber.

https://www.postgresql.org/docs/19/warm-standby.html

И снова мы приходим к одной модели:

```text
consumer safety
      ↕
retention debt
```

Нельзя мониторить только `restart_lsn`/размер lag. Нужен time-to-disk-exhaustion при текущей derivative.

## 3.6. Эксперимент: отстаём и догоняем

Берём primary + standby.

1. Стабильный write workload.
2. Ограничиваем replay/standby resources так, чтобы `G > R`.
3. Наблюдаем рост lag.
4. Возвращаем resources так, чтобы `R > G`.
5. Измеряем catch-up.

Где:

```text
G = WAL generation rate
R = replay/service rate
L = accumulated lag

dL/dt = G - R
```

Потом повторяем с:

- long standby analytical query;
- `hot_standby_feedback` off/on;
- replica read immediately after primary write;
- `WAIT FOR LSN` в PG19.

## 3.7. Invariants

Для standby, которая должна оставаться актуальной:

> **На устойчивом workload replay capacity должна быть выше generation rate с достаточным запасом для catch-up после bursts.**

Для application reads:

> **Каждый путь чтения с replica имеет явный consistency contract: stale acceptable, bounded stale или read-your-writes.**

Для slot:

> **Ни один consumer не может бесконечно удерживать disk/WAL без alert и bounded retention policy.**

---

# 4. Что объединяет логи, warm-up и replication

Во всех трёх случаях ошибка одна и та же: мы смотрим на **состояние**, а надо смотреть на **движение**.

Логов 50 GB backlog — плохо или нормально? Зависит от того, догоняем ли мы.

Replica отстаёт на 400 GB — плохо или нормально? Зависит от replay rate.

После restart p99 = 200 ms — плохо или нормально? Зависит от warm-up trajectory и promised RTO.

Поэтому книга должна постоянно заставлять читателя задавать второй вопрос:

> **Куда движется система и с какой скоростью?**

Это и есть практический смысл наших debt/invariant ideas.



\newpage

# Работающий PostgreSQL
## Археология 04: где живёт истина, ETL как очередь и почему OLTP + OLAP ещё не HTAP

Есть один вопрос, который в обычной книге про PostgreSQL почти не задают:

> **Если две системы показывают разные данные — кто прав?**

А в production это один из самых дорогих вопросов.

Представим банк или просто систему расчётов.

В PostgreSQL баланс клиента — 1000.

В warehouse — 980.

В cache приложения — 1020.

В поисковом индексе документ ещё говорит про старый лимит.

Все четыре системы работают. Ничего не «упало». И всё-таки система уже находится в состоянии, которое надо уметь объяснить.

С этого я бы начинал разговор про OLTP, OLAP, ETL, CDC и HTAP. Не с таблицы «OLTP: короткие queries, OLAP: длинные queries».

---

# 1. Истина — это архитектурное решение

PostgreSQL не обязан выполнять каждую работу вашей компании.

Никто не требует строить весь BI, full-text ranking, ML feature computation и web cache внутри одного backend.

Но реальная система должна знать:

> **Где находится authoritative state, из которого остальные состояния могут быть объяснены или восстановлены?**

Для огромного класса систем таким местом естественно становится PostgreSQL, потому что именно здесь живёт transactional boundary.

Это не маркетинговая фраза «single source of truth». В ней слишком легко потерять смысл.

Нас интересует более конкретное свойство:

> Если бизнес-событие произошло, где существует запись, которую мы считаем окончательным фактом этого события?

Например, баланс — это не число `1000`.

За ним может стоять история:

```text
+500 payment
-100 purchase
+700 transfer
-100 reversal
```

И ещё:
- timestamps/effective dates;
- currencies;
- reversals;
- corrections;
- transaction boundaries;
- business rules.

Если warehouse содержит только итоговое `1000`, а PostgreSQL содержит события и правила, то warehouse не становится более истинным от того, что SELECT там быстрее.

---

# 2. Derived state — это нормально

Очень важная оговорка.

Если сказать «PostgreSQL — место истины», легко превратить это в религию:

> тогда всё хранить только в PostgreSQL, никаких caches, search engines и warehouses.

Это неправильно.

Derived state нужен постоянно:

- index — тоже derived representation;
- materialized view;
- replica;
- application cache;
- external search index;
- data warehouse;
- feature store;
- precomputed balance;
- report table.

Вопрос не в том, можно ли иметь копию.

Вопрос:

> **Каков контракт этой копии с истиной?**

Для каждой derived system мы хотим знать хотя бы четыре вещи:

1. **Authority.** Из чего её можно восстановить?
2. **Freshness.** Насколько она может отставать?
3. **Consistency.** Какие отношения между объектами она обязана сохранять?
4. **Rebuildability.** Что делать, если мы ей больше не доверяем?

Если на четвёртый вопрос ответ «ну, надеемся, что Kafka всё сохранила», это уже не просто cache.

---

# 3. Materialized view: PostgreSQL сам учит нас цене derived state

Materialized view — прекрасный маленький пример, потому что вся архитектура видна внутри одной базы.

Мы берём query result и физически сохраняем его.

Зачем?

Потому что вычислять каждый раз дорого.

За что платим?

За freshness.

В PostgreSQL 9.3 materialized views появились как явный объект. В 9.4 стало можно делать `REFRESH MATERIALIZED VIEW CONCURRENTLY`, чтобы refresh не блокировал обычные reads, хотя это имеет дополнительные требования и стоимость.

Документация PG9.4:
https://www.postgresql.org/docs/9.4/sql-refreshmaterializedview.html

Даже этот крошечный механизм уже содержит всю будущую тему ETL:

```text
truth
  ↓ compute
materialized copy
  ↓
refresh lag
```

И сразу вопрос:

> Нас устраивает, что копия обновляется раз в пять минут?

Если да — отлично. Это не «плохая consistency». Это выбранный contract.

---

# 4. Logical decoding: WAL становится дорогой к истине

PostgreSQL 9.4 добавил logical decoding.

До этого WAL в первую очередь воспринимался как physical recovery/replication mechanism.

Logical decoding делает важный концептуальный поворот:

> Из потока физических изменений можно получить coherent stream logical changes, который понимает внешняя система.

Документация PG9.4:
https://www.postgresql.org/docs/9.4/logicaldecoding-explanation.html

Release notes:
https://www.postgresql.org/docs/9.4/release-9-4.html

Это очень сильная граница.

Вместо:

```text
periodically SELECT changed rows
```

мы можем строить:

```text
PostgreSQL transaction
        ↓ WAL
logical decoding
        ↓
consumer
        ↓
search / warehouse / another database
```

Но вместе с дорогой наружу появляется debt.

Consumer отстал — PostgreSQL должен помнить changes, которые он ещё не получил.

Replication slot как раз даёт такую гарантию.

И опять то же свойство PostgreSQL работает в обе стороны:

> **Мы получаем надёжность consumer-а, потому что primary соглашается удерживать историю для него.**

Если consumer исчез навсегда, гарантия превращается в unbounded WAL retention.

Отсюда derived systems нельзя обсуждать отдельно от operational capacity primary.

---

# 5. ETL — не стрелка между двумя прямоугольниками

На слайде ETL обычно выглядит красиво:

```text
PostgreSQL → Warehouse
```

В работающей системе там длинная цепочка:

```text
transaction commits
       ↓
change becomes extractable
       ↓
extractor / decoder
       ↓
queue / network
       ↓
transform
       ↓
load
       ↓
warehouse indexes/materializations
       ↓
report becomes visible
```

Каждый этап имеет throughput.

Поэтому ETL lag — такая же очередь, как replica lag.

Обозначим:

```text
E = rate of new extractable business changes
L = rate at which warehouse makes them usable
D = ETL debt

dD/dt = E - L
```

Если ночной поток вырос в три раза, а ETL всё ещё догоняет к 6 утра — возможно, всё нормально.

Если обычный дневной поток на 2% выше устойчивой capacity pipeline — через неделю у нас огромная проблема, хотя каждый dashboard показывает «lag пока всего 20 минут».

## 5.1. Почему time lag иногда обманывает

Допустим, ETL отстал на час.

Что это означает?

В спокойный час — 10 тысяч transactions.

В Black Friday — 50 миллионов.

Поэтому надо смотреть не только wall-clock lag, но и **объём незавершённой работы** и service rate.

Точно как с replication.

---

# 6. Баланс — хороший экзамен на architecture

Давайте усложним пример.

У нас есть financial balance.

Можно хранить его как текущее число в PostgreSQL. Можно вычислять из ledger. Можно копировать в warehouse. Можно кешировать в Redis.

Что должен видеть клиент сразу после платежа?

Вот тут архитектура перестаёт быть технической абстракцией.

Если баланс на экране обязан отражать committed transaction немедленно, то читать его из warehouse с five-minute ETL lag — не performance optimization. Это изменение business semantics.

Если monthly financial report строится через час после closing — наоборот, warehouse lag в пять минут вообще не проблема.

Значит, слово «freshness» само по себе ничего не говорит.

Нужен **business freshness contract**.

Я бы заставил читателя прямо заполнить таблицу:

| Derived state | Authority | Freshness | Rebuild | Можно использовать для денег? |
|---|---|---|---|---|
| primary PostgreSQL | ledger/transactions | committed state | backup/PITR | да, по контракту |
| physical replica | primary WAL | replication lag | recreate | зависит от read contract |
| warehouse | PostgreSQL/CDC | ETL lag | reload | для отчётов, не обязательно для current balance |
| cache | PostgreSQL | TTL/invalidation | discard | только если stale допустим |
| search | PostgreSQL | indexing lag | reindex | не источник transactional truth |

Не потому, что эта таблица универсальна. А потому, что без неё разные команды часто используют слово «данные» для сущностей с разными гарантиями.

---

# 7. OLTP и OLAP хотят от машины разного

Теперь можно наконец поговорить про OLTP и OLAP.

OLTP обычно хочет:

- короткие transactions;
- bounded tail latency;
- predictable lock duration;
- high concurrency;
- небольшой per-query working set;
- быстрый visibility of committed changes.

OLAP часто хочет:

- прочитать много данных;
- parallelism;
- большие hash/sort/aggregate structures;
- memory bandwidth;
- длительный snapshot;
- throughput важнее latency одного query.

Это уже конфликт ресурсов.

Но ещё хуже — конфликт времени.

OLTP хочет:

> освободить старые tuple versions как можно скорее.

Длинный analytical snapshot говорит:

> не трогайте историю, я ещё читаю.

И suddenly analytics, которое «почти не пишет», создаёт vacuum debt.

---

# 8. Почему OLTP + OLAP не равно HTAP

Представим самый простой эксперимент.

На PostgreSQL идёт стабильный OLTP workload.

Всё хорошо.

Запускаем тяжёлый parallel analytical query.

Теперь могут измениться:

- CPU scheduling;
- memory bandwidth;
- cache residency;
- I/O queue;
- number of available parallel workers;
- `work_mem` consumption;
- snapshot horizon;
- vacuum effectiveness;
- p99 OLTP.

Система умеет исполнять и UPDATE, и большой GROUP BY. Но это ещё не означает, что она стала хорошей HTAP system.

HTAP начинается там, где мы умеем ответить:

> **Какие ресурсы аналитика может забрать, какой freshness ей нужен и какой ущерб OLTP считается недопустимым?**

Это не сумма feature sets. Это управление interference.

---

# 9. Parallel query особенно хорошо показывает проблему

Современный PostgreSQL может дать одному query несколько parallel workers.

Это отлично для analytical throughput.

Но документация прямо напоминает: каждый worker — отдельный process с реальным CPU/memory/I/O impact; `work_mem` применяется к workers отдельно, поэтому parallel query способен использовать во много раз больше ресурсов, чем кажется по одному GUC.

PG19 resource docs:
https://www.postgresql.org/docs/19/runtime-config-resource.html

Это очень хороший практический урок.

Люди часто рассуждают:

> `work_mem = 256 MB`, значит query не съест больше 256 MB.

Нет.

Один query может иметь несколько memory-consuming plan operations. Несколько workers умножают часть потребления. Несколько concurrent analytical queries умножают ещё раз.

Поэтому HTAP нельзя свести к `SET work_mem`.

---

# 10. Большой scan: PostgreSQL давно пытается быть хорошим соседом

В PG8.3 большой sequential scan перестал вести себя как обычный набор случайных buffer accesses: bulk-read strategy должна меньше разрушать useful shared-buffer working set; synchronized scans позволяют нескольким большим scans делить часть физической работы.

Это было раннее признание простой проблемы:

> **Аналитический scan способен сделать плохо совершенно другим queries, если обращаться с ним как с обычным OLTP access pattern.**

Современные AIO/streaming-I/O изменения продолжают ту же линию, но фундаментальный вопрос остаётся:

> Сколько large-scan work можно впустить рядом с latency-sensitive transactions?

---

# 11. Вынести OLAP на replica? Иногда это правильный ответ. Но снова появляется boundary

Replica кажется идеальной:

```text
primary = OLTP
standby = OLAP
```

CPU и I/O разделены.

Но consistency и MVCC остаются связанными через WAL.

Длинный standby query может мешать replay cleanup. Если разрешаем replay победить — query отменяется.

Если включаем `hot_standby_feedback`, primary может дольше сохранять dead tuples, чтобы standby query продолжал видеть нужную историю.

Документация PG19 прямо предупреждает о возможном bloat на primary:
https://www.postgresql.org/docs/19/runtime-config-replication.html

Получается замечательная ситуация:

> **Физически мы вынесли аналитический workload на другую машину. Семантически его snapshot всё ещё способен создать debt на primary.**

Вот почему HTAP нельзя обсуждать только железом.

---

# 12. Другой вариант: derived analytical state

Можно пойти дальше и отделить analytics уже не physical replica, а logical/ETL copy.

Плюс:
- другой physical design;
- columnar/warehouse engine;
- independent vacuum/storage behavior;
- сильная resource isolation.

Минус:
- freshness lag;
- duplicate/retry/order semantics;
- reconciliation;
- separate backup/security concerns.

И снова главный вопрос не «быстрее ли ClickHouse/DuckDB/warehouse на aggregation».

Главный вопрос:

> **Какая freshness и consistency реально нужны этому analytical result?**

Если отчёт строится на вчерашнем closing state — external analytical engine может быть почти идеальным.

Если analyst расследует transaction, которую клиент совершил пять секунд назад, граница уже заметнее.

---

# 13. Как PostgreSQL эволюционировал вокруг этой границы

Если посмотреть release notes, видно постепенное появление разных способов обращаться с analytical/derived state:

**PG9.3 — materialized views.**

Сохраняем result внутри database, принимаем refresh semantics.

**PG9.4 — logical decoding + concurrent materialized refresh.**

Можно выводить changes наружу и обновлять materialization мягче.

**PG9.5 — BRIN.**

Очень большие physically correlated datasets получают индекс, который не пытается иметь entry на каждую tuple.

**PG9.6 — parallel query.**

Один analytical query получает больше CPU.

**PG10 — declarative partitioning + logical replication.**

Управление большими datasets и selective derived copies становится частью core.

**PG16 — logical decoding на standby и parallel apply improvements.**

CDC topology становится гибче.

**PG17 — logical slot failover support.**

Derived change stream становится частью HA state, который надо переживать при failover.

**PG19 beta — sequence replication и возможность активировать logical decoding при `wal_level=replica` через logical slots без обычного restart-path изменения `wal_level`.**

PG19 logical decoding docs:
https://www.postgresql.org/docs/19/logicaldecoding-explanation.html

Эволюция говорит сама за себя:

> PostgreSQL не пытается заставить каждую задачу выполняться только на primary. Он всё лучше управляет **границами между authoritative state и его производными представлениями**.

---

# 14. Эксперимент: построим плохой HTAP за пять минут

Это должно быть одной из самых весёлых демонстраций книги.

### Baseline

OLTP workload при arrival rate, например, 70–80% устойчивой capacity.

Измеряем:
- completed tx/s;
- p50/p95/p99;
- backlog;
- WAL;
- vacuum;
- cache/I/O.

### Добавляем analytics

Один большой parallel aggregation/scan.

Смотрим:
- насколько изменился OLTP p99;
- сколько workers/memory забрал query;
- изменился ли buffer/I/O pattern;
- как долго живёт snapshot;
- что делает autovacuum.

### Потом три архитектуры

A. Analytics on primary.

B. Analytics on physical standby.

C. Analytics on delayed/logical/materialized derived state.

И сравниваем не «кто быстрее SELECT».

Сравниваем:

| Архитектура | OLTP interference | Freshness | MVCC coupling | Recovery/rebuild complexity |
|---|---:|---:|---:|---:|
| primary | high/variable | immediate | direct | low |
| physical standby | lower physical interference | replication lag | still coupled | medium |
| derived analytical copy | strongly isolated | ETL lag | mostly separated | higher |

Вот это уже разговор про HTAP.

---

# 15. Invariants truth/derived state

Я бы оставил несколько простых правил, которые читатель сможет потом проверять в любой системе.

### Authority

> **Для каждого бизнес-факта известно, какая система является authoritative.**

### Rebuildability

> **Derived state можно уничтожить и восстановить из authority либо существует явная причина, почему это уже не derived state.**

### Freshness

> **Для каждого consumer определён допустимый lag в терминах бизнеса, а не просто “желательно realtime”.**

### Pipeline capacity

> **CDC/ETL/search service rate имеет запас над sustainable change rate и способен погашать backlog после допустимых bursts.**

### HTAP

> **Analytical workload не нарушает transactional SLA и maintenance invariants; его resource/freshness contract известен.**

---

# 16. Самая важная мысль этой части

PostgreSQL должен быть **местом истины** не в смысле «тащите в него вообще всё».

Смысл намного практичнее:

> **Когда система распадается на PostgreSQL, replicas, caches, search и warehouse, мы должны уметь провести стрелки назад и понять, где заканчивается производное состояние и начинается состояние, которому мы доверяем как факту.**

Если этого нельзя сделать, проблема архитектуры уже существует, даже если все dashboards зелёные.



\newpage

# Работающий PostgreSQL
## Археология 05: superuser, изменения на живой базе, backup и failover

В этой части четыре темы, которые обычно живут в разных главах DBA-курса:

- security;
- DDL/maintenance;
- backup;
- HA/failover.

Но у них есть общий вопрос:

> **Как изменить состояние работающей системы, не потеряв контроль над тем, кто имеет право это сделать, что именно изменилось и можно ли вернуться назад?**

---

# 1. Кто такой postgres и почему ему можно всё?

Начнём с путаницы, которая живёт даже у опытных людей.

Есть OS user `postgres` — account, от имени которого обычно работает server process и которому принадлежат files кластера.

И есть database role `postgres`, которую `initdb` часто создаёт как bootstrap superuser.

Это две разные границы безопасности.

Если человек говорит:

> «postgres имеет доступ ко всему»,

надо сначала спросить: **какой именно postgres?**

Но в обоих случаях доверие действительно очень широкое.

Database superuser обходит почти все database permission checks. OS account, который может читать/менять data directory и запускать server binaries, находится ещё ниже database permission model.

Поэтому production model «все административные скрипты подключаются как postgres» удобна ровно до первой ошибки credentials, script bug или compromise.

---

# 2. История PostgreSQL постепенно дробит всемогущество на capabilities

Если посмотреть release evolution, видно довольно ясное направление.

Раньше было проще сказать:

> эту операцию может только superuser.

Потом появляются более узкие права.

PG8.1 объединяет users/groups в roles.

PG9.0 добавляет `ALTER DEFAULT PRIVILEGES`, позволяя управлять правами будущих объектов без ручного догоняния каждого CREATE.

PG9.5 — Row Level Security.

PG10 — SCRAM-SHA-256.

PG11 создаёт отдельные роли `pg_read_server_files`, `pg_write_server_files`, `pg_execute_server_program`: capability очень опасная, но теперь её можно выдать отдельно от полного SUPERUSER.

PG15 меняет default для `public` schema: `PUBLIC` больше не получает `CREATE` автоматически в новых databases/clusters. Release notes прямо связывают это с более безопасной schema pattern.

https://www.postgresql.org/docs/release/15.0/

PG17 вводит `MAINTAIN` и `pg_maintain`, чтобы VACUUM/ANALYZE/REINDEX/CLUSTER и другие maintenance operations не требовали владельца или полного superuser для каждого operational user.

Современный PG19 список predefined roles уже хорошо показывает направление: monitoring, checkpoint, maintenance, signaling, data read/write, file access — отдельные capabilities.

https://www.postgresql.org/docs/19/predefined-roles.html

То есть эволюция security здесь очень похожа на эволюцию observability:

```text
one giant privilege
       ↓
separate capabilities
       ↓
least privilege becomes operationally possible
```

---

# 3. Postgres Pro: separation of duties как доведение идеи до конца

Здесь у нас есть собственная история компании, и её стоит рассказать именно как continuation той же линии.

Postgres Pro сделал модель separation of duties: regular operational responsibilities можно распределять между DBMS Administrator и Database Administrator, уменьшая необходимость постоянно использовать unrestricted superuser.

Документация прямо формулирует исходную проблему: superuser нужен для bootstrap и некоторых низкоуровневых задач, но его regular use создаёт security risk — от доступа к данным до опасных config changes и отказов DBMS.

https://postgrespro.com/docs/postgrespro/16/sod-separation-of-duties

Для книги важна не конкретная сертификационная схема, а вопрос:

> **Почему routine operation вообще требует capability, которая одновременно умеет читать все данные, менять configuration и bypass permissions?**

Если ответ «исторически так проще», это хороший кандидат на разделение прав.

---

# 4. Login hook: полезная сила, которая способна закрыть вам вход

В PostgreSQL 17 есть `login` event trigger.

Он срабатывает **после успешной аутентификации**. Его можно использовать для:

- logging login;
- проверки условий;
- role/session initialization;
- даже запрета дальнейшего login через exception.

Документация специально предупреждает: ошибка в таком trigger способна не дать пользователям войти, поэтому существует аварийный путь с отключением event triggers/single-user mode.

https://www.postgresql.org/docs/17/event-trigger-definition.html

Это прекрасный пример security feature для «Работающего PostgreSQL»:

> **Чем ближе policy enforcement к точке входа, тем сильнее она защищает — и тем больше blast radius ошибки в policy.**

Историю про возможность реакции именно на **неправильный** login, которую мы делали/отдавали в компании, надо перед публикацией восстановить отдельно и точно не смешивать с upstream `login` event trigger: upstream trigger работает уже после authenticated login.

Это хороший placeholder для нашей собственной археологии security contributions.

---

# 5. Эксперимент security: прожить день без superuser

Вместо страницы `GRANT`-ов я бы сделал простой эксперимент.

Есть operational team:

- monitoring;
- backup;
- routine vacuum/reindex;
- application deployment;
- replication operator;
- emergency administrator.

Сначала все используют `postgres`.

Потом последовательно убираем superuser и пытаемся дать каждой роли только необходимую capability.

И каждый раз записываем:

- что реально понадобилось;
- какой privilege пришлось добавить;
- может ли теперь эта role прочитать лишние данные;
- может ли она повысить сама себе права;
- что произойдёт при credential leak.

### Invariant

> **Routine production work не выполняется unrestricted superuser; elevated capability имеет owner, purpose и bounded use.**

---

# 6. «Надо добавить индекс». Почему это вообще опасная операция?

В development всё просто:

```sql
CREATE INDEX ...;
```

В production одна полезная команда может изменить жизнь тысяч transactions.

Почему?

Потому что DDL — это не текстовое изменение schema metadata. Оно может требовать:

- locks;
- table scan;
- index build;
- WAL;
- temporary disk;
- catalog changes;
- validation;
- waits for old transactions.

То есть правильный production-вопрос:

> **Какой physical work и какая blocking boundary стоят за одной строкой DDL?**

---

# 7. PostgreSQL много лет убирает stop-the-world, но цена не исчезает

Эта эволюция хорошо видна по release notes.

## PG8.2 — CREATE INDEX CONCURRENTLY

Обычный index build может долго блокировать writers. Concurrent build сохраняет DML, но требует более сложного lifecycle: multiple scans/waits, больше общей работы и больше времени.

https://www.postgresql.org/docs/8.2/sql-createindex.html

Вот первый общий закон:

> **CONCURRENTLY обычно не убирает стоимость. Оно меняет форму стоимости.**

Вместо большого blocking interval мы получаем:

- longer operation;
- extra scans;
- catch-up phases;
- more WAL/I/O;
- temporary state;
- короткий critical section в конце.

## PG11 — ADD COLUMN DEFAULT без полного rewrite

Раньше `ALTER TABLE ... ADD COLUMN ... DEFAULT constant` мог переписать всю большую таблицу. PG11 научился избегать этого physical rewrite для подходящих constant defaults.

https://www.postgresql.org/docs/11/release-11.html

Это великолепная production-фича именно потому, что SQL semantics почти не изменились, а physical consequence изменилась радикально.

Урок:

> **Перед DDL важно знать не только lock level, но и должен ли PostgreSQL физически потрогать каждую tuple.**

## PG12 — REINDEX CONCURRENTLY + progress

Можно перестраивать index, не закрывая writers, и при этом видеть progression операции.

https://www.postgresql.org/docs/12/release-12.html

Это две линии эволюции сразу:

```text
blocking → concurrent
invisible long operation → progress state
```

## PG19 beta — REPACK CONCURRENTLY

Вот почти идеальный материал для нашей debt model.

Обычный `REPACK` переписывает table/index files и требует `ACCESS EXCLUSIVE` lock.

`REPACK CONCURRENTLY` сначала копирует table, а DML, который происходит во время копирования, ловит через logical decoding и потом применяет к новой копии. В финале всё равно нужен `ACCESS EXCLUSIVE`, но обычно только на swap.

Документация честно предупреждает: если во время repack накопилось слишком много изменений, часть catch-up приходится делать непосредственно перед swap, и final lock может стать заметным.

https://www.postgresql.org/docs/19/sql-repack.html

Это буквально:

```text
old stop-the-world cost
        ↓
copy in background
        ↓
change backlog accumulates
        ↓
catch up
        ↓
short final stop
```

То есть online maintenance — это опять queueing problem.

PG19 пока Beta 3; перед печатью детали перепроверить.

---

# 8. Как практику думать о online change

Не спрашивать:

> Есть ли у команды `CONCURRENTLY`?

Спрашивать:

1. Какая работа идёт в фоне?
2. Как быстро foreground генерирует changes, которые надо догонять?
3. Сколько extra disk нужно одновременно для old/new representation?
4. Сколько WAL это создаёт?
5. Какой lock всё равно нужен в конце?
6. Что произойдёт, если этот lock не удастся получить час?
7. Можно ли abort/retry безопасно?
8. Что увидят replicas/CDC consumers?

### Invariant

> **Каждое production change имеет bounded blocking plan, resource budget, abort path и verification step.**

---

# 9. Backup: зелёная галочка ещё ничего не доказывает

Есть один очень опасный dashboard:

```text
Backup: SUCCESS
```

Что он на самом деле доказал?

В лучшем случае:

> программа backup закончилась без ошибки.

Он не доказал:

- что все нужные WAL доступны;
- что encryption key не потерян;
- что object storage credentials работают при disaster;
- что backup не повреждён;
- что recovery procedure никто не забыл;
- что application после restore считает данные корректными;
- что мы укладываемся в RTO.

Поэтому главный тезис должен быть простой:

> **Backup существует только после успешного restore.**

До этого у нас есть backup artefact, а не доказанная recovery capability.

---

# 10. PITR: почему backup — это история, а не snapshot-файл

PostgreSQL 8.0 приносит Point-In-Time Recovery.

Смысл глубже команды recovery target.

Base backup отвечает:

> вот физическое состояние на некотором интервале времени.

WAL archive отвечает:

> вот история изменений после него.

Вместе они позволяют восстановить состояние в выбранной точке.

Именно поэтому «мы каждую ночь копируем data directory» и «у нас есть PITR» — не одно и то же.

Эта линия потом усложняется:

- standby/base backup;
- progress reporting;
- checksums;
- WAL archiving;
- PG17 incremental backup.

PG17 `pg_basebackup --incremental` использует WAL summary files с номерами изменившихся blocks; `pg_combinebackup` собирает полный backup из full + incrementals.

Release notes:
https://www.postgresql.org/docs/17/release-17.html

Это снова уменьшение **amount of repeated physical work**.

Но correctness contract не меняется: цепочку надо уметь восстановить.

---

# 11. Эксперимент backup: восстановить не последнюю, а неудобную точку

Плохой restore drill:

> восстановили latest backup на test server, PostgreSQL стартовал.

Хороший:

1. создаём business transactions T1...T5;
2. после T3 делаем ошибочный DELETE;
3. продолжаем работу T4/T5;
4. выбираем recovery target **до** DELETE;
5. восстанавливаем;
6. проверяем не только startup, но business invariants;
7. меряем реальный RTO.

Потом второй drill:

- теряем latest incremental;
- проверяем, какую point-in-time history ещё можем собрать.

### Invariant

> **Организация способна восстановить проверенное business state в обещанных RPO/RTO, а не просто хранит backup files.**

---

# 12. Replica — не backup

Это надо объяснить одним предложением.

> Вы случайно сделали `DELETE`. Replica идеально и быстро повторила `DELETE`.

Вот и всё.

Replica — механизм availability/serving/copying current history.

Backup/PITR — механизм сохранения возможности вернуться в **другую точку истории**.

Иногда delayed replica помогает как дополнительная защита, но она не отменяет backup discipline.

---

# 13. Primary умер. Почему promote — ещё не HA?

Технически standby можно promote.

Но production failover — это распределённый переход состояния.

Надо решить:

- действительно ли old primary недоступен, а не просто network-partitioned?
- кто гарантирует, что он больше не принимает writes?
- какой standby наиболее свежий?
- какие acknowledged transactions сохранились?
- куда пойдут clients?
- что станет с old primary, когда он вернётся?

PostgreSQL исторически предоставляет database mechanisms, но не решает весь control-plane consensus за вас.

Старая документация по failover прямо говорила: PostgreSQL сам не предоставляет system software, которое определяет failure primary и уведомляет standby; для этого есть внешние tools/control plane.

https://www.postgresql.org/docs/9.5/warm-standby-failover.html

Это важная граница:

> **PostgreSQL знает, как быть primary или standby. Но решение “кто сейчас имеет право быть единственным writable authority” — уже задача HA system.**

---

# 14. pg_rewind: история после failover разошлась физически

После promotion старый primary нельзя просто включить обратно как будто ничего не произошло.

У него уже другая timeline/history.

PG9.5 добавил `pg_rewind`, который находит divergence point и переносит изменившиеся blocks/files, чтобы старый primary можно было быстрее превратить в standby нового primary, не делая полный base backup.

https://www.postgresql.org/docs/9.5/app-pgrewind.html

Современная документация формулирует тот же сценарий: две copies одного cluster разошлись после failover; `pg_rewind` синхронизирует target с новой authoritative history.

https://www.postgresql.org/docs/current/app-pgrewind.html

Это прекрасная визуальная история:

```text
           / old primary continues old timeline
common ---+
           \ promoted standby becomes new truth
```

Failover создаёт не просто «смену IP». Он выбирает, **какая ветка истории теперь является authoritative**.

---

# 15. Logical replication тоже пришлось научить переживать failover

Когда logical replication/CDC становится важной частью architecture, physical failover не должен означать «все slots потерялись, начинаем synchronization сначала».

PG17 добавляет failover control/synchronization logical replication slots и сохраняет logical slots/subscription state при `pg_upgrade` в поддерживаемых сценариях.

https://www.postgresql.org/docs/17/release-17.html

Это очень важный эволюционный сигнал:

> **Derived-state pipelines становятся частью production state, которую PostgreSQL начинает помогать переносить через failover и upgrade.**

Не только tables имеют continuity requirements.

---

# 16. Invariant HA

Я бы оставил его предельно коротким:

> **В каждый момент существует ровно один authoritative writable primary.**

Всё остальное — детали реализации этого свойства:

- failure detection;
- quorum/consensus;
- fencing;
- promotion;
- routing;
- timelines;
- rewind;
- recovery of replicas/slots.

Если HA design не может доказать этот invariant при network partition, это пока не HA design, а optimistic automation.

---

# 17. Что связывает security, online change, backup и failover

Везде есть одна мысль:

> **Сильная операция должна иметь ограниченную область действия и проверяемый результат.**

Security:
- кому разрешено действие?

Online maintenance:
- сколько оно блокирует и сколько debt создаёт?

Backup:
- можем ли мы вернуть прошлое состояние?

Failover:
- какая ветка истории теперь считается истиной?

Это уже не четыре DBA-topic. Это один разговор про **контроль изменения работающей системы**.



\newpage

# Работающий PostgreSQL
## Археология 07: соединения, locks, planner и состояние после upgrade

Эта часть про три вещи, которые практик видит каждый день и поэтому перестаёт замечать, насколько они странные.

- Каждый client получает отдельный backend process.
- MVCC есть, но sessions всё равно могут выстроиться в огромную очередь на lock.
- Planner каждый раз принимает решение на основе неполного знания и иногда выбирает то, что человеку кажется очевидно неправильным.

А потом мы делаем upgrade и удивляемся, что «те же данные» ведут себя иначе.

---

# 1. Почему соединение с PostgreSQL — это не просто socket

Для приложения connection выглядит дешёво:

```text
open connection
send SQL
get result
```

Внутри PostgreSQL это намного более тяжёлое понятие.

Традиционная архитектура PostgreSQL — backend process per connection.

У connection появляется собственный process state:

- address space;
- memory contexts;
- session GUC state;
- prepared statements;
- temporary objects;
- transaction state;
- snapshots;
- locks;
- caches и локальные структуры backend-а.

Поэтому 2000 connections, которые «ничего не делают», всё равно не равны двум тысячам file descriptors и пустым sockets.

Но здесь нельзя скатываться в старый лозунг:

> processes are expensive, threads are cheap.

Мы уже видели в NUMA-археологии, что реальная цена сегодня живёт не столько в мифическом context switch, сколько в architecture вокруг private/shared state.

---

# 2. Connection pool не уничтожает очередь. Он выбирает, где она будет стоять

Представим application с 10 000 users.

Без pool она может попытаться открыть тысячи database sessions.

С pool мы говорим:

> PostgreSQL получит, например, 200 active connections, остальные подождут снаружи.

Это очень полезное изменение.

Но давайте назовём его честно:

> **Мы перенесли очередь с PostgreSQL backend population в pool.**

Очередь всё равно существует, если arrival rate выше service capacity.

И это хорошо: external queue часто дешевле и контролируемее, чем тысячи active database backends.

Но теперь latency пользователя состоит из:

```text
pool wait
 +
database execution
 +
network/client work
```

Если мониторить только `pg_stat_activity`, пользователь может ждать три секунды, а PostgreSQL честно показывать query duration 20 ms.

Опять два наблюдателя правы одновременно.

---

# 3. Transaction pooling имеет семантическую цену

Если pool отдаёт connection на всю session, application сохраняет привычную session semantics.

Если connection выдаётся только на transaction, масштабирование лучше, но надо спросить:

- где живут session-prepared statements?
- temp tables?
- session variables?
- advisory locks?
- LISTEN/NOTIFY state?
- SET, который application считает persistent?

То есть pooling — снова boundary trade-off.

Мы экономим backend/session resources, но часть PostgreSQL session semantics перестаёт быть естественной.

И это надо объяснять application developer-у до migration на transaction pooling, а не после странного production bug.

---

# 4. Invariant connections

Не:

> `max_connections` должно быть 200.

А:

> **Число одновременно работающих database sessions bounded, а очередь admission находится там, где её стоимость и SLA можно контролировать.**

Если системе нужно 5000 concurrent business requests, это не означает, что ей нужно 5000 simultaneously executing database transactions.

---

# 5. Если PostgreSQL имеет MVCC, почему вообще существуют locks?

Это хороший вопрос, потому что многие объяснения MVCC звучат так:

> readers don't block writers and writers don't block readers.

После этой фразы новичок совершенно разумно ожидает, что locks почти исчезли.

А потом один `ALTER TABLE` ставит production в очередь.

Причина проста: MVCC решает **определённый класс конфликтов вокруг versions данных**. Он не отменяет необходимость координировать:

- изменение schema;
- изменение одного и того же row;
- uniqueness/referential constraints;
- explicit locking;
- object lifecycle;
- internal shared state.

То есть MVCC и locks — не конкурирующие идеи. Они покрывают разные correctness boundaries.

---

# 6. Самый опасный lock часто не самый длинный

Представим:

1. transaction A держит weak lock и долго живёт;
2. DDL B приходит и ждёт более сильный lock;
3. за B начинают выстраиваться обычные queries C, D, E, которые сами по себе могли бы работать рядом с A, но конфликтуют с уже ожидающим DDL/lock ordering.

Пользователь видит:

> вдруг всё встало.

А root cause может быть session, которая вообще ничего сейчас не исполняет, а просто оставила transaction open.

Отсюда важнейшая operational привычка:

> **Искать root blocker, а не убивать самых заметных waiters.**

Если убить query C, очередь станет короче на одного человека. Причина останется.

---

# 7. Idle in transaction — это не idle

Эта фраза должна быть отдельной рамкой.

Backend может не использовать CPU и не делать I/O.

Но открытая transaction способна удерживать:

- snapshot horizon;
- locks;
- tuple visibility history;
- connection/backend resources.

Поэтому слово `idle` в monitoring UI опасно.

`idle in transaction` — это **живое состояние базы**, а не отсутствие работы.

Именно отсюда естественно возникают:

- `idle_in_transaction_session_timeout`;
- transaction discipline приложения;
- alert на age, а не только current query duration.

---

# 8. Lock timeout — не лечение locks, а bounding tool

В deployment scripts полезно иметь короткий `lock_timeout` не потому, что locks плохие.

А потому что production change имеет invariant:

> **неожиданное ожидание сильного lock не должно молча превращаться в многоминутный queue convoy.**

Если lock сейчас получить нельзя, часто безопаснее отказаться и повторить позже, чем зависнуть в середине deployment.

Это снова наш принцип bounded debt.

---

# 9. Planner: он не “видит данные”, он строит модель

Один из самых вредных способов объяснять плохой план:

> PostgreSQL почему-то решил сделать Seq Scan.

Planner не “решает” как человек, который открыл таблицу и посмотрел распределение.

У него есть сжатое знание:

- row counts;
- histograms;
- most common values;
- ndistinct;
- correlations;
- extended statistics там, где они созданы;
- cost constants;
- parameter information;
- available paths.

Из этого он оценивает будущее, которого ещё не видел.

Поэтому плохой plan полезно рассматривать не как неправильный выбор, а как вопрос:

> **Где впервые модель мира planner-а разошлась с реальностью?**

Обычно начинаем с первого серьёзного estimate error, а не с последнего дорогого node.

---

# 10. Statistics — это operational state

Очень долго statistics воспринимались почти как расходный материал:

> после restore/upgrade ANALYZE соберёт заново.

Но представим большую production database после major upgrade.

Data files перенеслись быстро.

Application открылась.

Planner statistics ещё нет или она отличается.

С точки зрения storage данные те же.

С точки зрения performance это **другая система**.

PostgreSQL 18 сделал важный шаг: `pg_upgrade` теперь умеет сохранять большинство optimizer statistics (extended statistics имеют оговорки).

https://www.postgresql.org/docs/18/release-18.html

Мне нравится эта feature именно философски.

Она признаёт:

> **Знание о распределении данных — часть production state.**

Не только heap/index bytes заслуживают continuity.

---

# 11. То же произошло с logical replication state

PG17 научил `pg_upgrade` сохранять поддерживаемые logical replication slots и subscriber state.

https://www.postgresql.org/docs/17/release-17.html

Почему?

Потому что иначе data copy успешно пережила upgrade, а change pipeline потерял continuity и требует resync.

То есть всё больше состояний PostgreSQL становятся “настоящими” с точки зрения operations:

```text
data
statistics
replication slots
subscriptions
WAL history
cache warmth
prepared/session state
```

Они имеют разную durability, но performance/availability зависит от них всех.

---

# 12. Generic и custom plans: один SQL не означает одну оптимальную стратегию

Prepared statement создаёт ещё один интересный компромисс.

Planning имеет стоимость.

Если statement выполняется много раз, хочется reuse plan.

Но parameter values могут радикально менять selectivity.

Например:

```text
customer_id = ordinary customer → 10 rows
customer_id = giant tenant      → 20 million rows
```

Один generic plan может быть отличным для первого и ужасным для второго.

Поэтому PostgreSQL умеет выбирать между custom и generic planning approaches.

Практическая ошибка здесь — увидеть нестабильность и сразу “зафиксировать правильный plan”.

Сначала надо понять:

> действительно ли проблема в planner instability или у нас parameter distributions требуют разных plans?

---

# 13. PG19 plan advice: полезный предохранитель, но не замена пониманию

В PostgreSQL 19 beta появляется `pg_plan_advice` и companion `pg_stash_advice`, позволяющие стабилизировать/контролировать planner decisions.

Release notes:
https://www.postgresql.org/docs/19/release-19.html

Это очень полезно для production.

Представим regression после deploy/upgrade. Нужно быстро вернуть известный хороший shape плана, пока мы разбираемся.

Advice может стать **operational bridge**.

Но книга должна сразу развести две вещи:

> workaround и root cause.

Если плохой plan возник из-за неверной cardinality estimate, advice не исправляет знание planner-а о мире. Он лишь говорит:

> пока делай вот так.

И это нормально, если мы так его и используем.

PG19 пока Beta 3; syntax/semantics перепроверить перед печатью.

---

# 14. Эксперимент planner-а: найти первую ложь

Берём специально skewed dataset.

Строим query с несколькими plan alternatives.

Шаги:

1. `EXPLAIN` — estimates.
2. `EXPLAIN ANALYZE` — actual rows.
3. Ищем первый node, где estimates сильно разошлись.
4. Выясняем, чего planner не знает.
5. Меняем statistics/data model/query information.
6. Смотрим, изменился ли выбор сам.
7. Только потом пробуем advice/forcing как operational tool.

### Invariant

> **Для SLA-critical queries planner имеет достаточную информацию, а временное plan control не подменяет устранение systematic estimate error.**

---

# 15. Upgrade надо тестировать как изменение работающей системы

Плохой upgrade test:

> `pg_upgrade` завершился; smoke tests проходят.

Хороший:

- plans ключевых queries;
- statistics continuity;
- extensions;
- logical slots/subscriptions;
- authentication/security changes;
- cache warm-up;
- replication catch-up;
- backup compatibility;
- new defaults;
- performance tails under normal day workload.

Особенно важна последняя строка.

Новый major PostgreSQL может быть быстрее почти везде и всё равно ухудшить конкретную вашу critical path из-за changed plan, changed I/O pattern или changed concurrency interaction.

Поэтому upgrade — это не только compatibility test.

Это **новый экземпляр нашего operational-day experiment**.

---

# 16. Что объединяет connections, locks и planner

Все три темы говорят о скрытом состоянии.

Connection выглядит idle, но хранит session/transaction state.

Query выглядит blocked, но причина живёт в другом backend-е.

Plan выглядит как решение одного SQL, но на самом деле вырос из statistics и parameter history.

Поэтому monitoring, который показывает только current statement, всегда будет недостаточным.

Надо видеть **контекст, который сделал current statement таким**.

И это ещё одна хорошая формулировка “прояснения PostgreSQL”:

> **Мы хотим не только увидеть, что PostgreSQL делает сейчас. Мы хотим восстановить состояние и историю, из которых это действие стало неизбежным.**



\newpage

# Работающий PostgreSQL
## Археология 06: capacity, рабочий день, incident и что можно отдать автоматике

Мы дошли до точки, где можно снова задать первый вопрос книги:

> **Что значит “PostgreSQL работает хорошо”?**

Теперь ответ уже не помещается в `SELECT 1` и не помещается даже в TPS.

Работающая система живёт во времени. Она прогревается. Она копит и гасит vacuum debt. Она пишет WAL. Она иногда отстаёт по replication. Она переживает checkpoints. Она делает backups. На неё приходит не идеальный benchmark traffic, а бизнес-нагрузка с пиками, длинными transactions, DDL, retries и человеческими ошибками.

Поэтому unit of performance для production — не один query.

Я бы сделал unit-ом **операционный день**.

---

# 1. Почему короткий benchmark так легко врёт

Допустим, мы запустили `pgbench` на десять минут.

Получили:

```text
18 000 TPS
p95 = 8 ms
p99 = 20 ms
```

Выглядит отлично.

Но за десять минут могли не успеть проявиться:

- несколько checkpoint cycles;
- серьёзный autovacuum;
- freeze pressure;
- backup;
- daily report;
- ETL peak;
- replica catch-up;
- log retention/rotation;
- connection churn;
- long transaction;
- cache displacement;
- планировочное изменение на реальном parameter mix.

То есть мы измерили **execution ability в одном состоянии**, а не способность системы прожить день.

Это не делает короткий benchmark плохим.

Он просто отвечает на другой вопрос.

---

# 2. Performance надо измерять при фиксированном arrival rate

Benchmark “as fast as possible” полезен, когда мы ищем максимальную throughput boundary.

Но production обычно устроен иначе.

Запросы приходят независимо от того, успел PostgreSQL обработать предыдущие или нет.

Поэтому для tail/debt experiments намного полезнее rate-limited workload.

Современный `pgbench --rate` как раз ведёт schedule independently от completion предыдущей transaction. Если client начинает отставать от schedule, появляется `schedule lag`. А при `--latency-limit` transactions, которые уже безнадёжно опоздали до старта, могут быть помечены как skipped.

Документация PG19:
https://www.postgresql.org/docs/19/pgbench.html

Это почти готовая модель SLA queue.

`pgbench` буквально умеет показать:

> система уже настолько отстала, что следующую transaction бессмысленно даже отправлять, если мы хотим уложиться в limit.

Вот это намного ближе к реальной производительности бизнеса, чем “max TPS”.

---

# 3. Хвост — это не один медленный запрос

Вернёмся к нашей формуле.

Arrival:

```text
λ = 1000 tx/s
```

Sustainable capacity:

```text
μ = 1100 tx/s
```

Headroom:

```text
h = μ - λ = 100 tx/s
```

На одну секунду произошёл stall и completion почти остановился.

Debt:

```text
D ≈ 1000 tx
```

После stall debt гасится только spare capacity:

```text
100 tx/s
```

Значит, recovery около 10 секунд.

И вот ключевой момент:

> **Одна секунда p99-проблемы может породить десять секунд queueing-проблемы.**

Если такие stalls происходят чаще, чем мы успеваем возвращаться к baseline, система входит в режим накопления долга.

При этом средняя execution latency тех transactions, которые уже добрались до server, может оставаться довольно хорошей.

Пользователь видит очередь. Database profiler видит быстрые queries. Оба правы.

---

# 4. Headroom — не роскошь и не “неиспользованный сервер”

Очень естественная оптимизация бюджета:

> сервер в peak загружен только на 70%, значит мы переплатили 30%.

Но spare capacity выполняет работу.

Она нужна, чтобы:

- догонять после stalls;
- принять burst;
- выполнить vacuum;
- replay replica;
- пережить failover на меньшем составе;
- закончить backup;
- перестроить index;
- выдержать hardware degradation.

Поэтому headroom — это **recovery resource**.

Если система в normal state уже работает на 99.5% sustainable capacity, любой маленький долг становится почти вечным.

Можно даже написать:

```text
recovery time ≈ debt / spare capacity
```

И эта формула объясняет бизнесу необходимость capacity reserve гораздо лучше, чем “best practice 30% free CPU”.

---

# 5. Рабочий день как accounting system долгов

Представим, что утром все counters равны не нулю, но нормальному baseline.

За день система создаёт:

### Transaction debt

Пришла работа, которую ещё не завершили.

### MVCC debt

UPDATE/DELETE создали versions, которые надо reclaim/freeze.

### Write/checkpoint debt

Dirty pages должны стать persistent.

### WAL retention debt

Archive/replicas/slots ещё не отпустили историю.

### Replay debt

Standby должен применить WAL.

### ETL/search debt

Derived systems должны догнать truth.

### Logging debt

Logs должны пройти pipeline и retention.

### Backup obligation

Надо создать recovery point и проверить, что цепочка завершилась.

В конце дня мы спрашиваем не:

> Сколько TPS было в среднем?

А:

> **Что мы должны были закончить сегодня и что оставили завтра?**

---

# 6. Главная business metric

Мне кажется, её стоит оставить почти без украшений:

> **Количество необходимых SLA-transactions, завершённых за операционный день.**

В неё автоматически входят вещи, которые обычный benchmark выбрасывает как “фон”:

- long transactions;
- vacuum;
- checkpoints;
- backups;
- maintenance;
- bursts;
- replication;
- retries;
- recovery after stalls.

Потому что клиенту всё равно, почему его обязательная transaction не была завершена сегодня.

Для него она просто не выполнена.

---

# 7. Что означает “система выдерживает 10 000 TPS”

Эта фраза почти всегда неполна.

Надо спросить:

- сколько времени?
- с каким p99?
- с каким parameter/data distribution?
- при каком cache state?
- идёт ли backup?
- работает ли autovacuum?
- успевает ли replica?
- сколько WAL остаётся после теста?
- сколько dead tuples накопилось?
- какой backlog остался после остановки нагрузки?

Хороший benchmark должен иметь **aftercare phase**.

Мы не выключаем `pgbench` и сразу записываем число TPS в презентацию.

Мы ещё наблюдаем:

> сколько времени система возвращается к operational baseline?

Это особенно важно для stress test.

---

# 8. Capacity planning через derivatives

Обычный capacity planning:

```text
CPU 65%
RAM 70%
Disk 50%
```

Полезно, но недостаточно.

Интереснее смотреть на пары production/service rates.

| Debt | Production | Service |
|---|---|---|
| requests | arrival | completion |
| dead tuples | update/delete churn | vacuum/prune |
| WAL archive | WAL generation | archive transport |
| replica | WAL generation | replay |
| logs | log generation | ship/index |
| ETL | committed changes | transform/load |
| warm-up | demand for uncached state | cache fill |

Для каждой пары спрашиваем:

> В normal load service rate выше production rate?

И второй вопрос:

> Какой burst мы можем пережить и за сколько потом догнать?

Так capacity planning становится не прогнозом “когда CPU будет 100%”, а прогнозом **когда какой-нибудь долг перестанет быть bounded**.

---

# 9. Как найти первый будущий предел

Представим, бизнес растёт на 5% в месяц.

CPU пока 50%.

Но WAL generation уже вырос до 800 MB/s, а archive pipeline устойчиво вывозит 850 MB/s.

Что сломается раньше?

Не CPU.

Archive headroom всего 50 MB/s.

Любой burst начнёт создавать долг, который будет очень долго уходить.

Или другой пример:

Primary держит 40% CPU, но replica replay при normal workload уже 95% от generation rate.

Ваш первый capacity incident будет не “primary CPU 100%”, а replica, которая после maintenance window больше никогда не догонит.

Вот зачем модели долгов нужна книга: она заставляет искать limit не там, где проще всего построить график.

---

# 10. Incident: не лечить красную метрику

Теперь представим, всё уже произошло.

p99 вырос в десять раз.

Что делает плохая автоматизация?

```text
metric X high
   ↓
run action Y
```

Например:

- CPU high → добавить connections/parallelism;
- dead tuples high → запустить VACUUM FULL;
- replica lag high → rebuild standby;
- locks high → kill sessions;
- logs high → выключить logging;

Иногда это помогает.

Но это не diagnosis. Это reflex.

---

# 11. Incident надо проходить назад по книге

Наша книга к этому моменту уже дала читателю язык.

Поэтому incident loop может быть очень простым:

```text
symptom
  ↓
evidence
  ↓
which debt/invariant changed?
  ↓
which service mechanism is not keeping up?
  ↓
why?
  ↓
smallest safe action
  ↓
verify derivative/convergence
```

Обратите внимание на последнее слово.

После действия недостаточно увидеть, что metric стала меньше.

Надо увидеть, что **она движется в правильную сторону**.

Replica lag было 100 GB, стало 80 GB — прекрасно только если оно продолжает уменьшаться.

Dead tuples стало меньше после manual vacuum — хорошо только если daily creation/service rates теперь устойчивы.

Queue упала после рестарта — хорошо только если load после warm-up снова не создаёт её быстрее, чем мы обслуживаем.

---

# 12. Сначала сохранить evidence

Во время incident хочется действовать.

Но некоторые действия уничтожают доказательства.

Restart убирает:
- current waits;
- session state;
- locks;
- memory state;
- transient plans/caches;
- часть временной причинной цепочки.

Kill blocker может мгновенно починить symptom и одновременно лишить нас понимания, почему blocker появился.

Поэтому у operational system должна быть минимальная процедура evidence capture:

- `pg_stat_activity`;
- wait graph;
- relevant `pg_stat_*` snapshots;
- WAL/I/O rates;
- OS pressure;
- logs around transition;
- active/long transactions;
- replication positions;
- configuration/version/deploy state.

Но не надо превращать incident в музейную археологию.

Если бизнес падает, smallest safe action идёт первым после достаточного evidence.

---

# 13. Инвариант лучше threshold

Threshold:

> replica lag > 10 GB = красный.

Invariant:

> replica должна иметь положительную catch-up capacity и уложиться в допустимый freshness window.

Threshold:

> dead tuples > 1 million = красный.

Invariant:

> vacuum debt bounded и freeze horizon безопасен.

Threshold:

> CPU > 80% = красный.

Invariant:

> system сохраняет service capacity/headroom для SLA и обязательного maintenance.

Threshold всё равно нужен для alerting.

Но он должен быть **производным от модели**, а не заменять модель.

---

# 14. Что можно отдать автоматике

Когда у нас есть invariant, автоматизация становится намного безопаснее.

Например, replica:

```text
observe:
G = generation rate
R = replay rate
L = lag

invariant:
R must exceed G enough to recover within freshness objective

action:
raise resources / throttle optional workload / switch read policy

verify:
dL/dt < 0 and ETA acceptable
```

Это уже похоже на control system.

А правило:

```text
if lag > 10GB then restart replica
```

не похоже.

---

# 15. Где здесь AI-агент

Мне кажется, это хорошее место закончить книгу.

Не главой “AI for DBA”, где мы перечислим LLM tools.

А вопросом:

> **Какому агенту я вообще разрешу менять production PostgreSQL?**

Ответ, который вырос из всей книги:

Агент должен уметь:

1. наблюдать evidence;
2. отличать состояние от производной;
3. выбрать причинную модель;
4. назвать invariant, который нарушен;
5. оценить blast radius действия;
6. выбрать smallest reversible/safe action;
7. проверить convergence;
8. остановиться, если модель не подтверждается.

То есть агенту недостаточно знать “best practices PostgreSQL”.

Он должен уметь **прояснять PostgreSQL**.

---

# 16. Агент иногда должен исправить сам вопрос человека

Это особенно важно.

DBA пишет:

> У меня replica lag 400 GB. Как быстрее её rebuild?

Хороший агент не начинает с команды `pg_basebackup`.

Он сначала спрашивает систему:

- lag растёт или уменьшается?
- receive/write/flush/replay где?
- есть ли catch-up capacity?
- сколько времени до desired freshness?

И может ответить:

> Rebuild пока вообще не нужен. Replica догоняет, и rebuild только увеличит recovery time.

Или:

> Проблема не replay. WAL уже не приходит из-за network/slot/archive boundary.

То есть агент имеет право **уточнить задачу по evidence**, а не слепо исполнять формулировку пользователя.

Это уже не чат-бот над документацией.

Это operational reasoning.

---

# 17. Но automation не должна скрывать механизм

Есть опасность.

Если мы идеально автоматизировали vacuum, failover, scaling и query advice, практик может перестать понимать систему.

А потом случится случай, который automation не предусмотрела.

Поэтому я бы сформулировал философию книги так:

> **Хорошая автоматизация уменьшает число ручных действий, но не должна уничтожать причинную модель.**

В dashboard/agent answer должно быть видно не только:

> “I increased X.”

А:

> “WAL generation exceeded archive service rate for 18 minutes. Retained WAL is growing at 42 GB/h. At the current rate disk headroom is 3.1 hours. I reduced optional workload; the derivative is now negative. No restart was required.”

Это язык, которому можно доверять.

---

# 18. Финальный эксперимент книги: один рабочий день

В конце я бы вообще перестал давать отдельные упражнения.

Сделать один интеграционный stand.

## Утро

- restart;
- warm-up;
- постепенно растущий OLTP.

## День

- steady load;
- normal autovacuum;
- checkpoints;
- logs;
- physical replica;
- CDC/ETL consumer.

## После обеда

- большой analytical query;
- небольшая long transaction;
- index build / online maintenance.

## Incident

- короткий storage stall или forced checkpoint;
- затем consumer/replay slowdown.

## Вечер

Смотрим:

- сколько business transactions пришло;
- сколько completed within SLA;
- сколько late/skipped;
- максимальный transaction debt;
- recovery time после stall;
- vacuum debt;
- WAL retention;
- replica catch-up;
- ETL lag;
- log backlog;
- backup state.

И задаём последний вопрос:

> **Мы действительно закончили сегодняшний день или просто перестали принимать новые запросы?**

Вот это и есть “Работающий PostgreSQL”.

---

# 19. Главный invariant книги

Можно попытаться собрать всё в одну фразу:

> **Работающий PostgreSQL — это система, которая выполняет обязательную бизнес-работу в обещанные сроки, сохраняет authoritative state и способна устойчиво обслуживать все долги, которые создаёт собственная работа.**

И ещё одна, более инженерная:

> **После разрешённого возмущения каждый важный backlog должен сходиться обратно к нормальному состоянию.**

Если это выполняется — система живая.

Если нет — даже зелёный dashboard может просто показывать раннюю фазу аварии.



\newpage

# Работающий PostgreSQL — master map книги

Рабочая версия, 5 сентября 2026.

## Зачем эта карта

Это не оглавление и не каталог возможностей PostgreSQL.

Единица книги — **реальная ситуация работающей системы**. Для каждой ситуации мы должны пройти одну и ту же причинную дугу, но не показывать её читателю механически:

> **наблюдаем → ставим эксперимент → проясняем PostgreSQL → смотрим эволюцию → понимаем компромисс → формулируем invariant → действуем → проверяем convergence**

Release notes используются как карта археологических слоёв. Они показывают, какие проблемы сообщество считало достаточно важными, чтобы менять PostgreSQL. Для ключевых историй release note — только начало: дальше нужны commit, hackers и source archaeology.

В книге должен постоянно присутствовать второй голос — **«Почему PostgreSQL так устроен?»**. Он не уводит читателя в отдельный учебник internals, а появляется ровно там, где без понимания механизма практическое действие превращается в магический рецепт.

---

# Общая модель книги

Работающий PostgreSQL постоянно создаёт обязательства и долги:

- request backlog;
- dirty-page / checkpoint debt;
- MVCC / vacuum debt;
- freeze debt;
- WAL retention debt;
- replication / replay debt;
- ETL / CDC debt;
- search-index debt;
- logging debt;
- warm-up debt;
- maintenance catch-up debt.

Для многих из них полезна одна простая модель:

\[
D_{t+\Delta} = D_t + production\ rate - service\ rate
\]

Большое значение долга может быть безопасным, если оно быстро уменьшается. Маленькое значение может быть уже аварийным, если производная положительна и система не способна догнать.

Вторая общая модель — **truth vs derived state**:

> PostgreSQL часто является authoritative transactional state. Реплики, warehouse, search, caches и другие производные системы допустимы, если у них есть явные contracts по freshness, consistency, rebuildability и recovery.

Третья модель — **хвосты как генератор долга**:

Если arrival rate = 1000 tx/s, sustainable capacity = 1100 tx/s, а система на одну секунду почти останавливается, возникает примерно 1000 tx backlog. Свободная мощность после затыка всего 100 tx/s, поэтому одна секунда stall требует около 10 секунд catch-up. Редкие stalls способны испортить весь операционный день, хотя большинство отдельных запросов остаются быстрыми.

---

# MASTER MAP: 30 реальных проблем

## 1. «Я запустил запрос в psql. Так сколько он на самом деле работает?»

**Что видит практик:** первый запуск 120 ms, второй 40 ms, третий 39 ms.

**Прояснение PostgreSQL:** planning/execution/client transfer; shared buffers; OS page cache; JIT; temporary work; visibility and I/O.

**Археология:** постепенное появление `EXPLAIN` runtime observability, `EXPLAIN BUFFERS` в PG9.0, позднее richer I/O statistics.

**Эксперимент:** cold/warm runs; `EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)`; repeated runs; separate client-output cost.

**DBA/QPT reservoir:** monitoring, EXPLAIN, query profiling.

**Invariant:** performance claim must state what was measured and under what state.

**Production decision:** не экстраполировать один execution на service capacity.

---

## 2. «Мне надо измерить вычисление, а не диск»

**Что видит практик:** интересующая CPU-операция тонет в scan/runtime overhead.

**Прояснение PostgreSQL:** executor expression evaluation, planner transformations, constant folding, JIT, function volatility.

**Археология:** executor API and expression machinery; later JIT and planner transformations.

**Эксперимент:** **amplification** — многократно повторяем именно интересующую операцию над тем же входом, проверяем план, вычитаем baseline только если работа действительно общая.

**Invariant:** signal must dominate measurement noise without amplifying the wrong subsystem.

**Production decision:** microbenchmark отвечает на локальный вопрос; он не является performance validation системы.

---

## 3. «99% запросов быстрые. Почему к вечеру накопилась огромная очередь?»

**Что видит практик:** хороший median, приемлемый average, но к концу дня backlog.

**Прояснение PostgreSQL:** queueing; finite headroom; stalls; lock/checkpoint/I/O interference.

**Археология:** PG8.0 background writer, PG8.3 checkpoint spreading — исторические попытки уменьшить concentrated stalls.

**Эксперимент:** arrival-rate benchmark → bounded stall → recovery phase; измерять p50/p95/p99, backlog и catch-up time.

**Invariant:** после допустимого возмущения backlog должен сходиться к нормальному уровню.

**Production decision:** capacity определяется не peak TPS, а способностью завершить требуемую работу и погасить долг.

---

## 4. «pgbench десять минут прекрасен. Почему рабочий день плохой?»

**Что видит практик:** benchmark показывает высокий TPS, production копит незавершённую работу.

**Прояснение PostgreSQL:** steady state не успел сформироваться; vacuum, checkpoints, WAL, replica, backup, cache turnover имеют собственные циклы.

**Археология:** release evolution maintenance mechanisms показывает, что background work всегда был частью реальной производительности.

**Эксперимент:** short run vs long steady-state run; затем perturbation test.

**Invariant:** workload должен быть sustainable вместе с обязательным maintenance.

**Production decision:** performance acceptance = SLA + duration + maintenance + tails + recovery.

---

## 5. «PostgreSQL поднялся после restart. Почему пользователям ещё плохо?»

**Что видит практик:** postmaster отвечает, но latency первые 10–30 минут хуже.

**Прояснение PostgreSQL:** OS cache ≠ shared buffers; working set; pool/application state; plans/JIT; storage queue state.

**Археология:** PG8.3 cache-preserving large scans and synchronized scans; PG9.4 `pg_prewarm`; PG18 AIO.

**Эксперимент:** cold machine / warm OS / warm shared buffers / real workload warm-up; измерить trajectory до steady state.

**Invariant:** service reaches required operating region within a bounded warm-up interval.

**Production decision:** restart/failover RTO должен включать warm-up, а не только открытый порт.

---

## 6. «Логов мало — ничего не понятно. Логов много — система сама страдает»

**Что видит практик:** либо нет причинности, либо logging pipeline перегружен.

**Прояснение PostgreSQL:** logging — это workload с generation rate, serialization, local I/O, transport, remote collector and retention.

**Археология:** более богатый logging → sampled logging PG12 → JSON logs PG15 → richer statistics and per-backend attribution. PG15 release notes прямо предупреждают о resource impact дополнительного default logging.

**Реальная история:** включение prepared transactions изменило поведение сервиса; вырос log traffic; машина, перевозившая логи, перестала справляться; observability backlog стал operational failure.

**Эксперимент:** поднять контролируемый log rate; измерить foreground tails и способность shipper/collector догонять.

**Invariant:** log generation must remain serviceable; observability itself cannot have an unbounded queue.

**Production decision:** sampling, structured logging, dynamic escalation during incidents, explicit transport capacity.

---

## 7. «Почему COMMIT быстрый, если диск медленный?»

**Что видит практик:** committed changes видимы быстро, хотя data pages ещё не обязательно на своих местах.

**Прояснение PostgreSQL:** WAL rule; durability boundary; dirty buffers; REDO; fsync.

**Археология:** WAL в PG7.1 → background writer PG8.0 → WAL writer, async commit and checkpoint spreading PG8.3 → AIO PG18.

**Эксперимент:** sync vs async commit; WAL latency; checkpoint interaction.

**Invariant:** durability contract должен быть явным; deferred page writes must remain serviceable.

**Production decision:** не путать «быстро завершить commit» с «вся работа записи уже закончена».

---

## 8. «Каждые несколько минут p99 взлетает»

**Что видит практик:** throughput почти нормален, но периодические latency spikes.

**Прояснение PostgreSQL:** dirty pages, checkpoint work, I/O queueing, full-page images, competition with foreground writes.

**Археология:** именно checkpoint I/O spikes были причиной checkpoint spreading в PG8.3.

**Эксперимент:** одинаковый arrival-rate workload при разной checkpoint pressure; p99 + write rate + WAL + backlog recovery.

**Invariant:** checkpoint work must fit inside service envelope.

**Production decision:** настройка checkpoint — это управление распределением долга записи во времени, а не поиск «лучшего max_wal_size».

---

## 9. «Машина большая, CPU много, а PostgreSQL не масштабируется»

**Что видит практик:** throughput перестаёт расти или падает на multi-socket server.

**Прояснение PostgreSQL:** shared structures, cache-line contention, coherence, memory bandwidth, scheduler placement, locality, locks/atomics, not just remote-memory latency.

**Археология:** PG8.1 buffer-cache locking scalability; PG9.5 multi-CPU improvements; PG9.6 explicit multi-CPU-socket work: `ProcArrayLock`, buffer content locks, atomics, shared hash freelists.

**Наш опыт:** трудно было получить сильное падение, если строить workload только вокруг remote memory access. Значимый эффект возникал из комбинации механизмов.

**Эксперимент:** causal workload ladder: local/remote memory → bandwidth → shared cache lines → shared buffers → real concurrent SQL.

**Invariant:** performance diagnosis must identify the actual contended resource, not a fashionable hardware label.

**Production decision:** NUMA tuning только после доказанного causal mechanism.

---

## 10. «Процессы медленнее нитей — значит PostgreSQL надо просто переписать на threads?»

**Что видит практик:** тысячи backend processes и привлекательное простое объяснение overhead.

**Прояснение PostgreSQL:** modern OS process/thread scheduling has converged in many costs; важны оставшиеся архитектурные различия: separate address spaces, private backend state, shared-memory boundary, memory duplication, allocator/cache locality, connection model, extension APIs.

**Археология:** ранний POSTGRES рассматривал разные lightweight execution models; PostgreSQL scalability десятилетиями улучшалась через shared structures and atomics, а не только смену process model.

**Эксперимент:** measure connection/backend memory, scheduling/locality, shared-state contention; compare causal costs rather than context-switch folklore.

**Invariant:** architecture should change only for a measured dominant cost.

**Production decision:** pooling/thread discussion начинается с цены конкретной границы, а не с лозунга.

---

## 11. «Почему UPDATE создаёт мусор, если мы просто заменили значение?»

**Что видит практик:** dead tuples, growing relations, autovacuum.

**Прояснение PostgreSQL:** MVCC, snapshots, tuple versions, xmin/xmax, old readers.

**Археология:** old tuple retention → autovacuum external tool → built-in autovacuum PG8.1 → HOT PG8.3 → VM PG8.4 → parallel/smarter vacuum → PG19 prioritization.

**Эксперимент:** long snapshot + repeated UPDATE; observe dead tuples/horizon/vacuum effectiveness.

**Invariant:** snapshot age bounded; vacuum service rate >= long-run debt creation rate.

**Production decision:** лечить причину debt, а не добиваться нулевого числа dead tuples.

---

## 12. «VACUUM прошёл. Почему файл не уменьшился?»

**Что видит практик:** dead tuples исчезли/space reusable, но relation file почти прежний.

**Прояснение PostgreSQL:** reusable internal free space vs physical truncation/rewrite; page structure; tuple/index references.

**Археология:** ordinary VACUUM vs historical `VACUUM FULL`; PG19 `REPACK` as newer answer to physical compaction/reorganization.

**Эксперимент:** UPDATE/DELETE → VACUUM → refill table → compare reuse; then REPACK/VACUUM FULL with I/O/WAL/disk/locks.

**Invariant:** reclaim physical space only when physical size is itself the problem.

**Production decision:** не переписывать busy table ради красивого filesystem number.

---

## 13. «Почему autovacuum работает постоянно и всё равно не успевает?»

**Что видит практик:** workers busy, large tables grow, freeze age rises.

**Прояснение PostgreSQL:** eligibility, thresholds, cost delay, worker scarcity, index cleanup, horizon holders.

**Археология:** multiple workers PG8.3 → VM PG8.4 → parallel index vacuum PG13 → smarter failsafe PG14 → vacuum memory PG17 → scoring + parallel autovacuum PG19.

**Эксперимент:** controlled update rate; vary vacuum service capacity; observe whether debt converges.

**Invariant:** every high-churn relation has sufficient maintenance capacity and freeze margin.

**Production decision:** per-table tuning, remove horizon blockers, adjust service capacity before globally silencing autovacuum.

---

## 14. «Почему индекс растёт даже на почти одинаковых значениях?»

**Что видит практик:** version churn, page splits, index bloat.

**Прояснение PostgreSQL:** MVCC creates multiple physical index references; HOT eligibility; B-tree page splits and duplicates.

**Археология:** HOT PG8.3; B-tree dedup PG13 explicitly targets duplicate/version-churn pressure and postpones unnecessary page splits.

**Эксперимент:** update indexed vs non-indexed columns; compare HOT ratio/index size; dedup on/off where valid.

**Invariant:** index maintenance debt must remain bounded under update pattern.

**Production decision:** schema/index design учитывает churn, а не только read access path.

---

## 15. «Мне нужен индекс на production. Почему одна полезная команда может остановить запись?»

**Что видит практик:** normal `CREATE INDEX` conflicts with writers; concurrent build lasts longer.

**Прояснение PostgreSQL:** lock requirements, index validity phases, multiple scans/waits.

**Археология:** `CREATE INDEX CONCURRENTLY` PG8.2 → `REINDEX CONCURRENTLY` PG12 → wider online maintenance trend → `REPACK CONCURRENTLY` PG19.

**Эксперимент:** concurrent workload + normal/concurrent build; observe blocking, duration, I/O, WAL and tails.

**Invariant:** every production DDL has a bounded blocking plan.

**Production decision:** online operation trades blocking for longer work/extra scans/catch-up; choose consciously.

---

## 16. «Большой scan испортил всё остальное»

**Что видит практик:** analytic/reporting scan evicts hot OLTP pages or saturates I/O.

**Прояснение PostgreSQL:** buffer replacement strategy, bulk-read rings, synchronized scans, OS cache, AIO.

**Археология:** PG8.3 large scans stop pushing frequently-used pages out and can share reads; later streaming/AIO evolution.

**Эксперимент:** run hot OLTP working set + large scan; measure cache/I/O/tails with controlled variants.

**Invariant:** low-priority large work must not destroy the service-critical working set.

**Production decision:** resource isolation, workload scheduling, replicas/derived systems where needed.

---

## 17. «Planner выбрал ужасный план. Почему он не видит очевидного?»

**Что видит практик:** estimate errors or wrong cost preference.

**Прояснение PostgreSQL:** planner sees statistics and cost model, not the real future result; statistics are compressed knowledge.

**Археология:** extended statistics evolution, expression statistics, richer planner visibility; PG18 preserving optimizer statistics across `pg_upgrade`; PG19 plan advice.

**Эксперимент:** compare estimates/actuals; find first cardinality divergence; change information before forcing choice.

**Invariant:** planner decisions must be based on adequate information for critical workloads.

**Production decision:** information → model → advice/override, in that order.

---

## 18. «Prepared statement сначала хорош, потом вдруг плох для некоторых параметров»

**Что видит практик:** same SQL, different parameter selectivity, generic/custom plan behavior.

**Прояснение PostgreSQL:** planning cost vs parameter-sensitive execution benefit.

**Археология:** server-side PREPARE already in PG7.3; later custom/generic plan machinery; PG19 adds better counters/plan-control tooling.

**Эксперимент:** skewed parameter distribution; repeated executions; inspect generic/custom transitions.

**Invariant:** critical parameter-sensitive queries must not silently settle on a plan that violates SLA.

**Production decision:** fix statistics/query shape first; force planning mode only with explicit reason and monitoring.

---

## 19. «PostgreSQL tuple-at-a-time — это просто Volcano и поэтому он медленный на analytics?»

**Что видит практик:** vector engines outperform on some analytical workloads.

**Прояснение PostgreSQL:** executor producer/consumer boundaries; `ExecProcNode`; TupleTableSlot; deforming; batch representation must survive across consumers to matter.

**Наша археология:** next-style executor/`ExecProcNode` lineage exists in POSTGRES source before the Volcano paper; нельзя объяснять историю копированием Volcano.

**Эксперимент:** vectorize only scan vs preserve batch through consumer chain; measure boundary costs.

**Invariant:** optimize the dominant interface boundary, not the fashionable operator.

**Production decision:** HTAP/vectorization discussion должна опираться на end-to-end execution path.

---

## 20. «Мне нужен поиск. Почему не вынести его сразу во внешний search engine?»

**Что видит практик:** external search seems specialized and attractive.

**Прояснение PostgreSQL:** integrated FTS shares transaction, snapshot, JOIN, ACL, backup/recovery boundary with authoritative data.

**Археология:** `tsearch2` → integrated core FTS PG8.3 → phrase search PG9.6; история собственной работы над FTS показывает реальную мотивацию.

**Эксперимент:** simulate update + search before/after external indexing lag; permission change; consumer failure/rebuild.

**Invariant:** every external derived index has explicit freshness, consistency, authorization and rebuild contracts.

**Production decision:** внешний search выбирается, когда его возможности окупают новую consistency boundary.

---

## 21. «Нужна новая функциональность PostgreSQL. Писать свой сервис или патчить core?»

**Что видит практик/разработчик:** отсутствующий тип/оператор/индексная семантика.

**Прояснение PostgreSQL:** extensible types, operators, access methods, functions, background workers, shared memory, extensions.

**Археология:** contrib culture → `CREATE EXTENSION` PG9.1 → dynamic background workers/DSM PG9.4 → trusted extensions PG13.

**Пример:** Nepali date type: существующий package почти подходит, но не хватает нужной семантики; можно сделать type + operators + casts + index support как extension.

**Эксперимент:** создать маленький data type/operator class extension и показать installation/upgrade/indexing.

**Invariant:** before creating an external subsystem, check whether required semantics naturally belong inside PostgreSQL's extension boundary.

**Production decision:** ecosystem first; core patch only when extension boundary genuinely insufficient.

---

## 22. «Если есть MVCC, почему все всё равно стоят на locks?»

**Что видит практик:** CPU idle, sessions waiting.

**Прояснение PostgreSQL:** MVCC removes many read/write conflicts but not all correctness constraints; heavyweight locks, row locks, DDL, wait graph.

**Археология:** long evolution of lock granularity/scalability; richer wait visibility from PG9.6 onward; PG19 further lock observability.

**Эксперимент:** root blocker → waiting DDL → new requests convoy.

**Invariant:** waits that can threaten service have explicit bounds/timeouts.

**Production decision:** find root blocker; do not kill waiters; rehearse DDL with `lock_timeout`.

---

## 23. «Хочу очередь задач в PostgreSQL. Не будет ли всё блокироваться?»

**Что видит практик:** multiple workers contend for work rows.

**Прояснение PostgreSQL:** row locks, inconsistent-but-useful queue semantics, transaction ownership.

**Археология:** `SKIP LOCKED` PG9.5 explicitly supports queue-like consumers by skipping currently locked rows.

**Эксперимент:** N concurrent workers selecting work with/without `SKIP LOCKED`; compare contention/fairness/retries.

**Invariant:** work ownership and retry/idempotency semantics explicit.

**Production decision:** PostgreSQL can be a queue for appropriate workloads, but semantics must be chosen deliberately.

---

## 24. «Пользователь postgres может всё. Почему так и как перестать жить под superuser?»

**Что видит практик:** operational scripts/services use unrestricted superuser because it is easy.

**Прояснение PostgreSQL:** OS account vs database role; role membership; ownership; predefined capability roles; RLS; maintenance privileges.

**Археология:** roles PG8.1 → RLS PG9.5 → SCRAM PG10 → narrower predefined roles PG11+ → safer `public` default PG15 → `MAINTAIN`/`pg_maintain` PG17 → OAuth PG18. Postgres Pro separation-of-duties work is a natural local continuation.

**Эксперимент:** perform monitoring/maintenance/extension tasks with minimum roles; show where superuser is actually required.

**Invariant:** routine operations use least privilege; superuser is an exceptional capability.

**Production decision:** split operational roles by responsibility instead of sharing `postgres`.

---

## 25. «Replica отстаёт на 400 GB. Это катастрофа или она уже выздоравливает?»

**Что видит практик:** one lag number.

**Прояснение PostgreSQL:** WAL generation → send → receive → write → flush → replay; lag is a queue with a derivative.

**Археология:** WAL shipping → streaming replication PG9.0 → sync PG9.1 → cascading/quorum/logical evolution → PG19 richer recovery semantics.

**Эксперимент:** throttle standby, then restore capacity; measure G (generation) and R (replay), not only current L.

**Invariant:** replica expected to remain current has positive catch-up capacity over sustainable workload.

**Production decision:** diagnose stage and derivative before rebuilding a replica.

---

## 26. «Я записал на primary и сразу прочитал старое значение на replica»

**Что видит практик:** asynchronous replication violates intuitive read-your-writes.

**Прояснение PostgreSQL:** commit durability != standby replay visibility; consistency is an application contract.

**Археология:** async streaming → synchronous modes → quorum → PG19 `WAIT FOR LSN`.

**Эксперимент:** write, capture LSN, immediate standby read; then wait-for-replay and compare latency/freshness.

**Invariant:** every replica-read path has an explicit stale-read/read-your-writes contract.

**Production decision:** choose async, sync or targeted waiting based on business semantics, not generic «HA best practice».

---

## 27. «Primary умер. Можно просто promote replica?»

**Что видит практик:** technically promotable standby.

**Прояснение PostgreSQL:** timeline/history, asynchronous loss window, fencing, client routing, old primary return.

**Археология:** streaming replication → `pg_rewind` PG9.5 → quorum/sync evolution → logical failover support PG17.

**Эксперимент:** controlled failover while workload runs; compare last acknowledged vs surviving transaction; reconnect clients; return old primary safely.

**Invariant:** exactly one authoritative writable primary.

**Production decision:** failover is a distributed-system transition, not a single SQL/admin command.

---

## 28. «Backup зелёный. Значит, мы защищены?»

**Что видит практик:** successful backup job.

**Прояснение PostgreSQL:** base backup + WAL chain + recovery target + external dependencies + restore time.

**Археология:** PITR PG8.0 → streaming/base-backup improvements → progress visibility → incremental backup PG17.

**Эксперимент:** restore drill to a chosen point; application validation; measured RPO/RTO.

**Invariant:** backup exists only when a usable database can be restored within the promised objective.

**Production decision:** recovery is tested as a service property, not inferred from copied bytes.

---

## 29. «OLTP и OLAP работают отдельно. Почему их сумма не становится HTAP?»

**Что видит практик:** both workloads run on one cluster, but OLTP tails explode or analytics stale/slow.

**Прояснение PostgreSQL:** cache/I/O/memory/parallel-worker interference, long snapshots, vacuum horizon, data freshness.

**Археология:** materialized views PG9.3, logical decoding PG9.4, BRIN PG9.5, parallel query PG9.6, declarative partitioning/logical replication PG10, continuing analytical execution improvements.

**Эксперимент:** OLTP baseline → add large analytical workload → measure tails, cache/I/O, snapshot age, vacuum debt; then isolate/replicate/materialize and compare.

**Invariant:** analytical work has explicit resource and freshness contracts and cannot destroy transactional SLA.

**Production decision:** HTAP is managed coexistence around truth, not `OLTP + OLAP`.

---

## 30. «Баланс в PostgreSQL один, в warehouse другой, в cache третий. Кто прав?»

**Что видит практик:** several technically valid copies disagree.

**Прояснение PostgreSQL:** transactional truth vs derived state; CDC/ETL/replay queues; point-in-time semantics; reconciliation.

**Археология:** materialized views → logical decoding → logical replication → richer failover/CDC features.

**Эксперимент:** controlled transaction + CDC delay/failure + rebuild; show which states can be reconstructed from which.

**Invariant:** every derived system names its authoritative source, freshness bound, replay/rebuild procedure and reconciliation rule.

**Production decision:** PostgreSQL does not have to execute every workload, but the architecture must know where truth lives.

---

# Сквозная ситуация: операционный день

Эта ситуация должна возвращаться много раз и стать финальным интеграционным экспериментом.

Утром система стартует и прогревается. Затем растёт OLTP load. В течение дня появляются checkpoints, autovacuum, logs, analytical jobs, index/DDL maintenance, WAL, replication and ETL. Иногда возникает short stall. К вечеру надо ответить не «какой был средний TPS», а:

- сколько обязательных business/SLA transactions пришло;
- сколько завершено вовремя;
- сколько осталось в backlog;
- какой p95/p99 и сколько SLA misses;
- какой vacuum/freeze debt остался;
- какой WAL/archive/replication debt остался;
- догнали ли ETL/search/warehouse;
- закончен ли backup;
- остался ли достаточный headroom для следующего дня.

**Главный business-performance metric:**

> система должна завершить требуемую работу за операционный день, сохранив обещанные SLA и не оставив после себя неограниченно растущий operational debt.

---

# 12 якорных глав, которые естественно возникают из карты

Это уже ближе к будущему оглавлению, но пока не финальное.

1. **Так сколько это работает?** — measurement, psql, amplification, tails.
2. **Одна секунда затыка** — queueing, headroom, debt, operational day.
3. **Система помнит прошлое** — warm-up, caches, accumulated state.
4. **Почему удалённые строки продолжают жить** — MVCC, vacuum, freeze, bloat.
5. **Почему COMMIT не ждёт всю запись** — WAL, checkpoints, I/O.
6. **Почему большой сервер не обязательно быстрее** — NUMA, processes, threads, contention, AIO.
7. **Почему все стоят** — locks, DDL, queues, connection model.
8. **Почему planner не знает очевидного** — statistics, generic/custom, executor boundaries.
9. **PostgreSQL как платформа** — FTS, extensions, data semantics, external boundaries.
10. **Истина и её копии** — replication, ETL, search, balances, HTAP.
11. **Когда всё меняется на живой системе** — online maintenance, REPACK, upgrade, security.
12. **Рабочий день PostgreSQL** — integrated workload, incidents, capacity, recovery, automation.

---

# Семь эволюционных линий «Прояснения PostgreSQL»

Каждая линия должна появляться несколько раз, а не жить в отдельной исторической главе.

## A. Stop-the-world → online

Ordinary vacuum concurrency → `CREATE INDEX CONCURRENTLY` → weaker DDL locks → no-rewrite DDL → `REINDEX CONCURRENTLY` → `REPACK CONCURRENTLY`.

**Урок:** online operation обычно не удаляет стоимость; она переводит её из blocking в extra work, duration, catch-up, WAL or temporary space.

## B. Invisible → attributable

Logs → statement statistics → wait information → progress views → `pg_stat_io` → per-backend I/O/WAL → richer lock/recovery/autovacuum views.

**Урок:** зрелая operational system должна отвечать не только «что случилось», но и «какой механизм сейчас создаёт работу и почему».

## C. MVCC debt → smarter service

VACUUM → autovacuum → HOT → visibility map → parallel index vacuum → failsafe → memory improvements → prioritization.

**Урок:** maintenance debt is inherent to the concurrency model; evolution reduces its service cost.

## D. One giant privilege → capabilities

Users/groups → roles → RLS → SCRAM → predefined roles → safer schema defaults → `MAINTAIN` → external identity/OAuth.

**Урок:** operational security evolves by reducing the blast radius of routine capabilities.

## E. Core database → extensible platform

contrib/custom types → extension packaging → dynamic workers/shared memory → trusted extensions.

**Урок:** new semantics do not automatically require core changes or an external service.

## F. One machine assumption → modern hardware

buffer-lock contention → multi-socket fixes/atomics → parallel query → streaming I/O → AIO.

**Урок:** hardware changes reveal old abstraction costs; folklore must be re-measured.

## G. One copy of data → truth plus derived systems

PITR/standby → streaming replication → logical decoding → logical replication → richer consistency/failover controls.

**Урок:** copies create new contracts: freshness, ordering, consistency, retention, rebuild and authority.

---

# Что брать из DBA1–DBA3

Не переносить курс по порядку. Использовать его как **банк доказательств**.

Для каждого подходящего практикума задавать четыре вопроса:

1. Какую реальную production-ситуацию он моделирует?
2. Какой механизм он позволяет увидеть своими глазами?
3. Какой debt/invariant можно измерить, а не просто показать?
4. Как превратить упражнение из «выполните команду» в causal experiment?

Приоритетные кандидаты:

- activity/waits and monitoring;
- vacuum/autovacuum/freeze;
- buffer cache;
- WAL/checkpoints;
- object/row locks;
- backup/PITR;
- physical replication;
- switchover/failover;
- upgrade.

---

# Что обязательно требует нашей собственной археологии

Release notes недостаточно.

## 1. Executor / `ExecProcNode`

Нужен source lineage, который мы уже начали: ранний POSTGRES → нынешний executor boundary → почему простое «это Volcano» исторически неверно → где сегодня цена tuple-at-a-time.

## 2. Processes vs threads

Нужны старые architectural discussions, OS evolution и современные измерения. Не превращать в идеологию.

## 3. NUMA

Нужна история наших неудачных/удачных workloads и связь с реальными multi-socket fixes в core.

## 4. FTS

Нужна не только история интеграции `tsearch2`, но и реальная мотивация in-database search: transaction/snapshot/security/JOIN boundary и собственный опыт разработки.

## 5. Extensibility

GiST/FTS/hstore/jsonb, custom types and index semantics; различать «что естественно extension» и «когда boundary core всё-таки недостаточна».

## 6. Security / separation of duties

Нужна точная история Postgres Pro contributions и distinction OS `postgres` vs database superuser.

## 7. Logging failure story

Восстановить конкретную causal chain prepared transactions → log volume → transport capacity → service failure.

---

# Критерий включения материала в книгу

Фича или исторический эпизод попадает в основной текст только если есть все три элемента:

1. **реальная боль работающей системы;**
2. **архитектурный компромисс PostgreSQL, который эта история проясняет;**
3. **практический эксперимент, invariant или production decision, который читатель сможет применить сегодня.**

Если остаётся только «интересно знать», материал уходит в примечание или архив.

---

# Критерий хорошей главы

Если убрать слово PostgreSQL и главу можно почти без изменений вставить в generic DBA handbook — глава ещё не готова.

Хорошая глава должна отвечать:

- Что странного увидел практик?
- Как это воспроизвести?
- Какой механизм PostgreSQL это объясняет?
- Почему этот механизм появился?
- Что в окружающем мире с тех пор изменилось?
- Что в старом решении остаётся фундаментальным?
- Какой debt/invariant отсюда следует?
- Что делать сегодня?
- Как доказать, что система вернулась в устойчивое состояние?

---

# Следующий исследовательский проход

Для 10–12 якорных историй:

```text
release note
    ↓
commit(s)
    ↓
pgsql-hackers discussion
    ↓
source before
    ↓
source after
    ↓
benchmark / motivating workload
    ↓
что из предположений всё ещё верно на PG19
    ↓
наш reproducible experiment
    ↓
chapter
```

Первый приоритет для такой глубокой археологии:

1. checkpoint smoothing / tails;
2. VACUUM → HOT → VM → PG19 autovacuum;
3. multi-socket/NUMA scalability;
4. process vs thread boundary;
5. FTS inside PostgreSQL;
6. extension boundary;
7. executor / tuple-at-a-time;
8. replication lag and consistency;
9. online maintenance;
10. observability/logging capacity;
11. warm-up;
12. statistics/planner state across upgrades.


\newpage

# Приложение: release notes как археологический индекс проблем

Это не «что нового было в PostgreSQL». Это подсказка, куда идти дальше в commits/hackers/source, когда нам нужна история конкретной production-боли.

| Release | Что особенно интересно | Какую боль проясняет |
|---|---|---|
| 7.1 | WAL | почему COMMIT не обязан синхронно записать все data pages; durability debt переносится из critical path |
| 7.3 | prepared queries, schemas/dependencies | reuse planning; object namespace/dependency становится частью управляемого state |
| 7.4 | early autovacuum tooling | человек/cron уже плохо справляется с неизбежным MVCC maintenance |
| 8.0 | PITR, background writer, vacuum cost delay | recovery как история; background work interfering with foreground |
| 8.1 | integrated autovacuum, shared buffer locking work, roles, 2PC | maintenance становится server responsibility; SMP contention; privilege model; durable prepared state |
| 8.2 | `CREATE INDEX CONCURRENTLY`, fillfactor | stop-the-world index build неприемлем; иногда полезно заранее оставить физический запас |
| 8.3 | HOT, checkpoint spreading, async commit, synchronized scans, FTS | update/index debt; tails от write bursts; durability trade-off; cache interference; search boundary |
| 8.4 | visibility map, automatic FSM, `pg_stat_statements`, `auto_explain` | metadata позволяет не делать лишнюю работу; observability переходит от logs к attribution |
| 9.0 | streaming replication, hot standby, `EXPLAIN BUFFERS` | уменьшаем replication lag granularity; reads на copy; видим buffer work |
| 9.1 | synchronous replication, `CREATE EXTENSION`, foreign tables, unlogged tables | durability vs latency; operational packaging extensibility; external data boundary; crash safety trade-off |
| 9.2 | index-only scan, custom/generic plan improvements, checkpointer split | MVCC ограничивает seemingly obvious optimization; parameter-sensitive planning; разные background control loops |
| 9.3 | checksums, materialized views | data correctness; derived state внутри PostgreSQL |
| 9.4 | logical decoding, dynamic workers/DSM, `pg_prewarm`, concurrent matview refresh | change stream наружу; расширение server boundary; warm-up; online refresh |
| 9.5 | BRIN, RLS, `SKIP LOCKED`, `pg_rewind`, multi-CPU work | огромные correlated tables; security closer to data; database queues; divergent histories; SMP scaling |
| 9.6 | parallel query, multi-socket scaling, richer waits, phrase FTS | modern CPU scaling; observability waits; analytics; search semantics |
| 10 | logical replication, declarative partitioning, SCRAM, quorum sync | selective derived copies; lifecycle huge tables; auth evolution; availability/durability trade-off |
| 11 | ADD COLUMN DEFAULT without rewrite, JIT, covering indexes, narrower privileged roles | DDL physical work can disappear without SQL change; CPU expression cost; capability decomposition |
| 12 | `REINDEX CONCURRENTLY`, progress views, log transaction sampling | online maintenance; long operations become observable; logs need sampling |
| 13 | B-tree dedup, parallel index vacuum, trusted extensions | index version churn; maintenance service rate; extension security boundary |
| 14 | concurrency scaling, libpq pipeline, smarter B-tree cleanup/vacuum failsafe | client/server round trips; index debt prevention; safety debt outranks optimization |
| 15 | JSON logs, stats in shared memory, default checkpoint/slow-vacuum logging, safer `public` schema | structured observability; logging has resource cost; safer defaults |
| 16 | `pg_stat_io`, logical decoding on standby, parallel logical apply | attribute I/O to PostgreSQL mechanisms; CDC topology; apply capacity |
| 17 | VACUUM memory redesign, incremental backup, logical failover slots, `MAINTAIN` | maintenance representation itself matters; recovery work reduction; derived-stream continuity; least privilege |
| 18 | AIO, per-backend I/O/WAL, optimizer stats preserved by `pg_upgrade`, OAuth | hardware assumptions changed; attribution; performance knowledge is state; identity boundary |
| 19 beta | `REPACK CONCURRENTLY`, autovacuum scoring/parallelism, online checksums, `WAIT FOR LSN`, `pg_plan_advice`, richer lock/recovery views | online rewrite as catch-up queue; explicit maintenance priority; read-your-writes; plan stabilization; invisible → attributable |

## Как пользоваться индексом

Берём строку, но не пишем по ней книгу.

Например:

```text
PG11: ADD COLUMN DEFAULT without rewrite
```

Плохой текст:

> Начиная с PostgreSQL 11 ADD COLUMN с constant default не переписывает таблицу.

Хорошая раскопка:

> Почему одна строка DDL раньше могла часами переписывать multi-terabyte table? Как PostgreSQL смог сохранить SQL semantics, перестав физически записывать одно и то же значение в каждую старую tuple? Что это говорит нам о difference между logical schema change и physical work?

И потом:

```text
release note
  ↓
commit
  ↓
hackers motivation
  ↓
source before/after
  ↓
reproducible workload
  ↓
PG19 behavior
  ↓
production decision
```

Именно так release notes становятся не хронологией, а картой вопросов.

## Приоритет следующего source-level прохода

1. Process model: ранний POSTGRES → fork/backend architecture → что реально осталось дорогим сегодня.
2. Buffer manager: old shared-locking bottlenecks → partitioning/atomics → modern AIO/NUMA.
3. HOT/pruning: где именно foreground repays MVCC debt.
4. Visibility map: от VACUUM optimization к index-only scan и all-frozen evolution.
5. FTS: ранние Rambler/SAI задачи → tsearch/tsearch2 → core integration → external-search boundary.
6. Extension lifecycle: contrib scripts → `CREATE EXTENSION` → trusted/background-worker boundary.
7. Executor: `ExecProcNode` lineage → slot representation → current batching patches.
8. Lock observability: from wait debugging to current PG19 views.
9. Planner knowledge: statistics evolution → preserved stats → advice.
10. Failover continuity: timelines/rewind → slots/subscriptions continuity.


