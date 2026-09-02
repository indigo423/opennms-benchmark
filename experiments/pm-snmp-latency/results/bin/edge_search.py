#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Find the largest fleet that completes a full collection cycle under 8-12 ms/PDU.

Search direction is UPWARD by design. nl6 has no selective delete -- DELETE
/api/v1/devices removes the entire fleet -- so shrinking costs a full rebuild
plus a re-provision, while growing is a few POSTs. Start below the expected
edge and climb.

PASS means the cycle actually completes: the pending queue returns to zero
within the interval AND the median completion ratio is >= 0.99. The ratio is
judged on the median, never the minimum: it is a sawtooth that resets to ~0 at
every cycle boundary, and min() just samples a reset (measured at 12,055:
min 0.0036, median 0.9972).
"""
import json, urllib.request, urllib.parse, ssl, time, datetime, statistics, subprocess

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
P = "https://192.168.10.40/prometheus/api/v1/"
MON = "azureuser@192.168.10.40"
SIM = "azureuser@192.0.2.216"
CJ = 'instance="core-benchmark-01:9299"'
CN = 'instance="core-benchmark-01:9100"'
NS = 'instance="netsim-benchmark-01:9100"'
SETTLE, WINDOW, INTERVAL = 600, 900, 300
RESULTS = "edge-search.jsonl"
NETEM = "netem delay 10ms 2ms"          # uniform 8-12 ms per PDU
START, STEP = 10000, 1000


def log(m): print(f"[{datetime.datetime.now():%H:%M:%S}] {m}", flush=True)


def sh(host, cmd, jump=False, t=600):
    a = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=15"] + (["-J", MON] if jump else []) + [host, cmd]
    try:
        return subprocess.run(a, capture_output=True, text=True, timeout=t).stdout.strip()
    except subprocess.TimeoutExpired:
        return ""


def q(expr):
    d = urllib.parse.urlencode({"query": expr}).encode()
    try:
        r = json.load(urllib.request.urlopen(P + "query", d, context=CTX, timeout=30))["data"]["result"]
        return float(r[0]["value"][1]) if r else None
    except Exception:
        return None


def rng(expr, s, e, step="30"):
    d = urllib.parse.urlencode({"query": expr, "start": s, "end": e, "step": step}).encode()
    r = json.load(urllib.request.urlopen(P + "query_range", d, context=CTX, timeout=90))["data"]["result"]
    return [float(v) for _, v in r[0]["values"]] if r else []


def nl6_total():
    o = sh(MON, "curl -s -m 40 http://192.0.2.216:8080/api/v1/status "
                "| python3 -c 'import json,sys;print(json.load(sys.stdin)[\"data\"][\"total_devices\"])'")
    try: return int(o)
    except ValueError: return -1


def make_batches(octets, count=250):
    for o in octets:
        body = ('{"start_ip":"10.42.%d.1","device_count":%d,"netmask":"16",'
                '"syslog":{"collector":"192.0.2.144:10514"},'
                '"traps":{"collector":"192.0.2.144:10162","mode":"trap"},'
                '"resource_file":"cisco_crs_x.json"}' % (o, count))
        for attempt in range(4):
            out = sh(MON, f"curl -s -m 180 -X POST -H 'Content-Type: application/json' "
                          f"-d '{body}' http://192.0.2.216:8080/api/v1/devices")
            if '"success": true' in out or '"success":true' in out:
                break
            log(f"    retry {attempt+1} octet {o}: {out[:100]!r}")
            time.sleep(10)
        else:
            raise SystemExit(f"FATAL octet {o}")


def provision():
    sh(MON, "setsid sh -c '/tmp/prov.sh > /tmp/prov.log 2>&1' </dev/null >/dev/null 2>&1 &", t=60)
    time.sleep(30)
    log("    " + sh(MON, "tail -1 /tmp/prov.log"))


def settle(target):
    ok = None
    for _ in range(300):
        svc = q(f'opennms_collectd_collectableservicecount{{{CJ}}}') or 0
        imp = q(f'opennms_provisiond_importactivethreads{{{CJ}}}') or 0
        if abs(svc - target) <= max(20, target * 0.005) and imp == 0:
            ok = ok or time.time()
            if time.time() - ok >= SETTLE:
                log(f"    settled at {svc:.0f} services")
                return True
        else:
            ok = None
        time.sleep(30)
    log("    SETTLE TIMEOUT")
    return False


def measure(fleet, settled):
    t0 = datetime.datetime.now(datetime.timezone.utc)
    log(f"    measuring {WINDOW}s")
    time.sleep(WINDOW)
    t1 = datetime.datetime.now(datetime.timezone.utc)
    S, E = t0.strftime("%Y-%m-%dT%H:%M:%SZ"), t1.strftime("%Y-%m-%dT%H:%M:%SZ")
    svc = rng(f'opennms_collectd_collectableservicecount{{{CJ}}}', S, E)
    pend = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    ratio = rng(f'opennms_collectd_taskcompletionratio{{{CJ}}}', S, E)
    thr = rng(f'opennms_collectd_activethreads{{{CJ}}}', S, E)
    cpu = rng(f'sum(rate(node_cpu_seconds_total{{{CN},mode!="idle"}}[5m]))', S, E)
    heap = rng(f'java_lang_memory_heapmemoryusage_used{{{CJ}}}/1024/1024/1024', S, E)
    gc = rng(f'sum(rate(jvm_gc_collection_seconds_sum{{{CJ}}}[5m]))', S, E)
    ncpu = rng(f'sum(rate(node_cpu_seconds_total{{{NS},mode!="idle"}}[5m]))', S, E)
    n = statistics.median(svc) if svc else 0
    drains = (min(pend) == 0) if pend else False
    rmed = statistics.median(ratio) if ratio else 0
    rec = {"fleet": fleet, "services": n, "settled": settled,
           "window": [S, E],
           "queue_drains": drains,
           "queue_max": max(pend) if pend else None,
           "queue_zero_frac": round(sum(1 for x in pend if x == 0) / len(pend), 3) if pend else None,
           "ratio_median": round(rmed, 4),
           "threads_mean": round(statistics.mean(thr), 1) if thr else None,
           "threads_max": max(thr) if thr else None,
           "core_cores": round(statistics.mean(cpu), 3) if cpu else None,
           "core_pct": round(100 * statistics.mean(cpu) / 8, 1) if cpu else None,
           "heap_gib": round(statistics.mean(heap), 2) if heap else None,
           "gc_sec_per_sec": round(statistics.mean(gc), 4) if gc else None,
           "netsim_cores": round(statistics.mean(ncpu), 2) if ncpu else None}
    rec["PASS"] = bool(drains and rmed >= 0.99)
    open(RESULTS, "a").write(json.dumps(rec) + "\n")
    log(f"    services={n:.0f} PASS={rec['PASS']} drains={drains} "
        f"(zero {rec['queue_zero_frac']}) q_max={rec['queue_max']} ratio_med={rec['ratio_median']} "
        f"L={rec['threads_mean']}/{rec['threads_max']} cpu={rec['core_pct']}% heap={rec['heap_gib']}G")
    return rec


if __name__ == "__main__":
    # ---- step 1: let the post-outage churn drain, then see where CPU really sits
    log("step 1: settling 25 min after the rebuild outage")
    time.sleep(1500)
    c = q(f'sum(rate(node_cpu_seconds_total{{{CN},mode!="idle"}}[5m])) ')
    r = q(f'opennms_collectd_taskcompletionratio{{{CJ}}}')
    log(f"  after settle: core {c:.2f} cores ({100*c/8:.0f}%), ratio {r:.4f}, "
        f"scan {q(f'opennms_provisiond_scanactivethreads{{{CJ}}}'):.0f}")

    # ---- step 2: rebuild at 10,000 (delete-all is the only shrink this API has)
    log(f"step 2: rebuilding fleet at {START:,}")
    sh(MON, "curl -s -m 300 -X DELETE http://192.0.2.216:8080/api/v1/devices >/dev/null", t=360)
    for _ in range(90):
        if nl6_total() == 0: break
        time.sleep(5)
    log(f"  cleared ({nl6_total()})")
    make_batches(range(0, START // 250))
    log(f"  nl6 at {nl6_total():,}")
    provision()
    settle(START + 4)

    # ---- step 3: apply the injection
    log(f"step 3: applying '{NETEM}' (uniform 8-12 ms per PDU)")
    log("  " + sh(SIM, f"sudo tc qdisc replace dev enp6s19 root {NETEM} && tc qdisc show dev enp6s19 | head -1",
                  jump=True))
    time.sleep(INTERVAL)

    # ---- step 4: climb until a cycle fails
    fleet = START
    while fleet <= 16000:
        log(f"=== RUNG {fleet:,} devices, 8-12 ms/PDU ===")
        r = measure(fleet, True)
        if not r["PASS"]:
            log(f"!!! EDGE FOUND: {fleet:,} devices does NOT complete a cycle under 8-12 ms")
            break
        log(f"  {fleet:,} completes. growing +{STEP:,}")
        lo = fleet // 250
        make_batches(range(lo, lo + STEP // 250))
        fleet += STEP
        provision()
        settle(fleet + 4)
    log("=== search complete ===")
