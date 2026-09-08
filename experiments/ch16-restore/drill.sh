#!/bin/bash
# Учения с секундомером: RTO по участкам на маленьком масштабе.
#
#   ./drill.sh          # немного WAL после копии
#   ./drill.sh heavy    # много WAL после копии
#   ./drill.sh clean    # удалить всё
#
# Всё живёт в BASE (по умолчанию /tmp/ch09). Основную установку не
# трогает.
set -euo pipefail

BASE=${BASE:-/tmp/ch09}
SRC="$BASE/src"; BACKUP="$BASE/backup"; ARCHIVE="$BASE/archive"
DST="$BASE/restored"
PORT=${PORT:-55442}; RPORT=${RPORT:-55443}
MODE="${1:-light}"
SCALE=${SCALE:-50}

if [ "$MODE" = "clean" ]; then
  pg_ctl -D "$DST" -m immediate stop 2>/dev/null || true
  pg_ctl -D "$SRC" -m immediate stop 2>/dev/null || true
  rm -rf "$BASE"; echo "очищено"; exit 0
fi

t() { date +%s.%N; }
el() { echo "scale=1; $2 - $1" | bc; }

rm -rf "$BASE"; mkdir -p "$BASE" "$ARCHIVE"
mkdir -p results

# --- исходный кластер --------------------------------------------------
initdb -D "$SRC" -U "$USER" --no-sync > "$BASE/initdb.log"
cat >> "$SRC/postgresql.conf" <<EOF
port = $PORT
wal_level = replica
archive_mode = on
# Копирование в архив ДОЛЖНО быть атомарным: если сервер умрёт посреди
# cp, в архиве останется обрезанный сегмент, и восстановление на нём
# упадёт с 'archive file has wrong size'. Пишем во временное имя и
# переименовываем - mv в пределах файловой системы атомарен.
archive_command = 'test ! -f $ARCHIVE/%f && cp %p $ARCHIVE/%f.tmp && mv $ARCHIVE/%f.tmp $ARCHIVE/%f'
max_wal_size = 2GB
unix_socket_directories = '$BASE'
listen_addresses = 'localhost'
EOF
pg_ctl -D "$SRC" -l "$BASE/src.log" start
pgbench -h 127.0.0.1 -p "$PORT" -i -s "$SCALE" postgres > /dev/null 2>&1

# --- участок 1: снятие копии ------------------------------------------
T0=$(t)
pg_basebackup -h 127.0.0.1 -p "$PORT" -D "$BACKUP" -X stream -c fast
T1=$(t)
BACKUP_SIZE=$(du -sh "$BACKUP" | cut -f1)

# --- нагрузка после копии = WAL, который придётся проигрывать ----------
case "$MODE" in
  light) DUR=30  ; CLIENTS=4  ;;
  heavy) DUR=180 ; CLIENTS=16 ;;
esac
LSN0=$(psql -X -At -h 127.0.0.1 -p "$PORT" -d postgres -c "SELECT pg_current_wal_lsn()")
pgbench -h 127.0.0.1 -p "$PORT" -c "$CLIENTS" -j 4 -T "$DUR" -n postgres > /dev/null 2>&1
LSN1=$(psql -X -At -h 127.0.0.1 -p "$PORT" -d postgres -c "SELECT pg_current_wal_lsn()")
WAL_MADE=$(psql -X -At -h 127.0.0.1 -p "$PORT" -d postgres -c \
  "SELECT pg_size_pretty(pg_wal_lsn_diff('$LSN1','$LSN0'))")
psql -X -q -h 127.0.0.1 -p "$PORT" -d postgres -c "SELECT pg_switch_wal()" > /dev/null

# --- авария ------------------------------------------------------------
pg_ctl -D "$SRC" -m immediate stop > /dev/null

# --- участок 2: развёртывание копии ------------------------------------
T2=$(t)
cp -a "$BACKUP" "$DST"
T3=$(t)

cat >> "$DST/postgresql.conf" <<EOF
port = $RPORT
restore_command = 'cp $ARCHIVE/%f %p'
unix_socket_directories = '$BASE'
EOF
touch "$DST/recovery.signal"

# --- участок 3: старт и проигрывание -----------------------------------
# ВАЖНО: сервер начинает принимать соединения, как только достигнута
# согласованность, - то есть ЗАДОЛГО до конца проигрывания. Меряем оба
# момента: когда отвечает и когда восстановление действительно
# закончилось (pg_is_in_recovery() = false).
T4=$(t)
pg_ctl -D "$DST" -l "$BASE/restored.log" start > /dev/null
until psql -X -At -h 127.0.0.1 -p "$RPORT" -d postgres -c "SELECT 1" >/dev/null 2>&1; do
  sleep 0.2
done
T4B=$(t)
WAITED=0
until [ "$(psql -X -At -h 127.0.0.1 -p "$RPORT" -d postgres \
            -c 'SELECT pg_is_in_recovery()' 2>/dev/null)" = "f" ]; do
  sleep 0.5; WAITED=$((WAITED+1))
  if [ $WAITED -gt 1200 ]; then
    echo "восстановление не завершилось за 10 минут; смотрите $BASE/restored.log" >&2
    tail -5 "$BASE/restored.log" >&2
    exit 1
  fi
  if ! pg_ctl -D "$DST" status > /dev/null 2>&1; then
    echo "сервер восстановления упал; последние строки лога:" >&2
    tail -5 "$BASE/restored.log" >&2
    exit 1
  fi
done
T5=$(t)

# --- участок 4: первый запрос по холодному кэшу ------------------------
T6=$(t)
psql -X -q -h 127.0.0.1 -p "$RPORT" -d postgres \
  -c "SELECT count(*) FROM pgbench_accounts" > /dev/null
T7=$(t)
# второй раз, уже по прогретому
T8=$(t)
psql -X -q -h 127.0.0.1 -p "$RPORT" -d postgres \
  -c "SELECT count(*) FROM pgbench_accounts" > /dev/null
T9=$(t)

{
  echo "режим:              $MODE"
  echo "размер копии:       $BACKUP_SIZE"
  echo "WAL после копии:    $WAL_MADE"
  echo
  printf 'снятие копии:            %6s с\n' "$(el $T0 $T1)"
  printf 'развёртывание:           %6s с\n' "$(el $T2 $T3)"
  printf 'старт до первого ответа: %6s с\n' "$(el $T4 $T4B)"
  printf 'до КОНЦА проигрывания:   %6s с\n' "$(el $T4 $T5)"
  printf 'первый запрос (холодный):%6s с\n' "$(el $T6 $T7)"
  printf 'тот же запрос (тёплый):  %6s с\n' "$(el $T8 $T9)"
  echo
  printf 'RTO (развёртывание + проигрывание + прогрев): %s с\n' \
    "$(echo "scale=1; ($T5-$T2)+($T7-$T6)" | bc)"
} | tee "results/drill-$MODE.txt"

grep -E 'redo|consistent recovery|starting point-in-time|database system is ready' \
  "$BASE/restored.log" | tail -5

cat <<TXT

Кластеры оставлены запущенными для осмотра:
  исходный (остановлен): $SRC
  восстановленный:       порт $RPORT, каталог $DST
Удалить всё: ./drill.sh clean
TXT
