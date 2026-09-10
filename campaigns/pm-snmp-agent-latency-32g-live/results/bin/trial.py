#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Judge one tuning trial at a fixed fleet with the knee search's criterion.

Same rule as knee_search.measure(): the pending queue must return to zero
inside the window AND the window integral of taskscompleted must reach 97%
of the services due. Either measures a window that has already passed
(--start/--end) or sleeps through a fresh one (--minutes). Appends to
trials.jsonl under the results directory.
"""
import argparse
import datetime
import json
import statistics
import time
import urllib.parse
import urllib.request

P  = "http://192.168.10.40:9090/prometheus"
CJ = 'instance="core-benchmark-01:9299"'
CN = 'instance="core-benchmark-01:9100"'
MN = 'instance="minion-benchmark-01:9100"'
DN = 'instance="db-benchmark-01:9100"'
INTERVAL = 300

def seconds(S, E):
    """Whole seconds between two RFC 3339 UTC timestamps."""
    t0 = datetime.datetime.fromisoformat(S.replace("Z", "+00:00"))
    t1 = datetime.datetime.fromisoformat(E.replace("Z", "+00:00"))
    return int((t1 - t0).total_seconds())

def rng(expr, s, e, step="15s"):
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": expr, "start": s, "end": e, "step": step}), timeout=90))["data"]["result"]
    return [float(v) for _, v in d[0]["values"]] if d else []

def q(expr, at):
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query?" + urllib.parse.urlencode(
        {"query": expr, "time": at}), timeout=60))["data"]["result"]
    return float(d[0]["value"][1]) if d else float("nan")

def counter_rate(expr, S, E):
    """Per-second rate of a counter from its raw samples inside [S, E].

    increase() extrapolates to the window edges only when samples sit near
    them; the Core's JMX exporter drops scrapes under load, and one missing
    tail turned a 99.8% window into 86%. First and last raw sample, divided
    by the seconds between them, is the honest rate; the covered span is
    reported next to it.
    """
    W = seconds(S, E)
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query?" + urllib.parse.urlencode(
        {"query": f"{expr}[{W}s]", "time": E}), timeout=60))["data"]["result"]
    v = [(float(t), float(x)) for t, x in d[0]["values"]] if d else []
    if len(v) < 2:
        return float("nan"), 0
    return (v[-1][1] - v[0][1]) / (v[-1][0] - v[0][0]), int(v[-1][0] - v[0][0])

def measure(label, S, E, out):
    W = seconds(S, E)
    svc  = rng(f'opennms_collectd_collectableservicecount{{{CJ}}}', S, E)
    pend = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    thr  = rng(f'opennms_collectd_activethreads{{{CJ}}}', S, E)
    cpu  = rng(f'100 - avg(rate(node_cpu_seconds_total{{{CN},mode="idle"}}[5m]))*100', S, E)
    mcpu = rng(f'100 - avg(rate(node_cpu_seconds_total{{{MN},mode="idle"}}[5m]))*100', S, E)
    dcpu = rng(f'100 - avg(rate(node_cpu_seconds_total{{{DN},mode="idle"}}[5m]))*100', S, E)
    gc   = rng(f'rate(java_lang_g1_old_generation_collectioncount{{{CJ}}}[5m])*60', S, E)
    ygc_rate, _ = counter_rate(f'java_lang_g1_young_generation_collectiontime{{{CJ}}}', S, E)
    ygc = ygc_rate * W
    per_s, covered = counter_rate(f'opennms_collectd_taskscompleted{{{CJ}}}', S, E)
    done = per_s * W
    n = statistics.median(svc) if svc else 0
    req = n / INTERVAL * W
    rec = {"trial": label, "window": [S, E], "seconds": W, "counter_samples_span_s": covered, "services": n,
           "pool": q(f'opennms_collectd_maxpoolthreads{{{CJ}}}', E),
           "queue_drains": bool(pend) and min(pend) == 0,
           "queue_min": min(pend) if pend else None, "queue_max": max(pend) if pend else None,
           "queue_zero_frac": round(sum(1 for x in pend if x == 0) / len(pend), 3) if pend else None,
           "threads_mean": round(statistics.mean(thr), 1) if thr else None, "threads_max": max(thr) if thr else None,
           "core_pct": round(statistics.mean(cpu), 1) if cpu else None,
           "minion_pct": round(statistics.mean(mcpu), 1) if mcpu else None,
           "db_pct": round(statistics.mean(dcpu), 1) if dcpu else None,
           "old_gc_per_min": round(statistics.mean(gc), 2) if gc else None,
           "young_gc_ms_per_min": round(ygc / W * 60, 1) if ygc == ygc else None,
           "collections_done": round(done), "collections_required": round(req),
           "completion": round(done / req, 4) if req else None,
           "collections_per_s": round(per_s, 2)}
    rec["PASS"] = bool(rec["queue_drains"] and rec["completion"] is not None and rec["completion"] >= 0.97)
    with open(f"{out}/trials.jsonl", "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    print(json.dumps(rec, indent=1))
    return rec

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("label")
    ap.add_argument("--out", default=".")
    ap.add_argument("--start")
    ap.add_argument("--end")
    ap.add_argument("--minutes", type=int, default=15)
    a = ap.parse_args()
    if a.start and a.end:
        measure(a.label, a.start, a.end, a.out)
    else:
        t0 = datetime.datetime.now(datetime.UTC)
        time.sleep(a.minutes * 60)
        t1 = datetime.datetime.now(datetime.UTC)
        measure(a.label, t0.strftime("%Y-%m-%dT%H:%M:%SZ"), t1.strftime("%Y-%m-%dT%H:%M:%SZ"), a.out)
