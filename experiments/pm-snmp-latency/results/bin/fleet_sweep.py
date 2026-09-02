#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Grow the fleet in rungs and find where this deployment's knee actually is.

Two clean points (3,805 and 7,055) put marginal CPU cost above average cost,
which makes the curve convex and drops the predicted 80%-CPU ceiling from
~13,900 to ~10,750 devices. Two points cannot prove a curve, so this walks up
to and past the prediction.

Settle gate is deliberately NOT "no scans". The foreign source rescans on a
1-day interval, so at 7,000+ nodes rolling rescans are continuous (10% of
samples, up to 10 threads). Demanding zero would never pass. Imports must
finish; scan load is recorded as a covariate instead, because rescan cost
scales with inventory and is part of what makes the curve bend.
"""
import json, urllib.request, urllib.parse, ssl, time, datetime, statistics, subprocess

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
P = "https://192.168.10.40/prometheus/api/v1/"
MON = "azureuser@192.168.10.40"
CORE = "azureuser@192.0.2.200"
CJ = 'instance="core-benchmark-01:9299"'
CN = 'instance="core-benchmark-01:9100"'
MN = 'instance="minion-benchmark-01:9100"'
INTERVAL, SETTLE, WINDOW = 300, 600, 900
RESULTS = "fleet-sweep.jsonl"
# fleet already stands at 10,051 (octets 0-42 + 220). Measure it first on the
# resized generator, then keep climbing. Empty octet range = measure, no growth.
RUNGS = [ (13500, range(51, 57)),
         (15000, range(57, 63)), (16500, range(63, 69)), (18000, range(69, 75))]


def log(m): print(f"[{datetime.datetime.now():%H:%M:%S}] {m}", flush=True)


def sh(host, cmd, jump=False, t=300):
    a = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=15"] + (["-J", MON] if jump else []) + [host, cmd]
    r = subprocess.run(a, capture_output=True, text=True, timeout=t)
    return r.stdout.strip()


def q(expr):
    d = urllib.parse.urlencode({"query": expr}).encode()
    r = json.load(urllib.request.urlopen(P + "query", d, context=CTX, timeout=45))["data"]["result"]
    return float(r[0]["value"][1]) if r else None


def rng(expr, s, e, step="60"):
    d = urllib.parse.urlencode({"query": expr, "start": s, "end": e, "step": step}).encode()
    r = json.load(urllib.request.urlopen(P + "query_range", d, context=CTX, timeout=90))["data"]["result"]
    return [float(v) for _, v in r[0]["values"]] if r else []


def nl6_total():
    return int(sh(MON, "curl -s -m 20 http://192.0.2.216:8080/api/v1/status "
                       "| python3 -c 'import json,sys;print(json.load(sys.stdin)[\"data\"][\"total_devices\"])'"))


def grow(octets):
    for o in octets:
        before = nl6_total()
        body = ('{"start_ip":"10.42.%d.1","device_count":250,"netmask":"16",'
                '"syslog":{"collector":"192.0.2.144:10514"},'
                '"traps":{"collector":"192.0.2.144:10162","mode":"trap"},'
                '"resource_file":"cisco_crs_x.json"}' % o)
        out = sh(MON, f"curl -s -m 180 -X POST -H 'Content-Type: application/json' "
                      f"-d '{body}' http://192.0.2.216:8080/api/v1/devices")
        if '"success": true' not in out and '"success":true' not in out:
            raise SystemExit(f"FATAL octet {o}: {out[:300]}")
        for _ in range(60):
            time.sleep(5)
            if nl6_total() >= before + 250: break
    log(f"  nl6 fleet now {nl6_total():,}")


def provision():
    sh(MON, "setsid sh -c '/tmp/prov.sh > /tmp/prov.log 2>&1' </dev/null >/dev/null 2>&1 &", t=60)
    time.sleep(30)
    log("  " + sh(MON, "tail -2 /tmp/prov.log").replace("\n", " | "))


def settle(target):
    """Imports must finish and the service count must arrive. Scans are a covariate."""
    ok_since = None
    for _ in range(240):
        svc = q(f'opennms_collectd_collectableservicecount{{{CJ}}}') or 0
        imp = q(f'opennms_provisiond_importactivethreads{{{CJ}}}') or 0
        scan = q(f'opennms_provisiond_scanactivethreads{{{CJ}}}') or 0
        if svc >= target * 0.995 and imp == 0:
            ok_since = ok_since or time.time()
            held = time.time() - ok_since
            if held >= SETTLE:
                log(f"  settled: {svc:.0f} services, held {held/60:.1f} min (scan={scan:.0f})")
                return True
        else:
            ok_since = None
            log(f"  services={svc:.0f}/{target} import={imp:.0f} scan={scan:.0f}")
        time.sleep(30)
    log("  SETTLE TIMEOUT - measuring anyway, flagged")
    return False


def instrumentation(S, E):
    a, b = S.rstrip("Z"), E.rstrip("Z")
    out = sh(CORE, f"python3 /var/tmp/pm-snmp-latency/durations.py {a} {b} "
                   f"/var/tmp/pm-snmp-latency/capture.log 2>/dev/null | tr -s ' '", jump=True)
    d = {}
    for line in out.split("\n"):
        if "collectData" in line:
            import re
            for f in ("n", "mean", "p95", "max"):
                m = re.search(rf"\b{f}= ?([0-9]+)", line)
                if m: d[f"walk_{f}"] = int(m.group(1))
    return d


def measure(target, settled):
    t0 = datetime.datetime.now(datetime.timezone.utc)
    log(f"  measuring {WINDOW}s")
    time.sleep(WINDOW)
    t1 = datetime.datetime.now(datetime.timezone.utc)
    S, E = t0.strftime("%Y-%m-%dT%H:%M:%SZ"), t1.strftime("%Y-%m-%dT%H:%M:%SZ")
    svc = rng(f'opennms_collectd_collectableservicecount{{{CJ}}}', S, E)
    cpu = rng(f'sum(rate(node_cpu_seconds_total{{{CN},mode!="idle"}}[5m]))', S, E)
    heap = rng(f'java_lang_memory_heapmemoryusage_used{{{CJ}}}/1024/1024/1024', S, E)
    thr = rng(f'opennms_collectd_activethreads{{{CJ}}}', S, E)
    pend = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    ratio = rng(f'opennms_collectd_taskcompletionratio{{{CJ}}}', S, E)
    scan = rng(f'opennms_provisiond_scanactivethreads{{{CJ}}}', S, E)
    gc = rng(f'sum(rate(jvm_gc_collection_seconds_sum{{{CJ}}}[5m]))', S, E)
    gcold = rng(f'rate(java_lang_g1_old_generation_collectioncount{{{CJ}}}[5m])*60', S, E)
    heapmax = rng(f'java_lang_memory_heapmemoryusage_max{{{CJ}}}/1024/1024/1024', S, E)
    mcpu = rng(f'sum(rate(node_cpu_seconds_total{{{MN},mode!="idle"}}[5m]))', S, E)
    NS = 'instance="netsim-benchmark-01:9100"'
    ncpu = rng(f'sum(rate(node_cpu_seconds_total{{{NS},mode!="idle"}}[5m]))', S, E)
    nmem = rng(f'100*(1-node_memory_MemAvailable_bytes{{{NS}}}/node_memory_MemTotal_bytes{{{NS}}})', S, E)
    n = statistics.median(svc) if svc else 0
    c = statistics.mean(cpu) if cpu else 0
    rec = {"target": target, "settled": settled, "window": [S, E],
           "services": n, "core_cores": round(c, 3),
           "core_pct": round(100 * c / 8, 1),
           "mc_per_device": round(1000 * c / n, 4) if n else None,
           "heap_gib": round(statistics.mean(heap), 2) if heap else None,
           "heap_max": round(max(heap), 2) if heap else None,
           "threads_mean": round(statistics.mean(thr), 1) if thr else None,
           "queue_max": max(pend) if pend else None,
           "queue_zero": (min(pend) == 0) if pend else None,
           "ratio_min": round(min(ratio), 4) if ratio else None,
           "ratio_median": round(statistics.median(ratio), 4) if ratio else None,
           "scan_mean": round(statistics.mean(scan), 2) if scan else None,
           "minion_cores": round(statistics.mean(mcpu), 3) if mcpu else None,
           "netsim_cores": round(statistics.mean(ncpu), 3) if ncpu else None,
           "netsim_mem_pct": round(max(nmem), 1) if nmem else None,
           "heap_ceiling": round(statistics.median(heapmax), 2) if heapmax else None,
           "gc_sec_per_sec": round(statistics.mean(gc), 4) if gc else None,
           "gc_old_per_min": round(max(gcold), 2) if gcold else None}
    rec.update(instrumentation(S, E))
    open(RESULTS, "a").write(json.dumps(rec) + "\n")
    log(f"  services={rec['services']:.0f} cpu={rec['core_cores']}c ({rec['core_pct']}%) "
        f"mc/dev={rec['mc_per_device']} heap={rec['heap_gib']}G walk={rec.get('walk_mean')}ms "
        f"L={rec['threads_mean']} q_max={rec['queue_max']} zero={rec['queue_zero']} ratio_med={rec['ratio_median']}")
    return rec


def knee(r):
    reasons = []
    if r["queue_zero"] is False: reasons.append("queue stopped draining")
    rm = r.get("ratio_median")
    if rm is not None and rm < 0.98: reasons.append(f"completion ratio median {rm}")
    if r["core_pct"] > 90: reasons.append(f"core CPU {r['core_pct']}%")
    # NOT a raw heap percentage: G1 fills whatever ceiling it is given, so 95% with
    # zero old-gen collections is comfortable. Measured at 10,055 services: heap
    # 9.47/10.0 with 0 old-gen GC and 2.8% GC time. Pressure is what counts, below.
    ceil = r.get("heap_ceiling") or 10.0
    if r["heap_max"] and r["heap_max"] > ceil * 0.99 and (r.get("gc_sec_per_sec") or 0) > 0.10:
        reasons.append(f"heap {r['heap_max']} GiB of {ceil} WITH GC pressure")
    if r.get("gc_sec_per_sec") and r["gc_sec_per_sec"] > 0.20:
        reasons.append(f"GC {r['gc_sec_per_sec']}s/s (>20% of one core in GC)")
    if r.get("gc_old_per_min") and r["gc_old_per_min"] > 1.0:
        reasons.append(f"old-gen GC {r['gc_old_per_min']}/min (full collections)")
    if r.get("netsim_cores") and r["netsim_cores"] > 3.4: reasons.append(f"GENERATOR cpu {r['netsim_cores']}/4")
    if r.get("netsim_mem_pct") and r["netsim_mem_pct"] > 90: reasons.append(f"GENERATOR mem {r['netsim_mem_pct']}%")
    return reasons


if __name__ == "__main__":
    while subprocess.run(["pgrep", "-f", "scaling.py"], capture_output=True).returncode == 0:
        time.sleep(30)
    log("starting fleet sweep on 8 vCPU / 16 GiB / 10 GiB heap")
    for target, octets in RUNGS:
        log(f"=== RUNG {target:,} devices ===")
        if list(octets):
            grow(octets)
            provision()
        else:
            log("  no growth needed; measuring the fleet as it stands")
        s = settle(target)
        r = measure(target, s)
        k = knee(r)
        if k:
            log(f"!!! KNEE at {r['services']:.0f} services: " + "; ".join(k))
            break
    log("=== sweep complete ===")
