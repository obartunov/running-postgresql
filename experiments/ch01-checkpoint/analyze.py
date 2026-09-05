#!/usr/bin/env python3
"""Перцентили задержки по окнам из сырого лога pgbench (-l).

Формат строки pgbench: client_id transaction_no time script_no
time_epoch time_us [...]. Поле time — задержка в микросекундах.

Вывод: одна строка на окно — epoch, число транзакций, p50, p95, p99, max
(миллисекунды). Наложите на моменты 'checkpoint starting' из лога
сервера, чтобы увидеть форму зубца.
"""
import sys, glob, statistics
from collections import defaultdict

WINDOW = int(sys.argv[2]) if len(sys.argv) > 2 else 10

buckets = defaultdict(list)
files = sorted(glob.glob(sys.argv[1] + "*"))
if not files:
    sys.exit(f"нет файлов по маске {sys.argv[1]}*")

for path in files:
    for line in open(path):
        f = line.split()
        if len(f) < 6:
            continue
        try:
            lat_us = float(f[2])
            epoch = int(f[4])
        except ValueError:
            continue
        buckets[epoch - epoch % WINDOW].append(lat_us / 1000.0)

def pct(xs, p):
    xs = sorted(xs)
    k = min(len(xs) - 1, int(round(p * (len(xs) - 1))))
    return xs[k]

print("epoch\tn\tp50_ms\tp95_ms\tp99_ms\tmax_ms")
for epoch in sorted(buckets):
    xs = buckets[epoch]
    print(f"{epoch}\t{len(xs)}\t{statistics.median(xs):.2f}\t"
          f"{pct(xs,0.95):.2f}\t{pct(xs,0.99):.2f}\t{max(xs):.2f}")

all_lat = [x for xs in buckets.values() for x in xs]
print(f"\n# всего транзакций: {len(all_lat)}", file=sys.stderr)
print(f"# p50={statistics.median(all_lat):.2f} ms  "
      f"p99={pct(all_lat,0.99):.2f} ms  "
      f"p99/p50={pct(all_lat,0.99)/statistics.median(all_lat):.1f}",
      file=sys.stderr)
