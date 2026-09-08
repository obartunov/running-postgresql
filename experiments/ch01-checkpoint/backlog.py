#!/usr/bin/env python3
"""Темп поступления, темп завершения и backlog по секундам.

  backlog.py <каталог прогона> [окно, с]

pgbench с -R пишет в сырой лог для каждой транзакции задержку от
ЗАПЛАНИРОВАННОГО момента (schedule lag включён в latency при -R).
Отсюда:

  arrivals(t)    — сколько транзакций должно было стартовать в окне
  completions(t) — сколько фактически завершилось в окне
  backlog(t)     — накопленная разница, то есть длина очереди

Отдельно печатается schedule lag: если он растёт, система не
успевает за расписанием, и это тот самый долг, а не просто медленный
запрос.
"""
import sys, glob, os, statistics
from collections import defaultdict

d = sys.argv[1]
W = int(sys.argv[2]) if len(sys.argv) > 2 else 1

comp = defaultdict(int)
lat = defaultdict(list)
lag = defaultdict(list)   # schedule lag: 7-е поле, появляется при -R
for path in sorted(glob.glob(os.path.join(d, "pg.*"))):
    if path.endswith((".out", ".tsv", ".txt", ".log")):
        continue
    for line in open(path):
        f = line.split()
        if len(f) < 6:
            continue
        try:
            l_ms, epoch = float(f[2]) / 1000.0, int(f[4])
        except ValueError:
            continue
        b = epoch - epoch % W
        comp[b] += 1
        lat[b].append(l_ms)
        if len(f) >= 7:
            try:
                lag[b].append(float(f[6]) / 1000.0)
            except ValueError:
                pass
if not comp:
    sys.exit("нет сырого лога pgbench в " + d)

start, end = min(comp), max(comp)
total = sum(comp.values())
rate = total / max(1, (end - start + W))

has_lag = bool(lag)
print("t,c\tзавершено\tp50_ms\tp99_ms\tlag_p50_ms\tlag_max_ms")
for e in range(start, end + 1, W):
    done = comp.get(e, 0)
    xs = sorted(lat.get(e) or [0.0])
    p99 = xs[min(len(xs) - 1, int(round(0.99 * (len(xs) - 1))))]
    ls = sorted(lag.get(e) or [0.0])
    lp50 = statistics.median(ls)
    print(f"{e-start}\t{done}\t{statistics.median(xs):.2f}\t{p99:.2f}\t"
          f"{lp50:.2f}\t{max(ls):.2f}")

print(f"\n# средний темп завершения: {rate:.1f}/s", file=sys.stderr)
if has_lag:
    allrows = [(e, max(lag.get(e) or [0.0])) for e in range(start, end + 1, W)]
    base = statistics.median([v for _, v in allrows])
    print(f"# schedule lag (задержка от расписания -R): медиана максимума по "
          f"окнам {base:.2f} ms", file=sys.stderr)
    for e, v in allrows:
        if v > 10 * max(base, 0.1):
            print(f"#   t={e-start}s: lag до {v:.1f} ms ({v/max(base,0.1):.0f}x)",
                  file=sys.stderr)
    print("# Backlog здесь — это lag: растущий lag означает, что заявки "
          "ждут своего\n#   расписания, то есть очередь. Постоянный lag "
          "означает, что очереди нет.", file=sys.stderr)
else:
    print("# в логе нет поля schedule lag: прогон был без -R, backlog "
          "не определён", file=sys.stderr)
