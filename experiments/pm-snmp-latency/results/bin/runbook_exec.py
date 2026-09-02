#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Execute experiments/pm-snmp-latency/RUNBOOK.md, one phase group at a time.

Results append to results.jsonl as each phase lands, so a crash loses at most
the phase in flight. Rate is computed against the WALL-CLOCK window, never the
tool's message-timestamp span -- that conflation is what manufactured a false
40% gain in pm-collectd-threads.
"""
import json, re, subprocess, sys, time, datetime, urllib.request, urllib.parse, ssl, statistics

MON = "azureuser@192.168.10.40"
SIM = "azureuser@192.0.2.216"
SSHO = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=15"]
RESULTS = "results.jsonl"
WINDOW = 900          # 3 collection cycles
SETTLE = 900          # one cycle of settling after a qdisc change
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE


def sh(host, cmd, jump=False):
    a = ["ssh"] + SSHO + (["-J", MON] if jump else []) + [host, cmd]
    r = subprocess.run(a, capture_output=True, text=True, timeout=300)
    return r.stdout.strip(), r.returncode


def log(m):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {m}", flush=True)


def set_qdisc(spec):
    """spec: None to remove all shaping, else the netem/prio command body."""
    if spec is None:
        out, _ = sh(SIM, "sudo tc qdisc del dev enp6s19 root 2>/dev/null; tc qdisc show dev enp6s19", jump=True)
    else:
        out, _ = sh(SIM, f"sudo tc qdisc replace dev enp6s19 root {spec} && tc qdisc show dev enp6s19", jump=True)
    return out.split("\n")[0][:90]


def prom(expr, start, end, step="30"):
    d = urllib.parse.urlencode({"query": expr, "start": start, "end": end, "step": step}).encode()
    u = "https://192.168.10.40/prometheus/api/v1/query_range"
    r = json.load(urllib.request.urlopen(u, d, context=CTX, timeout=60))["data"]["result"]
    return [float(v) for _, v in r[0]["values"]] if r else []


def capture_offsets(tag):
    """--start-offsets takes a PATH, not a JSON string. Write the file on the host."""
    sh(MON, f"/usr/local/bin/kafka-metrics-report --label {tag}-base "
             f"--html /tmp/{tag}-base.html --json /tmp/{tag}-base.json >/dev/null 2>&1")
    out, rc = sh(MON, f"python3 -c \"import json;d=json.load(open('/tmp/{tag}-base.json'));"
                      f"json.dump({{p:v['end'] for p,v in d['offsets'].items()}},"
                      f"open('/tmp/{tag}-start.json','w'));"
                      f"print(open('/tmp/{tag}-start.json').read())\"")
    if rc != 0 or not out.startswith("{"):
        raise SystemExit(f"FATAL: could not capture start offsets for {tag}: {out!r}")
    return f"/tmp/{tag}-start.json"


def read_window(tag, offs_path):
    _, rc = sh(MON, f"/usr/local/bin/kafka-metrics-report --label {tag} --start-offsets {offs_path} "
                    f"--html /tmp/{tag}.html --json /tmp/{tag}.json >/tmp/{tag}.err 2>&1; echo rc=$?")
    out, _ = sh(MON, f"python3 -c \"import json;d=json.load(open('/tmp/{tag}.json'));"
                     f"print(json.dumps({{'totals':d['totals'],'rate':d['rate'],'warnings':d['warnings']}}))\"")
    if not out.startswith("{"):
        err, _ = sh(MON, f"tail -5 /tmp/{tag}.err")
        raise SystemExit(f"FATAL: no sidecar for {tag}. stderr: {err!r}")
    return json.loads(out)


CORE = "azureuser@192.0.2.200"
INSTR = ("/var/tmp/pm-snmp-latency/backfill-from-1500Z.log "
         "/var/tmp/pm-snmp-latency/capture.log")


def instrumentation(S, E):
    """collectData begin->end for the window. 99.9% of these lines are the fleet."""
    a, b = S.rstrip("Z"), E.rstrip("Z")
    out, _ = sh(CORE, f"python3 /var/tmp/pm-snmp-latency/durations.py {a} {b} {INSTR} 2>/dev/null "
                      f"| tr -s ' '", jump=True)
    d = {}
    for line in out.split("\n"):
        if "collectData" in line or "persistQueue" in line:
            k = "collect" if "collectData" in line else "persist"
            for f in ("n", "mean", "median", "p90", "p95", "p99", "max"):
                m = re.search(rf"\b{f}= ?([0-9]+)", line)
                if m:
                    d[f"{k}_{f}"] = int(m.group(1))
        if "mean concurrency" in line:
            m = re.search(r"concurrency ([0-9.]+)", line)
            if m:
                d["L_measured"] = float(m.group(1))
    return d


def phase(tag, spec, settle):
    log(f"=== {tag} ===")
    q = set_qdisc(spec)
    log(f"  qdisc: {q}")
    if settle:
        log(f"  settling {settle}s"); time.sleep(settle)
    t0 = datetime.datetime.now(datetime.timezone.utc)
    offs = capture_offsets(tag)
    log(f"  start offsets captured; measuring {WINDOW}s")
    time.sleep(WINDOW)
    t1 = datetime.datetime.now(datetime.timezone.utc)
    r = read_window(tag, offs)
    S, E = t0.strftime("%Y-%m-%dT%H:%M:%SZ"), t1.strftime("%Y-%m-%dT%H:%M:%SZ")
    C = 'instance="core-benchmark-01:9299"'; M = 'instance="minion-benchmark-01:9100"'
    act = prom(f'opennms_collectd_activethreads{{{C}}}', S, E)
    pend = prom(f'opennms_collectd_taskqueuependingcount{{{C}}}', S, E)
    ratio = prom(f'opennms_collectd_taskcompletionratio{{{C}}}', S, E)
    pkt = prom(f'rate(node_network_transmit_packets_total{{{M},device="enp6s20"}}[2m])', S, E)
    cpu = prom(f'sum(rate(node_cpu_seconds_total{{{M},mode!="idle"}}[2m]))', S, E)
    wall = (t1 - t0).total_seconds()
    samples = r.get("totals", {}).get("samples", 0)
    lam = 3805 / 300.0
    rec = {
        "tag": tag, "qdisc": q, "start": S, "end": E, "wall_s": round(wall, 1),
        "samples": samples,
        "rate_wallclock": round(samples / wall, 1) if wall else 0,
        "rate_tool_span": r.get("rate", {}).get("mean_per_second"),
        "span_s": r.get("rate", {}).get("span_seconds"),
        "coverage": round(r.get("rate", {}).get("span_seconds", 0) / wall, 3) if wall else 0,
        "nodes_seen": r.get("totals", {}).get("nodes_seen"),
        "warnings": r.get("warnings"),
        "threads_mean": round(statistics.mean(act), 2) if act else None,
        "threads_max": max(act) if act else None,
        "W_s": round(statistics.mean(act) / lam, 3) if act else None,
        "queue_mean": round(statistics.mean(pend), 1) if pend else None,
        "queue_max": max(pend) if pend else None,
        "queue_returns_zero": (min(pend) == 0) if pend else None,
        "ratio_min": round(min(ratio), 4) if ratio else None,
        "req_pkt_s": round(statistics.mean(pkt)) if pkt else None,
        "minion_cores": round(statistics.mean(cpu), 2) if cpu else None,
    }
    rec.update(instrumentation(S, E))
    if not samples:
        raise SystemExit(f"FATAL: {tag} read 0 samples while Collectd showed "
                         f"{rec['threads_mean']} mean threads and {rec['req_pkt_s']} pkt/s. "
                         f"That is a silent zero in the harness, not a result. Aborting.")
    with open(RESULTS, "a") as f:
        f.write(json.dumps(rec) + "\n")
    log(f"  samples={rec['samples']:,} wall-rate={rec['rate_wallclock']:,}/s cov={rec['coverage']} "
        f"| collectData mean={rec.get('collect_mean')}ms p95={rec.get('collect_p95')}ms "
        f"max={rec.get('collect_max')}ms | L={rec.get('L_measured')} "
        f"| queue_max={rec['queue_max']} zero={rec['queue_returns_zero']} ratio={rec['ratio_min']}")
    return rec


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "gate"
    if which == "gate":
        p0 = phase("p0-control", None, 300)        # settle after removing the aborted run's qdisc
        p1 = phase("p1-netem0", "netem delay 0ms", SETTLE)
        d = abs(p1["samples"] - p0["samples"]) / p0["samples"] * 100 if p0["samples"] else 999
        log(f"=== GATE: P1 vs P0 delta = {d:.2f}%  ({'PASS' if d <= 1.0 else 'FAIL'}, threshold 1%) ===")
        log("Sweep NOT started - gate result needs review before committing ~3h.")
    elif which == "p2":
        for d_ms in (2, 5, 10, 20, 30, 40):
            r = phase(f"p2-{d_ms}ms", f"netem delay {d_ms}ms", SETTLE)
            if r["queue_returns_zero"] is False:
                log(f"!!! SATURATED at {d_ms} ms/PDU - queue no longer drains between cycles.")
        log("=== P2 sweep complete ===")
    elif which == "rungs":
        # ad-hoc rungs, e.g. `runbook_exec.py rungs 50` to extend the sweep
        for d_ms in [int(x) for x in sys.argv[2:]]:
            r = phase(f"p2-{d_ms}ms", f"netem delay {d_ms}ms", SETTLE)
            if r["queue_returns_zero"] is False:
                log(f"!!! SATURATED at {d_ms} ms/PDU - queue no longer drains between cycles.")
        log("=== extra rungs complete ===")
