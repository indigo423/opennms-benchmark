#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Summarise an outage or pulse timeline log per phase: before, outage, first cycle after, steady after."""
import re
import statistics
import sys

path = sys.argv[1]
rows, t0, t1 = [], None, None
with open(path) as fh:
    for line in fh:
        stamp = re.search(r"\d{4}-\d\d-\d\dT(\d\d:\d\d:\d\d)Z", line)
        if line.startswith(("# T0 OUTAGE START", "# PULSE ON")) and stamp:
            t0 = stamp.group(1)
        elif line.startswith(("# T1 RESTORE", "# PULSE OFF")) and stamp:
            t1 = stamp.group(1)
        elif line[:2].isdigit() and line[2] == ":":
            p = line.split()
            if len(p) >= 17:
                rows.append(p)
cols = ["time", "services", "pending", "active", "done_s", "core", "minion", "db", "heap", "oldgc", "snmp", "load",
        "ev", "dcf", "dcs", "alarms", "open_major"]
recs = [dict(zip(cols, r, strict=False)) for r in rows]


def rows_for(sel):
    return [r for r in recs if sel(r["time"])]


PHASES = [("before", lambda t: t < t0), ("outage", lambda t: t0 <= t < t1),
          ("restore +0 to 5 min", lambda t: t1 <= t < plus(t1, 5)),
          ("restore +5 to 15 min", lambda t: plus(t1, 5) <= t < plus(t1, 15)),
          ("restore +15 to 30 min", lambda t: plus(t1, 15) <= t < plus(t1, 30))]


def collector_table():
    print("| Phase | Min | Coll./s | Queue peak | Threads | Core | DB | Heap | SNMP |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for name, sel in PHASES:
        rs = rows_for(sel)
        if not rs:
            continue
        v = {k: [float(r[k]) for r in rs] for k in ("done_s", "pending", "active", "core", "db", "heap", "snmp")}
        m = statistics.mean
        print(f"| {name} | {len(rs)} | {m(v['done_s']):.1f} | {max(v['pending']):,.0f} "
              f"| {m(v['active']):.0f} | {m(v['core']):.1f}% | {m(v['db']):.1f}% "
              f"| {m(v['heap']):.1f} | {m(v['snmp']):.1f} |")


def event_table():
    print("| Phase | Failed | Succeeded | Open alarms, peak |")
    print("|---|---:|---:|---:|")
    for name, sel in PHASES:
        rs = rows_for(sel)
        if not rs:
            continue
        dcf = sum(float(r["dcf"]) for r in rs)
        dcs = sum(float(r["dcs"]) for r in rs)
        op = max(float(r["open_major"]) for r in rs)
        print(f"| {name} | {dcf:,.0f} | {dcs:,.0f} | {op:,.0f} |")


def plus(t, m):
    h, mi, s = (int(x) for x in t.split(":"))
    mi += m
    h += mi // 60
    mi %= 60
    return f"{h:02d}:{mi:02d}:{s:02d}"


collector_table()
print()
event_table()
print(f"\nT0 {t0}Z, T1 {t1}Z; one line per minute from bin/monitor.py.")
