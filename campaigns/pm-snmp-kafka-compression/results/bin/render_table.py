#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Render the trials table for findings.md from trials.jsonl. Numbers never typed by hand."""
import json
import sys

with open(sys.argv[1]) as fh:
    rows = [json.loads(line) for line in fh]
base = rows[0]
print("| Trial | Minion codec | Core metrics codec | Coll./s | Completion | Queue at zero | Queue peak "
      "| Core CPU | Core core-s per coll. | Minion CPU | Broker CPU | Minion to Kafka | Core Kafka side "
      "| Broker link | Verdict |")
print("|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|")
for r in rows:
    m = r["mbit"]
    c = r["cpu"]
    print(f"| {r['trial']} | {r['codec_minion']} | {r['codec_core_metrics']} | {r['collections_per_s']:.2f} "
          f"| {100 * r['completion']:.1f}% | {100 * r['queue_zero_frac']:.0f}% | {r['queue_max']:,.0f} "
          f"| {c['core']:.1f}% | {r['core_cpu_s_per_collection']:.4f} | {c['minion']:.1f}% | {c['kafka']:.1f}% "
          f"| {m['minion_enp6s19_rpc_to_kafka']:.0f} Mbit/s | {m['core_enp6s20_rpc_and_metrics']:.0f} Mbit/s "
          f"| {m['kafka_enp6s19_all']:.0f} Mbit/s | {'pass' if r['PASS'] else 'fail'} |")
print()
print("Relative to the first baseline row:")
print()
print("| Trial | Core core-s per coll. | Minion to Kafka | Broker link | Broker CPU |")
print("|---|---:|---:|---:|---:|")
for r in rows[1:]:
    d = 100 * (r["core_cpu_s_per_collection"] / base["core_cpu_s_per_collection"] - 1)
    n1 = r["mbit"]["minion_enp6s19_rpc_to_kafka"] / base["mbit"]["minion_enp6s19_rpc_to_kafka"]
    n2 = r["mbit"]["kafka_enp6s19_all"] / base["mbit"]["kafka_enp6s19_all"]
    dk = r["cpu"]["kafka"] - base["cpu"]["kafka"]
    print(f"| {r['trial']} | {d:+.1f}% | {100 * n1:.0f}% of baseline | {100 * n2:.0f}% of baseline "
          f"| {dk:+.1f} points |")
