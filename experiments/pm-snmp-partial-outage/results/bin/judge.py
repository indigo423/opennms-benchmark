#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Judge one outage level over a window: what the collector does, what the healthy remainder delivers.

The completion counter counts failed collections as completed, so delivered work is read from
the Core's metrics stream to Kafka (bytes out on enp6s20), normalised to the healthy baseline.
"""
import argparse
import datetime
import json
import statistics
import urllib.parse
import urllib.request

P = "http://192.168.10.40:9090/prometheus"
CJ = 'instance="core-benchmark-01:9299"'
N = {h: f'instance="{h}-benchmark-01:9100"' for h in ("core", "minion", "db")}


def rng(expr, S, E):
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": expr, "start": S, "end": E, "step": "15s"}), timeout=90))["data"]["result"]
    return [float(v) for _, v in d[0]["values"]] if d else []


def counter_rate(expr, S, E):
    t0 = datetime.datetime.fromisoformat(S.replace("Z", "+00:00"))
    t1 = datetime.datetime.fromisoformat(E.replace("Z", "+00:00"))
    W = int((t1 - t0).total_seconds())
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query?" + urllib.parse.urlencode(
        {"query": f"{expr}[{W}s]", "time": E}), timeout=60))["data"]["result"]
    v = [(float(t), float(x)) for t, x in d[0]["values"]] if d else []
    return (v[-1][1] - v[0][1]) / (v[-1][0] - v[0][0]) if len(v) > 1 else float("nan")


def mean(expr, S, E):
    v = rng(expr, S, E)
    return round(statistics.mean(v), 2) if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--level", type=int, required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--out", default=".")
    ap.add_argument("--baseline-tx-mbit", type=float, default=None, help="Core enp6s20 transmit at 0%% outage")
    a = ap.parse_args()
    S, E = a.start, a.end
    svc = rng(f'opennms_collectd_collectableservicecount{{{CJ}}}', S, E)
    pend = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    n = statistics.median(svc) if svc else 0
    per_s = counter_rate(f'opennms_collectd_taskscompleted{{{CJ}}}', S, E)
    tx = counter_rate(f'node_network_transmit_bytes_total{{{N["core"]},device="enp6s20"}}', S, E) * 8 / 1e6
    cpu = {h: mean(f'100 - avg(rate(node_cpu_seconds_total{{{N[h]},mode="idle"}}[2m])) * 100', S, E) for h in N}
    rec = {"trial": a.label, "unreachable_pct": a.level, "window": [S, E], "services": n,
           "collections_per_s": round(per_s, 2), "required_per_s": round(n / 300, 2),
           "threads_mean": mean(f'opennms_collectd_activethreads{{{CJ}}}', S, E),
           "queue_max": max(pend) if pend else None,
           "queue_zero_frac": round(sum(1 for x in pend if x == 0) / len(pend), 3) if pend else None,
           "cpu": cpu,
           "core_cpu_s_per_collection": round(cpu["core"] * 8 / 100 / per_s, 4) if per_s else None,
           "core_tx_mbit": round(tx, 1),
           "delivered_share": round(tx / a.baseline_tx_mbit, 3) if a.baseline_tx_mbit else None,
           "expected_share": round(1 - a.level / 100, 3),
           "minion_snmp_mbit": mean(
               f'(rate(node_network_receive_bytes_total{{{N["minion"]},device="enp6s20"}}[2m]) '
               f'+ rate(node_network_transmit_bytes_total{{{N["minion"]},device="enp6s20"}}[2m])) * 8 / 1e6', S, E),
           "heap_gib": mean(f'java_lang_memory_heapmemoryusage_used{{{CJ}}} / 2^30', S, E),
           "old_gc_per_min": mean(f'rate(java_lang_g1_old_generation_collectioncount{{{CJ}}}[5m]) * 60', S, E),
           "core_load1": mean(f'node_load1{{{N["core"]}}}', S, E)}
    with open(f"{a.out}/levels.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(json.dumps(rec, indent=1))


if __name__ == "__main__":
    main()
