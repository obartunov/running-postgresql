# Реестр версионно-зависимых утверждений

Назначение: сделать проверку перед печатью механической. Здесь не
доказательства, а checklist — что именно надо сверить, где и по чему.

Целевая версия книги — PostgreSQL 19; на 6 сентября 2026 она в статусе
Beta 3.

Статусы:

- `timeless` — механизм не зависит от версии; сверять не нужно, но
  формулировка не должна незаметно стать версионной;
- `versioned` — верно начиная с указанной версии; сверить по release
  notes или коммиту;
- `beta/dev` — относится к PostgreSQL 19 и подлежит пересверке после GA.

`Evidence` заполняется честно: `not recorded` означает, что источник не
записывался, а не что его нет. `Experiment` заполняется только если
собственный стенд действительно проверяет это утверждение, а не просто
находится рядом.

Список полей у каждой записи одинаков, чтобы `tools/check-experiments.py`
мог его разобрать.

Сводка: всего записей — 65, из них к пересверке перед печатью — 35.

---

## VC-001

Chapter / section: Перед стартом
Claim: timing_clock_source, default auto, на подходящих x86-64 может использовать TSC
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-002

Chapter / section: гл. 2
Claim: обычное сканирование может само пометить страницу как all-visible
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-003

Chapter / section: Интермеццо CONCURRENTLY
Claim: REPACK CONCURRENTLY: изменения ловятся logical decoding и применяются перед swap
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: беглая проверка 2026-09-05 (существование команды в 19)
Recheck before print: yes

## VC-004

Chapter / section: гл. 8
Claim: pg_upgrade переносит большую часть optimizer statistics; CREATE STATISTICS и cumulative statistics — нет
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18
- source / commit: not recorded
- experiment: ch08-upgrade-window (косвенно)

Last verified: 2026-09-05
Recheck before print: yes

## VC-005

Chapter / section: гл. 8
Claim: JIT выключен по умолчанию
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-006

Chapter / section: гл. 8
Claim: pg_plan_advice
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-007

Chapter / section: гл. 15
Claim: WAIT FOR LSN
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-008

Chapter / section: гл. 1
Claim: checkpoint_completion_target по умолчанию 0.9
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: release notes 14
- source / commit: not recorded
- experiment: ch01-checkpoint (значение видно в settings.txt)

Last verified: 2026-09-05
Recheck before print: no

## VC-009

Chapter / section: гл. 1
Claim: pg_stat_checkpointer отделён от pg_stat_bgwriter
PostgreSQL version: 17
Status: versioned
Evidence:
- documentation: release notes 17
- source / commit: not recorded
- experiment: ch01-checkpoint (ветка в collect.sql)

Last verified: 2026-09-05
Recheck before print: no

## VC-010

Chapter / section: гл. 1
Claim: WAL в pg_stat_io; num_done у чекпойнтера
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-011

Chapter / section: гл. 4
Claim: hash_mem_multiplier по умолчанию 2.0
PostgreSQL version: 15
Status: versioned
Evidence:
- documentation: release notes 15, commit 8f388f6f
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-012

Chapter / section: гл. 4
Claim: хеш-агрегация умеет сбрасывать на диск
PostgreSQL version: 13
Status: versioned
Evidence:
- documentation: release notes 13
- source / commit: not recorded
- experiment: ch04-work-mem (Batches>1 при 4MB)

Last verified: 2026-09-05
Recheck before print: no

## VC-013

Chapter / section: гл. 8
Claim: CREATE STATISTICS: ndistinct, dependencies
PostgreSQL version: 10
Status: versioned
Evidence:
- documentation: документация 10
- source / commit: not recorded
- experiment: ch08-estimates

Last verified: 2026-09-05
Recheck before print: no

## VC-014

Chapter / section: гл. 8
Claim: CREATE STATISTICS: mcv
PostgreSQL version: 12
Status: versioned
Evidence:
- documentation: документация 12
- source / commit: not recorded
- experiment: ch08-estimates

Last verified: 2026-09-05
Recheck before print: no

## VC-015

Chapter / section: гл. 8
Claim: статистика по выражениям
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: release notes 14
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-016

Chapter / section: гл. 3 / Интермеццо CONCURRENTLY
Claim: SET NOT NULL без сканирования при валидном CHECK
PostgreSQL version: 12
Status: versioned
Evidence:
- documentation: release notes 12
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-017

Chapter / section: гл. 7
Claim: DETACH PARTITION CONCURRENTLY
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: документация 14
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-018

Chapter / section: гл. 3
Claim: NOT NULL ... NOT VALID
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-019

Chapter / section: гл. 2 / Интермеццо
Claim: REPACK / REPACK CONCURRENTLY
PostgreSQL version: 19
Status: beta/dev
Evidence:
- documentation: release notes 19 (beta)
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05 (только факт наличия в 19)
Recheck before print: yes

## VC-020

Chapter / section: гл. 7
Claim: автовакуум не выполняет ANALYZE секционированной таблицы
PostgreSQL version: все
Status: timeless
Evidence:
- documentation: документация (раздел про автовакуум)
- source / commit: not recorded
- experiment: нет — утверждение не проверялось на стенде

Last verified: 2026-09-05
Recheck before print: no

## VC-021

Chapter / section: гл. 7
Claim: ANALYZE ONLY
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-022

Chapter / section: гл. 7
Claim: внешние ключи, ссылающиеся на секционированную таблицу
PostgreSQL version: 12
Status: versioned
Evidence:
- documentation: release notes 12
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-023

Chapter / section: гл. 6
Claim: переработка снимков MVCC для масштабируемости по числу соединений
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: release notes 14 (Andres Freund)
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-024

Chapter / section: гл. 6
Claim: PgBouncer: подготовленные запросы в transaction pooling, только протокольные, при max_prepared_statements > 0
PostgreSQL version: PgBouncer 1.21
Status: versioned
Evidence:
- documentation: changelog PgBouncer 1.21
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-025

Chapter / section: гл. 15
Claim: recovery_prefetch
PostgreSQL version: 15
Status: versioned
Evidence:
- documentation: release notes 15 (Thomas Munro)
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-026

Chapter / section: гл. 15
Claim: max_slot_wal_keep_size
PostgreSQL version: 13
Status: versioned
Evidence:
- documentation: release notes 13
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-027

Chapter / section: гл. 16
Claim: pg_verifybackup
PostgreSQL version: 13
Status: versioned
Evidence:
- documentation: release notes 13
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-028

Chapter / section: гл. 16
Claim: инкрементальные копии: pg_basebackup --incremental, pg_combinebackup, summarize_wal
PostgreSQL version: 17
Status: versioned
Evidence:
- documentation: release notes 17 (Robert Haas)
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-029

Chapter / section: гл. 16
Claim: pg_amcheck
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: release notes 14
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-030

Chapter / section: drafts/r2d2-expanded/02a (не canonical)
Claim: last_idx_scan, last_seq_scan, n_tup_newpage_upd
PostgreSQL version: 16
Status: versioned
Evidence:
- documentation: release notes 16
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-031

Chapter / section: приложение release notes / drafts/r2d2-expanded/02a
Claim: дедупликация B-tree
PostgreSQL version: 13
Status: versioned
Evidence:
- documentation: release notes 13
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-032

Chapter / section: drafts/r2d2-expanded/02a (не canonical)
Claim: удаление устаревших версий при заполнении страницы (bottom-up index deletion)
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: release notes 14
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-033

Chapter / section: гл. 15
Claim: счётчики конфликтов в pg_stat_subscription_stats; parallel streaming по умолчанию
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-034

Chapter / section: гл. 2
Claim: TidStore для VACUUM, снят потолок maintenance_work_mem в 1 GB
PostgreSQL version: 17
Status: versioned
Evidence:
- documentation: release notes 17
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-035

Chapter / section: drafts/r2d2-expanded/13a (не canonical)
Claim: для кластеров не на libc после обновления рекомендовано перестроить FTS и pg_trgm индексы
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05
Recheck before print: no

## VC-036

Chapter / section: гл. 1
Claim: размазывание чекпойнта и checkpoint_completion_target
PostgreSQL version: 8.3
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-037

Chapter / section: гл. 1
Claim: чекпойнтер выделен в отдельный процесс
PostgreSQL version: 9.2
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-038

Chapter / section: гл. 1
Claim: max_wal_size вместо checkpoint_segments; wal_compression
PostgreSQL version: 9.5
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-039

Chapter / section: гл. 1
Claim: упорядоченная запись при чекпойнте, checkpoint_flush_after
PostgreSQL version: 9.6
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-040

Chapter / section: гл. 1
Claim: log_checkpoints включён по умолчанию
PostgreSQL version: 15
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-041

Chapter / section: Интермеццо CONCURRENTLY
Claim: CREATE INDEX CONCURRENTLY
PostgreSQL version: 8.2
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-042

Chapter / section: гл. 3
Claim: pg_blocking_pids()
PostgreSQL version: 9.6
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: ch03-lock-queue (функция работает в 16)

Last verified: not verified для версии появления
Recheck before print: yes

## VC-043

Chapter / section: гл. 3
Claim: быстрый ADD COLUMN с константным DEFAULT без rewrite
PostgreSQL version: 11
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-044

Chapter / section: Интермеццо CONCURRENTLY
Claim: REINDEX CONCURRENTLY
PostgreSQL version: 12
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: ch02-index-bloat (команда работает в 16)

Last verified: not verified для версии появления
Recheck before print: yes

## VC-045

Chapter / section: гл. 2
Claim: autovacuum внутри сервера / включён по умолчанию
PostgreSQL version: 8.1 / 8.3
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-046

Chapter / section: гл. 2
Claim: HOT
PostgreSQL version: 8.3
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: ch02-index-bloat (механизм наблюдается в 16)

Last verified: not verified для версии появления
Recheck before print: yes

## VC-047

Chapter / section: гл. 2
Claim: visibility map
PostgreSQL version: 8.4
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-048

Chapter / section: гл. 2
Claim: карта заморозки (all-frozen bit)
PostgreSQL version: 9.6
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-049

Chapter / section: гл. 2
Claim: autovacuum по вставкам (autovacuum_vacuum_insert_threshold)
PostgreSQL version: 13
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-050

Chapter / section: гл. 2
Claim: vacuum_failsafe_age
PostgreSQL version: 14
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-051

Chapter / section: гл. 2
Claim: autovacuum_vacuum_cost_delay по умолчанию 2 мс
PostgreSQL version: 12
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-052

Chapter / section: гл. 11
Claim: доверенные расширения (trusted extensions)
PostgreSQL version: 13
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-053

Chapter / section: гл. 15
Claim: disable_on_error у подписки
PostgreSQL version: 15
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-054

Chapter / section: гл. 15
Claim: pg_createsubscriber
PostgreSQL version: 17
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-055

Chapter / section: гл. 2 / 3 / 6
Claim: transaction_timeout
PostgreSQL version: 17
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-056

Chapter / section: гл. 15
Claim: idle_replication_slot_timeout
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: not recorded
- source / commit: not recorded
- experiment: нет

Last verified: not verified
Recheck before print: yes

## VC-057

Chapter / section: гл. 2
Claim: autovacuum_vacuum_max_threshold, vacuum_max_eager_freeze_failure_rate, vacuum_truncate
PostgreSQL version: 18
Status: versioned
Evidence:
- documentation: release notes 18 (беглая проверка)
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-05 бегло
Recheck before print: yes

## VC-058

Chapter / section: гл. 2
Claim: VACUUM не возвращает место файловой системе, только делает его reusable
PostgreSQL version: все
Status: timeless
Evidence:
- documentation: документация
- source / commit: not recorded
- experiment: ch07-partitions (419 MB после VACUUM)

Last verified: 2026-09-06
Recheck before print: no

## VC-059

Chapter / section: гл. 3
Claim: ожидающий несовместимый lock блокирует пришедших позже; hard и soft blocker в pg_blocking_pids()
PostgreSQL version: все
Status: timeless
Evidence:
- documentation: документация pg_blocking_pids
- source / commit: not recorded
- experiment: ch03-lock-queue

Last verified: 2026-09-06
Recheck before print: no

## VC-060

Chapter / section: гл. 15
Claim: при hot_standby_feedback и replication slot pg_stat_replication.backend_xmin может быть NULL; horizon показывается в pg_replication_slots.xmin
PostgreSQL version: 19 beta (целевая версия; дата появления поведения не устанавливается)
Status: beta/dev
Evidence:
- documentation: https://www.postgresql.org/docs/19/monitoring-stats.html (backend_xmin прямо описан как NULL при использовании replication slot)
- source / commit: not recorded
- experiment: ch15-standby (backend_xmin = NULL, slot xmin = 757)

Last verified: 2026-09-06 по документации 19 Beta 3 и стенду
Recheck before print: yes
## VC-061

Chapter / section: интермеццо «Проклятие удобной абстракции»
Claim: TOAST включается примерно после 2 kB row width; unchanged out-of-line fields при UPDATE обычно сохраняются без повторной TOAST work
PostgreSQL version: 19 beta (целевая версия)
Status: beta/dev
Evidence:
- documentation: https://www.postgresql.org/docs/19/storage-toast.html
- source / commit: not recorded
- experiment: нет; JSONB threshold stand в тексте пока только предложен

Last verified: 2026-09-06 по документации 19 Beta 3
Recheck before print: yes

## VC-062

Chapter / section: гл. 9 / интермеццо про временную архитектуру
Claim: current pg_duckdb поддерживает CREATE TABLE ... USING duckdb и может передавать analytical execution DuckDB engine (например через duckdb.force_execution)
PostgreSQL version: external project pg_duckdb, current main 2026-09-06
Status: versioned
Evidence:
- documentation: https://github.com/duckdb/pg_duckdb ; docs/gotchas_and_syntax.md
- source / commit: not pinned
- experiment: нет

Last verified: 2026-09-06 по upstream README/docs
Recheck before print: yes

## VC-063

Chapter / section: гл. 9 / интермеццо про временную архитектуру
Claim: current pg_clickhouse является PostgreSQL extension/FDW для query pushdown в ClickHouse; pushdown coverage неполна и является развиваемой частью проекта
PostgreSQL version: external project pg_clickhouse, current main 2026-09-06
Status: versioned
Evidence:
- documentation: https://github.com/ClickHouse/pg_clickhouse
- source / commit: not pinned
- experiment: нет

Last verified: 2026-09-06 по upstream README/roadmap
Recheck before print: yes

## VC-064

Chapter / section: гл. 18, queueing network
Claim: PostgreSQL 19 различает Buffer wait type, LWLock BufferMapping и IPC BufferIo как разные wait points на пути к buffer/page
PostgreSQL version: 19 beta
Status: beta/dev
Evidence:
- documentation: https://www.postgresql.org/docs/19/monitoring-stats.html
- source / commit: not recorded
- experiment: нет

Last verified: 2026-09-06 по документации 19 Beta 3
Recheck before print: yes

## VC-065

Chapter / section: гл. 16, archive_command
Claim: archive_command должен возвращать success только после успешного архивирования; pre-existing WAL file допустим как success только при идентичном полностью сохранённом содержимом
PostgreSQL version: current documented contract (проверено на 19 beta)
Status: timeless
Evidence:
- documentation: https://www.postgresql.org/docs/19/continuous-archiving.html ; https://www.postgresql.org/docs/19/runtime-config-wal.html
- source / commit: not recorded
- experiment: ch16-restore (interrupted direct cp оставил partial final file)

Last verified: 2026-09-06 по документации 19 Beta 3 и стенду
Recheck before print: no

---

## Приложение с release notes

Приложение «Release notes как археологическая карта болей» содержит
десятки версионных утверждений от 7.1 до 19, не разложенных в этот
реестр поштучно. Оно требует отдельного прохода: каждая строка получает
ссылку на release notes соответствующей версии либо на коммит.

Это единственная часть книги, которую рецензент будет сверять
построчно.

Отдельный риск в приложении — не даты, а объём заявлений. Формулировки
вида «в версии N появился X» бывают верны по дате и слишком широки по
содержанию (например, parallel query в 9.6 появился не для всех узлов).
Проверять надо оба измерения.

Recheck before print: yes (весь раздел)
