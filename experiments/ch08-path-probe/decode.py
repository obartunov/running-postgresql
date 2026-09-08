#!/usr/bin/env python3
"""Читаемый вид строк PATHPROBE из лога сервера.

  decode.py <лог сервера> [nodetags.h]

Без nodetags.h номера узлов печатаются как есть: они зависят от версии,
поэтому таблица берётся из исходников той сборки, которой снят лог.
"""
import sys, re

log = sys.argv[1]
tags = {}
if len(sys.argv) > 2:
    # в nodetags.h часть элементов имеет явное значение (T_SeqScan = 318),
    # остальные продолжают счёт; учитываем оба случая
    n = 0
    for raw in open(sys.argv[2]):
        line = raw.strip().rstrip(',')
        if not line.startswith('T_'):
            continue
        m = re.match(r'(T_\w+)\s*=\s*(\d+)', line)
        if m:
            name, n = m.group(1), int(m.group(2))
        else:
            name, n = line.split()[0], n + 1
        tags[n] = name

print(f"{'решение':9} {'rel':6} {'узел':18} {'startup':>10} {'total':>12} "
      f"{'rows':>9} {'pk':>3} {'req_outer':>9}")
for line in open(log, errors='replace'):
    m = re.search(r'PATHPROBE (\w+) rel=(\S+) node=(\d+) startup=(\S+) '
                  r'total=(\S+) rows=(\S+) pathkeys=(\d+) req_outer=(\S+)', line)
    if not m:
        continue
    ev, rel, node, st, tot, rows, pk, req = m.groups()
    name = tags.get(int(node), f'node{node}')
    idx = re.search(r'index=(\d+)', line)
    print(f"{ev:9} {rel:6} {name:18} {st:>10} {tot:>12} {rows:>9} {pk:>3} "
          f"{req:>9}" + (f"  index={idx.group(1)}" if idx else ""))
