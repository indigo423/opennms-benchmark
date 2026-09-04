#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Find the fleet size at which Collectd stops completing a cycle under 50-100 ms/PDU.

Search-upward only: nl6 has no selective delete, so every shrink is a full
rebuild. Start small, grow by STEP, stop at the first rung that fails.

Pass criterion: the pending queue returns to zero inside the window AND the
window integral of taskscompleted reaches 97% of the services due. Both
required. The completion-ratio gauge is recorded but not judged; see measure().

Window and settle follow the measurement rules: integer multiples of the 300 s
interval, wall-clock rates, and no measurement until scans are done and the
queue has been observed draining.
"""
import datetime
import json
import statistics
import subprocess
import sys
import time
import urllib.parse
import urllib.request

MON  = "labuser@192.168.10.40"
SIM  = "labuser@netsim-benchmark-01"
P    = "http://192.168.10.40:9090/prometheus"
CJ   = 'instance="core-benchmark-01:9299"'
CN   = 'instance="core-benchmark-01:9100"'
NL6  = "http://192.0.2.216:8080"
NETEM = "netem delay 75ms 25ms"          # uniform 50-100 ms per packet
START, STEP, CAP = 2000, 500, 6000
INTERVAL, WINDOW, SETTLE = 300, 900, 300  # 3 cycles measured; settle >= 1 cycle after scans finish
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
RESULTS, LOG = f"{OUT}/knee-search.jsonl", f"{OUT}/knee-search.log"

def log(m):
    line = f"[{datetime.datetime.now(datetime.UTC):%H:%M:%S}Z] {m}"
    print(line, flush=True)
    with open(LOG, "a") as fh:
        fh.write(line + "\n")

def sh(host, cmd, t=120, jump=False):
    j = ["-J", MON] if jump else []
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25", "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null", *j, host, cmd], capture_output=True, text=True, timeout=t)
    return "\n".join(ln for ln in r.stdout.splitlines() if not ln.startswith(("*", " ", "/")))

def q(expr, at=None):
    p = {"query": expr}
    if at:
        p["time"] = at
    u = f"{P}/api/v1/query?" + urllib.parse.urlencode(p)
    d = json.load(urllib.request.urlopen(u, timeout=60))["data"]["result"]
    return float(d[0]["value"][1]) if d else float("nan")

def rng(expr, s, e, step="15s"):
    d = json.load(urllib.request.urlopen(f"{P}/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": expr, "start": s, "end": e, "step": step}), timeout=90))["data"]["result"]
    return [float(v) for _, v in d[0]["values"]] if d else []

def nl6_total():
    try:
        py = "import json,sys;print(json.load(sys.stdin)[\"data\"][\"total_devices\"])"
        return int(sh(MON, f"curl -s -m 40 {NL6}/api/v1/status | python3 -c '{py}'"))
    except ValueError:
        return -1

def grow(octets):
    for o in octets:
        body = json.dumps({"start_ip": f"10.42.{o}.1", "device_count": 250, "netmask": "16",
                           "syslog": {"collector": "192.0.2.144:10514"},
                           "traps": {"collector": "192.0.2.144:10162", "mode": "trap"},
                           "resource_file": "cisco_crs_x.json"})
        for attempt in range(4):
            out = sh(MON, f"curl -s -m 180 -X POST -H 'Content-Type: application/json' "
                          f"-d '{body}' {NL6}/api/v1/devices")
            if '"success": true' in out or '"success":true' in out:
                break
            log(f"    retry {attempt+1} octet {o}")
            time.sleep(10)
        else:
            raise SystemExit(f"FATAL octet {o}")

def provision():
    log("    " + sh(MON, "sh /tmp/prov.sh 2>&1 | tail -1", t=400))

def wait_scans(expected):
    """Every fleet node must hold 144 SNMP interfaces before a window opens.

    Two nodes with zero interfaces and a null lastcapsdpoll were found on this
    fleet once, counted in the service gauge and yielding nothing. Reconcile
    interfaces against nodes rather than trust the gauge.
    """
    sql = ("select (select count(*) from node where foreignsource='nl6-pm-72m' and nodetype<>'D'),"
           "(select count(*) from node where foreignsource='nl6-pm-72m' and nodetype<>'D' and lastcapsdpoll is null),"
           "(select count(*) from snmpinterface s join node n on n.nodeid=s.nodeid where n.nodetype<>'D')")
    for _ in range(240):
        cmd = f"sudo -u postgres psql -qtA -F'|' -d onms_benchmark -c \"{sql}\""
        row = sh("labuser@db-benchmark-01", cmd, jump=True).strip()
        try:
            active, unscanned, ifs = (int(x) for x in row.split("|"))
        except ValueError:
            time.sleep(30)
            continue
        if active == expected and unscanned == 0 and ifs == expected * 144:
            log(f"    reconciled: {active:,} nodes, {ifs:,} interfaces, 0 unscanned")
            return True
        time.sleep(30)
    log(f"    RECONCILE TIMEOUT: {row}")
    return False

def wait_quiet():
    """Provisiond idle and the queue seen at zero, so the window measures steady state."""
    for _ in range(60):
        sched = q(f'opennms_provisiond_scheduledactivethreads{{{CJ}}}')
        scan = q(f'opennms_provisiond_scanactivethreads{{{CJ}}}')
        if sched == 0 and scan == 0:
            break
        time.sleep(30)
    time.sleep(SETTLE)

def measure(fleet):
    t0 = datetime.datetime.now(datetime.UTC)
    time.sleep(WINDOW)
    t1 = datetime.datetime.now(datetime.UTC)
    S, E = t0.strftime("%Y-%m-%dT%H:%M:%SZ"), t1.strftime("%Y-%m-%dT%H:%M:%SZ")
    svc   = rng(f'opennms_collectd_collectableservicecount{{{CJ}}}', S, E)
    pend  = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    ratio = rng(f'opennms_collectd_taskcompletionratio{{{CJ}}}', S, E)
    thr   = rng(f'opennms_collectd_activethreads{{{CJ}}}', S, E)
    cpu   = rng(f'100 - avg(rate(node_cpu_seconds_total{{{CN},mode="idle"}}[5m]))*100', S, E)
    gc    = rng(f'rate(java_lang_g1_old_generation_collectioncount{{{CJ}}}[5m])*60', S, E)
    done  = q(f'increase(opennms_collectd_taskscompleted{{{CJ}}}[{WINDOW}s])', E)
    n = statistics.median(svc) if svc else 0
    drains = bool(pend) and min(pend) == 0
    rmed = statistics.median(ratio) if ratio else 0
    rec = {"fleet": fleet, "services": n, "netem": NETEM, "pool": q(f'opennms_collectd_maxpoolthreads{{{CJ}}}'),
           "window": [S, E],
           "queue_drains": drains, "queue_min": min(pend) if pend else None, "queue_max": max(pend) if pend else None,
           "queue_zero_frac": round(sum(1 for x in pend if x == 0) / len(pend), 3) if pend else None,
           "ratio_median": round(rmed, 4),
           "threads_mean": round(statistics.mean(thr), 1) if thr else None, "threads_max": max(thr) if thr else None,
           "core_pct": round(statistics.mean(cpu), 1) if cpu else None,
           "old_gc_per_min": round(statistics.mean(gc), 2) if gc else None,
           "collections_done": round(done), "collections_required": round(n / INTERVAL * WINDOW),
           "completion": round(done / (n / INTERVAL * WINDOW), 4) if n else None}
    # Pass = the queue returns to zero inside the window AND the window
    # integral of the completion counter reaches 97% of required. The
    # completion-ratio gauge is deliberately NOT part of it: it is a periodic
    # sawtooth (0.96 -> 1.00 -> 0.96 every cycle) whose median depends on the
    # window's phase, and at pool 200 it marked a 99.2%-complete, fully-draining
    # rung as a knee. The counter's window integral is the honest measure.
    completion = done / (n / INTERVAL * WINDOW) if n else 0.0
    rec["PASS"] = bool(drains and completion >= 0.97)
    rec["ratio_median_informational"] = rec.pop("ratio_median")
    with open(RESULTS, "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    log(f"    services={n:.0f} PASS={rec['PASS']} drains={drains} zero={rec['queue_zero_frac']} "
        f"q_max={rec['queue_max']} ratio={rec['ratio_median_informational']} "
        f"L={rec['threads_mean']}/{rec['threads_max']} cpu={rec['core_pct']}% done={rec['completion']}")
    return rec

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("out", nargs="?", default=OUT)
    ap.add_argument("--start", type=int, default=START, help="first rung to measure; grown to from the current fleet")
    ap.add_argument("--step", type=int, default=STEP)
    ap.add_argument("--fine-above", type=int, default=0, help="above this fleet, step by --fine-step instead")
    ap.add_argument("--fine-step", type=int, default=250)
    ap.add_argument("--cap", type=int, default=CAP)
    ap.add_argument("--label", default="", help="suffix for the result files, e.g. the pool size")
    a = ap.parse_args()
    OUT = a.out
    suffix = f"-{a.label}" if a.label else ""
    RESULTS, LOG = f"{OUT}/knee-search{suffix}.jsonl", f"{OUT}/knee-search{suffix}.log"
    for v in (a.start, a.step, a.fine_step, a.cap):
        assert v % 250 == 0, f"{v} is not a multiple of 250: growth is one /24 of 250 devices at a time"

    pool = q(f'opennms_collectd_maxpoolthreads{{{CJ}}}')
    log(f"knee search: {NETEM}, Collectd pool {pool:.0f}, start {a.start:,}, step {a.step}"
        + (f" then {a.fine_step} above {a.fine_above:,}" if a.fine_above else "") + f", cap {a.cap:,}")
    # The latency is a control here, not something this run applies: refuse to
    # measure without it rather than silently measuring a cleanroom.
    have = sh(SIM, "tc qdisc show dev enp6s19 | head -1", jump=True).strip()
    assert "netem" in have, f"latency injection is not applied on netsim: {have!r}"
    log(f"  netem present: {have}")

    fleet = nl6_total()
    log(f"  fleet now {fleet:,}")
    assert fleet <= a.start, f"fleet {fleet:,} is above the start {a.start:,}; shrinking is a rebuild"
    if fleet < a.start:
        log(f"  growing {fleet:,} -> {a.start:,} before the first rung")
        grow(range(fleet // 250, a.start // 250))
        provision()
        wait_scans(a.start)
        fleet = a.start
    else:
        wait_scans(fleet)
    wait_quiet()

    while fleet <= a.cap:
        log(f"=== RUNG {fleet:,} devices, pool {pool:.0f} ===")
        r = measure(fleet)
        if not r["PASS"]:
            log(f"!!! KNEE: {fleet:,} devices does not complete a cycle under {NETEM} with pool {pool:.0f}")
            break
        step = a.fine_step if (a.fine_above and fleet >= a.fine_above) else a.step
        nxt = fleet + step
        if nxt > a.cap:
            log(f"cap {a.cap:,} reached without failure")
            break
        log(f"  {fleet:,} passes. growing to {nxt:,}")
        grow(range(fleet // 250, nxt // 250))
        provision()
        wait_scans(nxt)
        wait_quiet()
        fleet = nxt
    log("=== search complete ===")
