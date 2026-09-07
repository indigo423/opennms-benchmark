#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Render the per-level table for the report from levels.jsonl. Numbers never typed by hand."""
import json
import sys

with open(sys.argv[1]) as fh:
    rows = [json.loads(line) for line in fh]
LABEL = {"baseline-0": "0%, baseline", "after-pulse": "0%, after the pulse"}


def label(r):
    return LABEL.get(r["trial"], f"{r['unreachable_pct']}%")


print("| Unreachable | Coll./s | Threads | Queue empty | Core | Minion | DB | Core-s per coll. |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for r in rows:
    c = r["cpu"]
    print(f"| {label(r)} | {r['collections_per_s']:.2f} | {r['threads_mean']:.0f} | {100 * r['queue_zero_frac']:.0f}% "
          f"| {c['core']:.1f}% | {c['minion']:.1f}% | {c['db']:.1f}% | {r['core_cpu_s_per_collection']:.4f} |")
print()
print("| Unreachable | Metrics out | Delivered | Expected | Heap | Load |")
print("|---|---:|---:|---:|---:|---:|")
for r in rows:
    ds = f"{100 * r['delivered_share']:.0f}%" if r.get("delivered_share") is not None else "baseline"
    print(f"| {label(r)} | {r['core_tx_mbit']:.1f} | {ds} | {100 * r['expected_share']:.0f}% "
          f"| {r['heap_gib']:.1f} | {r['core_load1']:.1f} |")
