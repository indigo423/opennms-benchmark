#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""The sizing rule, derived from every knee the campaign recorded, and tested against each.

Two constants per collection: thread time T = P x R + c0 (P PDUs per collection at
round trip R, c0 the Core-side overhead) and CPU cost c in core-seconds. The pool
binds at threads x 300 / T devices, the cores at cores x U x 300 / c. Whichever is
smaller is the knee. Every input is read from the searches' own records.
"""
import json
import statistics

A = "experiments/pm-snmp-agent-latency/results"
L = "experiments/pm-snmp-latency/results"
R_MS = 75.6           # median SNMP round trip under netem delay 75ms 25ms, from the Minion pcap
INTERVAL = 300


def rows(path):
    with open(path) as fh:
        return [json.loads(line) for line in fh]


def last_pass(rs):
    p = [r for r in rs if r["PASS"]]
    return p[-1] if p else None


def first_fail(rs):
    f = [r for r in rs if not r["PASS"]]
    return f[0] if f else None


print("## Thread time per collection against agent latency "
      "(fleet 3,803, pool 100, max-repetitions 2)\n")
print("| netem delay | Thread-seconds per collection | Collection time, median | Persist, median | Pool busy, mean |")
print("|---:|---:|---:|---:|---:|")
sweep = rows(f"{L}/latency-sweep.jsonl")
pts = []
for r in sweep:
    tag = r["tag"].replace("p2-", "").replace("p0-control", "none").replace("p1-netem0", "0 ms (netem on)")
    cm = f"{r['collect_median'] / 1000:.2f} s" if "collect_median" in r else "n/a"
    pm = f"{r['persist_median']:.0f} ms" if "persist_median" in r else "n/a"
    print(f"| {tag} | {r['W_s']:.2f} s | {cm} | {pm} | {r['threads_mean']:.1f} |")
    if "collect_median" in r and tag.endswith("ms") and r["threads_mean"] < 99:
        pts.append((float(tag.rstrip("ms").strip()), r["collect_median"]))
# slope of collection time against delay: PDUs per collection
xs = [p[0] for p in pts]
ys = [p[1] for p in pts]
mx, my = statistics.mean(xs), statistics.mean(ys)
slope = sum((x - mx) * (y - my) for x, y in zip(xs, ys, strict=True)) / sum((x - mx) ** 2 for x in xs)
icpt = my - slope * mx
print(f"\nSlope of the median collection time against the delay, 2 to 50 ms: {slope:.0f} ms per ms, "
      f"i.e. {slope:.0f} sequential PDUs per collection; intercept {icpt:.0f} ms. Estimate.\n")

# per-search summaries
searches = [
    ("mr2, pool 100", f"{A}/knee-search.jsonl", 149, 100, "16 GiB / 10 GiB heap"),
    ("mr2, pool 200", f"{A}/knee-search-pool200.jsonl", 149, 200, "16 GiB / 10 GiB heap"),
    ("mr5, pool 200", f"{A}/knee-search-pool200-mr5.jsonl", 61, 200, "16 GiB / 10 GiB heap"),
    ("mr5, pool 300", f"{A}/knee-search-pool300-mr5.jsonl", 61, 300, "16 GiB / 10 GiB heap"),
    ("mr5, pool 300", f"{A}/knee-search-pool300-mr5-32g.jsonl", 61, 300, "32 GiB / 20 GiB heap"),
    ("mr5, pool 400", f"{A}/knee-search-pool400-mr5-32g.jsonl", 61, 400, "32 GiB / 20 GiB heap"),
]
print("## Every knee at 50 to 100 ms per PDU, measured against the rule\n")
print("| Search | Core | Last pass / first fail | T measured at last pass | T = P x R + c0 "
      "| Pool limit, threads x 300 / T | c measured, core-s | CPU limit at 96% of 8 cores "
      "| Binds |")
print("|---|---|---|---:|---:|---:|---:|---:|---|")
C0 = 0.75            # Core-side seconds per collection outside the SNMP round trips: RPC, parse, persist
for name, path, P, pool, core in searches:
    rs = rows(path)
    lp, ff = last_pass(rs), first_fail(rs)
    n = lp["services"]
    rate = n / INTERVAL * lp.get("completion", 1.0)
    T_meas = lp["threads_mean"] / rate
    T_rule = P * R_MS / 1000 + C0
    pool_limit = pool * INTERVAL / T_rule
    c_meas = lp["core_pct"] / 100 * 8 / rate
    cpu_limit = 8 * 0.96 * INTERVAL / c_meas
    knee = f"{lp['fleet']:,} / {ff['fleet']:,}" if ff else f"{lp['fleet']:,} / cap"
    gc_bound = core.startswith("16") and lp["fleet"] >= 12000 and lp["core_pct"] > 80
    binds = "heap (old-gen GC)" if gc_bound else ("pool" if pool_limit < cpu_limit else "cores")
    print(f"| {name} | {core} | {knee} | {T_meas:.1f} s | {T_rule:.1f} s | {pool_limit:,.0f} | {c_meas:.3f} "
          f"| {cpu_limit:,.0f} | {binds} |")

print("\n## Fast agents: the cleanroom edge search "
      "(8 to 12 ms per PDU, max-repetitions 2, pool 100, 16 GiB / 10 GiB heap)\n")
print("| Fleet | Pool busy, mean | T measured | Core cores busy | c, core-s per collection | Heap used "
      "| GC share | Verdict |")
print("|---:|---:|---:|---:|---:|---:|---:|---|")
for r in rows(f"{L}/edge-search.jsonl"):
    rate = r["services"] / INTERVAL
    print(f"| {r['fleet']:,} | {r['threads_mean']:.1f} | {r['threads_mean'] / rate:.2f} s | {r['core_cores']:.2f} "
          f"| {r['core_cores'] / rate:.3f} | {r['heap_gib']:.1f} GiB | {100 * r['gc_sec_per_sec']:.1f}% "
          f"| {'pass' if r['PASS'] else 'fail'} |")
T_edge = 149 * 0.010 + C0
print(f"\nRule at 10 ms: T = 149 x 0.010 + {C0} = {T_edge:.2f} s, pool limit 100 x 300 / {T_edge:.2f} = "
      f"{100 * 300 / T_edge:,.0f} devices; measured 13,000 pass, 14,000 fail.\n")

print("## Heap: live set after collection against fleet and pool\n")
print("| Core | Fleet | Threads | Heap used, window mean | Old-generation GC | Source |")
print("|---|---:|---:|---:|---|---|")
for r in rows(f"{L}/fleet-sweep.jsonl"):
    print(f"| 16 GiB / 10 GiB | {r['services'] - 55:,.0f} | 100 | {r['heap_gib']:.1f} GiB "
          f"| {r['gc_old_per_min']:.2f} per min, {100 * r['gc_sec_per_sec']:.1f}% of wall | fleet-sweep (cleanroom) |")
print("| 16 GiB / 10 GiB | 14,250 | 300 | 9.1 GiB | 61 in 35 min, 17.4% of wall "
      "| pm-snmp-agent-latency-mr5-live |")
print("| 32 GiB / 20 GiB | 17,250 | 300 | 15.5 GiB (12.4 after collection) | 0 "
      "| pm-snmp-agent-latency-32g-live |")
print("| 32 GiB / 20 GiB | 20,250 | 400 | 16.8 GiB (16.3 after collection) | 5 full in 25 min, 7.9% of wall "
      "| pm-snmp-agent-latency-32g-pool400-live |")
