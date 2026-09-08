#!/usr/bin/env python3
"""Backlog: расписание против факта.

  backlog.py <префикс лога pgbench> <sampler.tsv> <лог сервера> [окно, с]

pgbench с -R записывает для каждой транзакции schedule lag: на сколько
она стартовала позже, чем должна была по расписанию. Это и есть прямая
мера накопленной очереди: если система успевает, lag около нуля; если
не успевает, он растёт и потом рассасывается.

Формат сырого лога pgbench при -R:
  client_id transaction_no time script_no time_epoch time_us schedule_lag
"""
import sys, glob, re, statistics, datetime
from collections import defaultdict

prefix, sampler, server_log = sys.argv[1], sys.argv[2], sys.argv[3]
W = int(sys.argv[4]) if len(sys.argv) > 4 else 5

lat, lag, cnt = defaultdict(list), defaultdict(list), defaultdict(int)
for path in sorted(glob.glob(prefix + "*")):
    for line in open(path):
        f = line.split()
        if len(f) < 7:
            continue
        try:
            e = int(f[4]) // W * W
            lat[e].append(float(f[2]) / 1000.0)
            lag[e].append(float(f[6]) / 1000.0)
            cnt[e] += 1
        except ValueError:
            continue
if not cnt:
    sys.exit("нет данных pgbench с schedule lag (нужен прогон с -R и -l)")

ckpt = []
pat = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\.\d+ \w+ .*checkpoint (starting|complete)")
for line in open(server_log, errors="replace"):
    m = pat.match(line)
    if m:
        t = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        ckpt.append((int(t.replace(tzinfo=datetime.timezone.utc).timestamp()),
                     m.group(2)))

buf = {}
for line in open(sampler):
    f = line.split("\t")
    if len(f) < 8 or not f[0].isdigit():
        continue
    e = int(f[0]) // W * W
    d = buf.setdefault(e, [0, 0, 0])
    d[0] += int(f[1]); d[1] += int(f[5]); d[2] += int(f[6])

def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(p * (len(xs) - 1))))]

start = min(cnt)
marks = {e // W * W: k for e, k in ckpt if start <= e <= max(cnt)}
print("t,c\tзавершено\tp99_ms\tlag_p99_ms\tlag_max_ms\tbuf_ckpt\tметка")
for e in sorted(cnt):
    b = buf.get(e, [0, 0, 0])
    print(f"{e-start}\t{cnt[e]}\t{pct(lat[e],0.99):.1f}\t"
          f"{pct(lag[e],0.99):.1f}\t{max(lag[e]):.1f}\t{b[1]}\t"
          f"{marks.get(e,'')}")

quiet = [max(lag[e]) for e in cnt if e not in marks]
if quiet:
    base = statistics.median(quiet)
    print(f"\n# фоновый максимум schedule lag: {base:.1f} ms", file=sys.stderr)
    for e in sorted(cnt):
        if max(lag[e]) > 5 * base:
            prev = [c for c in sorted(marks) if c <= e]
            off = f"+{e-prev[-1]}s от {marks[prev[-1]]}" if prev else "до чекпойнта"
            print(f"# t={e-start}s: lag_max {max(lag[e]):.0f} ms, "
                  f"завершено {cnt[e]}, буферов чекпойнта {buf.get(e,[0,0,0])[1]}, {off}",
                  file=sys.stderr)
