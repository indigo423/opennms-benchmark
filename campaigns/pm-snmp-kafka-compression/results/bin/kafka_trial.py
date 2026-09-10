#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Judge one Kafka compression trial at a fixed fleet.

The knee search's pass rule (queue back to zero inside the window, completed
count at 97% of due) plus what the codec is expected to move: CPU on the Core,
the Minion and the broker, bytes on the Kafka segment, and the Core's CPU cost
per collection. Every figure is a window average from the raw samples.
"""
import argparse
import datetime
import json
import statistics
import urllib.parse
import urllib.request

P = "http://192.168.10.40:9090/prometheus"
CJ = 'instance="core-benchmark-01:9299"'
N = {h: f'instance="{h}-benchmark-01:9100"' for h in ("core", "minion", "db", "kafka", "netsim")}
INTERVAL = 300


def seconds(S, E):
    t0 = datetime.datetime.fromisoformat(S.replace("Z", "+00:00"))
    t1 = datetime.datetime.fromisoformat(E.replace("Z", "+00:00"))
    return int((t1 - t0).total_seconds())


def rng(expr, S, E, step="15s"):
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": expr, "start": S, "end": E, "step": step}), timeout=90))["data"]["result"]
    return [float(v) for _, v in d[0]["values"]] if d else []


def counter_rate(expr, S, E):
    W = seconds(S, E)
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query?" + urllib.parse.urlencode(
        {"query": f"{expr}[{W}s]", "time": E}), timeout=60))["data"]["result"]
    v = [(float(t), float(x)) for t, x in d[0]["values"]] if d else []
    return (v[-1][1] - v[0][1]) / (v[-1][0] - v[0][0]) if len(v) > 1 else float("nan")


def mean(expr, S, E):
    v = rng(expr, S, E)
    return round(statistics.mean(v), 1) if v else None


def mbit(host, dev, S, E):
    i = N[host]
    return mean(f'(rate(node_network_receive_bytes_total{{{i},device="{dev}"}}[2m]) '
                f'+ rate(node_network_transmit_bytes_total{{{i},device="{dev}"}}[2m])) * 8 / 1e6', S, E)


def cpu(host, S, E):
    return mean(f'100 - avg(rate(node_cpu_seconds_total{{{N[host]},mode="idle"}}[2m])) * 100', S, E)


def measure(label, codec_minion, codec_core, S, E, out):
    W = seconds(S, E)
    svc = rng(f'opennms_collectd_collectableservicecount{{{CJ}}}', S, E)
    pend = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    n = statistics.median(svc) if svc else 0
    per_s = counter_rate(f'opennms_collectd_taskscompleted{{{CJ}}}', S, E)
    core = cpu("core", S, E)
    rec = {"trial": label, "codec_minion": codec_minion, "codec_core_metrics": codec_core,
           "window": [S, E], "seconds": W, "services": n,
           "collections_per_s": round(per_s, 2), "required_per_s": round(n / INTERVAL, 2),
           "completion": round(per_s * INTERVAL / n, 4) if n else None,
           "queue_drains": bool(pend) and min(pend) == 0,
           "queue_max": max(pend) if pend else None,
           "queue_zero_frac": round(sum(1 for x in pend if x == 0) / len(pend), 3) if pend else None,
           "threads_mean": mean(f'opennms_collectd_activethreads{{{CJ}}}', S, E),
           "cpu": {h: cpu(h, S, E) for h in ("core", "minion", "kafka", "db", "netsim")},
           "core_cpu_s_per_collection": round(core * 8 / 100 / per_s, 4) if per_s else None,
           "minion_cpu_s_per_collection": (round(cpu("minion", S, E) * 4 / 100 / per_s, 4)
                                           if per_s else None),
           "mbit": {"minion_enp6s19_rpc_to_kafka": mbit("minion", "enp6s19", S, E),
                    "core_enp6s20_rpc_and_metrics": mbit("core", "enp6s20", S, E),
                    "kafka_enp6s19_all": mbit("kafka", "enp6s19", S, E),
                    "minion_enp6s20_snmp": mbit("minion", "enp6s20", S, E)},
           "young_gc_s_per_min": mean(
               f'rate(java_lang_g1_young_generation_collectiontime{{{CJ}}}[2m]) / 1000 * 60', S, E),
           "ctxsw_per_s": {"core": mean(f'rate(node_context_switches_total{{{N["core"]}}}[2m])', S, E),
                           "minion": mean(f'rate(node_context_switches_total{{{N["minion"]}}}[2m])', S, E)}}
    rec["PASS"] = bool(rec["queue_drains"] and rec["completion"] is not None and rec["completion"] >= 0.97)
    with open(f"{out}/trials.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(json.dumps(rec, indent=1))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--codec-minion", default="none")
    ap.add_argument("--codec-core", default="none")
    ap.add_argument("--out", default=".")
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    a = ap.parse_args()
    measure(a.label, a.codec_minion, a.codec_core, a.start, a.end, a.out)
