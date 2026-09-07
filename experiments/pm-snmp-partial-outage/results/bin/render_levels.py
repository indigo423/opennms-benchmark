#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Render the per-level table for the report from levels.jsonl. Numbers never typed by hand."""
import json
import sys

with open(sys.argv[1]) as fh:
    rows = [json.loads(line) for line in fh]
print("| Unreachable | Dead devices | Coll./s | Threads busy | Queue at zero | Core CPU | Minion CPU | DB CPU "
      "| Core core-s per coll. | Metrics out | Delivered share | Expected share | Heap | Core load |")
print("|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
for r in rows:
    c = r["cpu"]
    ds = f"{100 * r['delivered_share']:.0f}%" if r.get("delivered_share") is not None else "baseline"
    dead = r["unreachable_pct"] * 110
    print(f"| {r['unreachable_pct']}% | {dead:,} | {r['collections_per_s']:.2f} | {r['threads_mean']:.0f} "
          f"| {100 * r['queue_zero_frac']:.0f}% | {c['core']:.1f}% | {c['minion']:.1f}% | {c['db']:.1f}% "
          f"| {r['core_cpu_s_per_collection']:.4f} | {r['core_tx_mbit']:.1f} Mbit/s | {ds} "
          f"| {100 * r['expected_share']:.0f}% | {r['heap_gib']:.1f} GiB | {r['core_load1']:.1f} |")
