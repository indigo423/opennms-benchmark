#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Per-device SNMP collection duration from OpenNMS instrumentation.log.

`collector.collect: begin:<key>` -> `end:<key>` is the service time W that
Little's Law only estimates from aliased thread counts. Note the plain verbs
carry NO space after the colon, while persistDataQueueing does.

Under Kafka-exclusive forwarding persistDataQueueing is the producer handoff,
not disk, so it is reported separately and never folded into service time.
"""
import re, sys, datetime, statistics
from collections import defaultdict

PAT = re.compile(
    r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d),(\d{3}) .*?"
    r"collector\.collect: (persistDataQueueing: )?(begin|end):\s*(\S+)")


def parse(paths, t0=None, t1=None):
    open_c, open_p = {}, {}
    durs, pdurs = [], []
    by_pkg = defaultdict(list)
    for path in paths:
        try:
            fh = open(path, errors="replace")
        except OSError:
            continue
        for line in fh:
            m = PAT.match(line)
            if not m:
                continue
            ts = datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            ts = ts.replace(microsecond=int(m.group(2)) * 1000)
            if t0 and ts < t0:
                continue
            if t1 and ts > t1:
                continue
            persist, verb, key = bool(m.group(3)), m.group(4), m.group(5)
            d = open_p if persist else open_c
            if verb == "begin":
                d[key] = ts
            else:
                b = d.pop(key, None)
                if b is None:
                    continue
                dt = (ts - b).total_seconds()
                if persist:
                    pdurs.append(dt)
                else:
                    durs.append(dt)
                    by_pkg[key.split("/")[0]].append(dt)
    return durs, pdurs, by_pkg


def rep(name, a):
    if not a:
        print(f"  {name}: none")
        return
    x = sorted(a)
    pc = lambda q: x[min(len(x) - 1, int(len(x) * q))]
    print(f"  {name}: n={len(a):>6}  mean={statistics.mean(a)*1000:>7.0f}ms  "
          f"median={statistics.median(a)*1000:>7.0f}ms  p90={pc(.90)*1000:>7.0f}ms  "
          f"p95={pc(.95)*1000:>7.0f}ms  p99={pc(.99)*1000:>8.0f}ms  max={max(a)*1000:>8.0f}ms")


if __name__ == "__main__":
    t0 = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%S") if len(sys.argv) > 1 else None
    t1 = datetime.datetime.strptime(sys.argv[2], "%Y-%m-%dT%H:%M:%S") if len(sys.argv) > 2 else None
    paths = sys.argv[3:] or ["/var/tmp/pm-snmp-latency/backfill-from-1500Z.log",
                             "/var/tmp/pm-snmp-latency/capture.log"]
    d, pd, by_pkg = parse(paths, t0, t1)
    print(f"window {t0} .. {t1} (UTC)   files={len(paths)}")
    rep("collectData  SNMP service time", d)
    rep("persistQueue Kafka handoff    ", pd)
    print("  by package:")
    for pkg, v in sorted(by_pkg.items(), key=lambda kv: -len(kv[1])):
        rep(f"    {pkg:<10}", v)
    if d and t0 and t1:
        tot, span = sum(d), (t1 - t0).total_seconds()
        print(f"  aggregate: {tot:.0f} thread-seconds / {span:.0f}s window "
              f"=> mean concurrency {tot/span:.1f} threads (measured L, not sampled)")
