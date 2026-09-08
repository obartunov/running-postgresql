#!/usr/bin/env python3
"""Тень очереди: p99 по окнам, наложенная на моменты чекпойнтов.

  shadow.py <префикс лога pgbench> <лог сервера> [окно, с]

Выводит по строке на окно: время от начала прогона, число транзакций,
p50/p99, и пометку CKPT в окне, где начался чекпойнт. В конце - оценка
длины тени: сколько окон подряд после начала чекпойнта p99 держится
выше фонового уровня.
"""
import sys, glob, re, statistics, datetime
from collections import defaultdict

log_prefix, server_log = sys.argv[1], sys.argv[2]
W = int(sys.argv[3]) if len(sys.argv) > 3 else 10

buckets = defaultdict(list)
for path in sorted(glob.glob(log_prefix + "*")):
    for line in open(path):
        f = line.split()
        if len(f) < 6:
            continue
        try:
            lat, epoch = float(f[2]) / 1000.0, int(f[4])
        except ValueError:
            continue
        buckets[epoch - epoch % W].append(lat)
if not buckets:
    sys.exit("нет данных pgbench по маске " + log_prefix + "*")

# моменты 'checkpoint starting' из лога сервера
ckpt = []
pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ \w+ .*checkpoint starting: (\w+)")
for line in open(server_log, errors="replace"):
    m = pat.match(line)
    if m:
        t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        ckpt.append((int(t.replace(tzinfo=datetime.timezone.utc).timestamp()),
                     m.group(2)))

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))]

start = min(buckets)
ckpt_windows = {e - e % W: kind for e, kind in ckpt if start <= e <= max(buckets)}

rows = []
print("t,c\tn\tp50_ms\tp99_ms\tметка")
for e in sorted(buckets):
    xs = buckets[e]
    p50, p99 = statistics.median(xs), pct(xs, 0.99)
    mark = "CKPT " + ckpt_windows[e] if e in ckpt_windows else ""
    rows.append((e, p99))
    print(f"{e-start}\t{len(xs)}\t{p50:.2f}\t{p99:.2f}\t{mark}")

# Фон и всплески. Важно: при размазанном чекпойнте боль приходится не
# на окно старта, а на середину фазы записи, поэтому считается смещение
# всплеска от ближайшего предыдущего старта чекпойнта, а не только
# соседние окна.
quiet = [p for e, p in rows if e not in ckpt_windows]
if quiet:
    base = statistics.median(quiet)
    print(f"\n# фоновый p99 (медиана по окнам без чекпойнта): {base:.2f} ms",
          file=sys.stderr)
    starts = sorted(ckpt_windows)
    spikes = [(e, p) for e, p in rows if p > 5 * base and e != min(buckets)]
    if not spikes:
        print("# всплесков выше 5x фона нет: на этих данных чекпойнт "
              "тени не отбрасывает", file=sys.stderr)
    for e, p in spikes:
        prev = [c for c in starts if c <= e]
        off = f"+{e - prev[-1]}s от старта чекпойнта" if prev else "до первого чекпойнта"
        print(f"# всплеск t={e-start}s: p99 {p:.1f} ms ({p/base:.0f}x фона), {off}",
              file=sys.stderr)
