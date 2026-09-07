#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Summarise the outage timeline log per phase: before, outage, first cycle after, steady after."""
import statistics
import sys

path = sys.argv[1]
rows, t0, t1 = [], None, None
with open(path) as fh:
    for line in fh:
        if line.startswith("# T0 OUTAGE START"):
            t0 = line.split()[4][11:19]
        elif line.startswith("# T1 RESTORE"):
            t1 = line.split()[3][11:19]
        elif line[:2].isdigit() and line[2] == ":":
            p = line.split()
            if len(p) >= 17:
                rows.append(p)
cols = ["time", "services", "pending", "active", "done_s", "core", "minion", "db", "heap", "oldgc", "snmp", "load",
        "ev", "dcf", "dcs", "alarms", "open_major"]
recs = [dict(zip(cols, r, strict=False)) for r in rows]


def phase(name, sel):
    rs = [r for r in recs if sel(r["time"])]
    if not rs:
        return
    def col(k):
        return [float(r[k]) for r in rs]

    m = statistics.mean
    print(f"| {name} | {len(rs)} | {m(col('done_s')):.1f} | {max(col('pending')):.0f} | {m(col('active')):.0f} "
          f"| {m(col('core')):.1f}% | {m(col('db')):.1f}% | {m(col('heap')):.1f} GiB | {m(col('snmp')):.1f} "
          f"| {sum(col('dcf')):.0f} | {sum(col('dcs')):.0f} | {max(col('open_major')):.0f} |")


def plus(t, m):
    h, mi, s = (int(x) for x in t.split(":"))
    mi += m
    h += mi // 60
    mi %= 60
    return f"{h:02d}:{mi:02d}:{s:02d}"


print("| Phase | Minutes | Coll./s | Queue peak | Threads busy | Core CPU | DB CPU | Heap | SNMP Mbit/s "
      "| dataCollectionFailed | dataCollectionSucceeded | Open major alarms, peak |")
print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
phase("before the outage", lambda t: t < t0)
phase("outage", lambda t: t0 <= t < t1)
phase("first 5 min after restore", lambda t: t1 <= t < plus(t1, 5))
phase("5 to 15 min after restore", lambda t: plus(t1, 5) <= t < plus(t1, 15))
phase("15 to 30 min after restore", lambda t: plus(t1, 15) <= t < plus(t1, 30))
print(f"\nT0 {t0}Z, T1 {t1}Z; one line per minute from bin/monitor.py.")
