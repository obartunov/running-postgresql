#!/bin/sh
set -eu

awk '
/PLANNER_PATH/ {
    line = $0
    sub(/^.*PLANNER_PATH[[:space:]]*/, "", line)
    trace[++n] = line

    event = "unknown"
    nf = split(line, f, /[[:space:]]+/)
    for (i = 1; i <= nf; i++)
    {
        if (f[i] ~ /^event=/)
        {
            split(f[i], a, "=")
            event = a[2]
        }
    }
    count[event]++

    if (line ~ /IndexScan|IndexOnlyScan/)
        index_trace[++ni] = line

    if (line ~ /required_outer=\{[0-9]/ ||
        line ~ /new_required_outer=\{[0-9]/ ||
        line ~ /old_required_outer=\{[0-9]/)
        param_trace[++np] = line
}
END {
    print "== planner path-pruning events =="
    for (i = 1; i <= n; i++)
        print trace[i]

    print ""
    print "== event counts =="
    print "accept          " (count["accept"] + 0)
    print "precheck-reject " (count["precheck-reject"] + 0)
    print "reject          " (count["reject"] + 0)
    print "displace        " (count["displace"] + 0)

    print ""
    print "== events mentioning an index path =="
    if (ni == 0)
        print "(none)"
    else
        for (i = 1; i <= ni; i++)
            print index_trace[i]

    print ""
    print "== events with non-empty parameterization =="
    if (np == 0)
        print "(none)"
    else
        for (i = 1; i <= np; i++)
            print param_trace[i]
}
' "${1:-/dev/stdin}"
