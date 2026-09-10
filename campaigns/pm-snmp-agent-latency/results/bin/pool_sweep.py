#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Sweep the Collectd thread pool under agent latency, and stop on the constraint that binds.

Implements the corrected sweep plan from the pool-sizing research: the fleet and
the injected latency are held fixed, the pool is the only variable, and the stop
signals are the ones an I/O-bound pool actually trips rather than the ones a
CPU-oversubscribed pool would.

    pool_sweep.py <results_dir> [--start 100] [--cap 1600] [--fleet 3000]

Per rung: set threads, restart OpenNMS (the pool is read at daemon start), wait
for the service to answer, wait one full cycle plus a settle after the queue is
seen draining, then measure one 900 s window (three cycles) and read every stop
signal. Doubles the pool while throughput still rises at least 20 % per
doubling and no signal fires. The last passing rung is the ceiling; the plan
sets 80 % of it.

Before the first rung, two JVM-startup settings the plan depends on are put in
place once: NativeMemoryTracking (so per-rung native memory can be read) and
MALLOC_ARENA_MAX (so glibc arenas cannot masquerade as thread cost). Both are
recorded in the results so a later reader knows the JVM was not stock.
"""
import argparse
import datetime
import json
import statistics
import subprocess
import time
import urllib.parse
import urllib.request

MON = "labuser@192.168.10.40"
CORE = "core-benchmark-01"
MINION = "minion-benchmark-01"
P = "http://192.168.10.40:9090/prometheus"
CJ = 'instance="core-benchmark-01:9299"'
CN = 'instance="core-benchmark-01:9100"'
MN = 'instance="minion-benchmark-01:9100"'
CONF = "/opt/opennms/etc/opennms.conf"
COLLECTD = "/opt/opennms/etc/collectd-configuration.xml"
INTERVAL, WINDOW, SETTLE = 300, 900, 300
BOOT_TIMEOUT = 600

# Stop thresholds from the plan. Each is a fraction of a limit read from the
# host at start, never a typed constant.
THREADS_FRAC, FDS_FRAC = 0.90, 0.90     # Threads vs TasksMax, FDSize vs NOFILE
RSS_HEADROOM_MB = 1024                  # stop when RSS is within this of VM RAM
CPU_STOP = 80.0                         # the strategy's CPU concern finally applies here
MIN_GAIN = 0.20                         # throughput must rise this much per doubling
DETACH = 0.0                            # set by --detach; peak/pool below this ends the sweep

OUT = None
RESULTS = LOG = None


def log(m):
    line = f"[{datetime.datetime.now(datetime.UTC):%H:%M:%S}Z] {m}"
    print(line, flush=True)
    with open(LOG, "a") as fh:
        fh.write(line + "\n")


def sh(host, cmd, t=180):
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=25", host, cmd],
                       capture_output=True, text=True, timeout=t)
    return "\n".join(ln for ln in r.stdout.splitlines() if not ln.startswith(("*", " ", "/")))


def q(expr, at=None):
    p = {"query": expr}
    if at:
        p["time"] = at
    u = f"{P}/api/v1/query?" + urllib.parse.urlencode(p)
    d = json.load(urllib.request.urlopen(u, timeout=60))["data"]["result"]
    return float(d[0]["value"][1]) if d else float("nan")


def rng(expr, s, e, step="15s"):
    u = f"{P}/api/v1/query_range?" + urllib.parse.urlencode({"query": expr, "start": s, "end": e, "step": step})
    d = json.load(urllib.request.urlopen(u, timeout=90))["data"]["result"]
    return [float(v) for _, v in d[0]["values"]] if d else []


def jvm_pid(host):
    return sh(host, "sudo ps -eo pid,comm --no-headers | awk '$2==\"java\"{print $1; exit}'").strip()


# ---------------------------------------------------------------- host facts
def read_limits():
    """The limits every stop signal is measured against. Read once, never assumed."""
    core = sh(CORE, (
        "echo tasksmax=$(systemctl show -p TasksMax --value opennms.service);"
        "echo nofile=$(systemctl show -p LimitNOFILE --value opennms.service);"
        "echo memtotal_mb=$(awk '/MemTotal/{printf \"%d\",$2/1024}' /proc/meminfo);"
        "echo threads_max=$(cat /proc/sys/kernel/threads-max)"))
    minion = sh(MINION, (
        "echo nofile=$(systemctl show -p LimitNOFILE --value minion.service);"
        "echo tasksmax=$(systemctl show -p TasksMax --value minion.service);"
        "echo ports=$(awk '{print $2-$1}' /proc/sys/net/ipv4/ip_local_port_range)"))
    lim = {"core": dict(kv.split("=") for kv in core.split()),
           "minion": dict(kv.split("=") for kv in minion.split())}
    for side in lim.values():
        for k, v in side.items():
            side[k] = int(v) if v.isdigit() else v
    return lim


def prepare_jvm():
    """One-time: NMT on via opennms.conf, arenas capped via a systemd drop-in.

    Both take effect at the next restart. They go to different places because
    opennms.conf's `export` lines do not reach the JVM environment (none of
    them do; POSTGRES_HOST and the CORE_SERVICE_* flags are consumed by the
    launcher, not passed through), so a glibc tunable has to come from the
    service unit, which is inherited by everything the launcher execs.
    """
    script = (
        "import os,re,subprocess\n"
        f"p='{CONF}'\n"
        "s=open(p).read(); changed=[]\n"
        "if 'NativeMemoryTracking' not in s:\n"
        "    s=re.sub(r'^(ADDITIONAL_MANAGER_OPTIONS=\")', r'\\1-XX:NativeMemoryTracking=summary ',\n"
        "             s, count=1, flags=re.M)\n"
        "    open(p,'w').write(s); changed.append('-XX:NativeMemoryTracking=summary')\n"
        "d='/etc/systemd/system/opennms.service.d'; f=d+'/malloc-arena.conf'\n"
        "if not os.path.exists(f):\n"
        "    os.makedirs(d, exist_ok=True)\n"
        "    open(f,'w').write('[Service]\\nEnvironment=\"MALLOC_ARENA_MAX=4\"\\n')\n"
        "    subprocess.run(['systemctl','daemon-reload'],check=True)\n"
        "    changed.append('MALLOC_ARENA_MAX=4 (unit drop-in)')\n"
        "print(','.join(changed) or 'already in place')\n"
    )
    with open(f"{OUT}/.prep.py", "w") as fh:
        fh.write(script)
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", f"{OUT}/.prep.py", f"{CORE}:/tmp/prep.py"], check=True)
    out = sh(CORE, "sudo python3 /tmp/prep.py; rm -f /tmp/prep.py").strip()
    log(f"  jvm prep: {out}")
    return out


# ------------------------------------------------------------------ one rung
def set_threads(n):
    """Set the pool size in collectd-configuration.xml, on the host, in python.

    The first version did this with sed through ssh. The backreference reached
    sed as a literal "\\1" and replaced the whole root element with it, leaving a
    file that OpenNMS would have refused to parse at the next restart. Now: a
    backup first, a regex applied by python on the host where nothing is
    re-quoted, and xmllint on the result before anything is allowed to restart.
    """
    script = (
        "import re,shutil,subprocess,sys,time\n"
        f"p='{COLLECTD}'\n"
        f"shutil.copy(p, p+'.pool-sweep-bak')\n"
        "s=open(p).read()\n"
        "s2,k=re.subn(r'(<collectd-configuration\\b[^>]*?)threads=\"\\d+\"', "
        f"lambda m: m.group(1)+'threads=\"{n}\"', s, count=1)\n"
        "assert k==1, 'root element threads attribute not found'\n"
        "open(p,'w').write(s2)\n"
        "r=subprocess.run(['xmllint','--noout',p],capture_output=True,text=True)\n"
        "if r.returncode!=0:\n"
        "    shutil.copy(p+'.pool-sweep-bak', p); print('XMLLINT FAILED, restored: '+r.stderr[:200]); sys.exit(2)\n"
        "m=re.search(r'<collectd-configuration[^>]*threads=\"(\\d+)\"', s2)\n"
        "print('threads=\"'+m.group(1)+'\"')\n"
    )
    with open(f"{OUT}/.set_threads.py", "w") as fh:
        fh.write(script)
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", f"{OUT}/.set_threads.py", f"{CORE}:/tmp/set_threads.py"],
                   check=True)
    got = sh(CORE, "sudo python3 /tmp/set_threads.py; rm -f /tmp/set_threads.py").strip()
    assert got == f'threads="{n}"', f"set_threads({n}) on Core reported: {got!r}"


def restart_and_wait():
    sh(CORE, "sudo systemctl restart opennms", t=300)
    # Probe from the Core itself: 192.0.2.0/24 is not routable from the
    # workstation, only via the jump host, and a probe that can never succeed
    # looks exactly like a daemon that never came up.
    t0 = time.time()
    while time.time() - t0 < BOOT_TIMEOUT:
        code = sh(CORE, "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8980/opennms/login.jsp",
                  t=30).strip()
        if code in ("200", "302"):
            break
        time.sleep(10)
    else:
        raise SystemExit("OpenNMS did not answer after restart")
    pid = jvm_pid(CORE)
    # `sudo tr < /proc/PID/environ` opens the redirect in the UNPRIVILEGED shell
    # and reads an empty stream; it reported MALLOC_ARENA_MAX missing for a
    # whole rung while it was present. Open the file as root, in one process.
    flags = sh(CORE, f"sudo sh -c \"tr '\\0' '\\n' < /proc/{pid}/cmdline\" | grep -cE 'NativeMemoryTracking'")
    env = sh(CORE, f"sudo sh -c \"tr '\\0' '\\n' < /proc/{pid}/environ\" | grep -cE '^MALLOC_ARENA_MAX='")
    log(f"  up in {time.time()-t0:.0f}s, pid {pid}, NMT flag {'present' if flags.strip()=='1' else 'MISSING'}, "
        f"MALLOC_ARENA_MAX {'present' if env.strip()=='1' else 'MISSING'}")
    return pid


def wait_steady():
    """One full cycle after boot, then the queue seen at zero, then SETTLE."""
    time.sleep(INTERVAL)
    for _ in range(40):
        if q(f'opennms_collectd_taskqueuependingcount{{{CJ}}}') == 0:
            break
        time.sleep(15)
    time.sleep(SETTLE)


def snapshot(pid, tag):
    """Everything the plan says to capture per rung, from the hosts directly."""
    nmt = sh(CORE, f"sudo -u opennms jcmd {pid} VM.native_memory summary scale=MB 2>/dev/null")
    tp = f"sudo -u opennms jcmd {pid} Thread.print 2>/dev/null"
    states = sh(CORE, f"{tp} | grep 'java.lang.Thread.State' | sort | uniq -c | sort -rn")
    coll = sh(CORE, f"{tp} | grep -A1 'Collectd-Thread' | grep State | sort | uniq -c")
    # Context switches summed over every task from /proc, as a 5 s delta. Not
    # pidstat: its -t layout puts TID in column 4 and a column-position read
    # silently returned 0.0 for both counters when tested. And never the
    # group leader's /proc/PID/status alone, which reports only the main thread.
    csw_awk = "awk '/ctxt_switches/ {s[$1]+=$2} END {printf \"%d %d\", s[\"voluntary_ctxt_switches:\"], " \
              "s[\"nonvoluntary_ctxt_switches:\"]}'"
    csw = sh(CORE, f"a=$(sudo {csw_awk} /proc/{pid}/task/*/status); sleep 5; "
                   f"b=$(sudo {csw_awk} /proc/{pid}/task/*/status); "
                   "echo $a $b | awk '{printf \"%.1f %.1f\", ($3-$1)/5, ($4-$2)/5}'", t=60)
    status = sh(CORE, f"sudo grep -E '^(Threads|FDSize|VmRSS)' /proc/{pid}/status"
                      " | awk '{printf \"%s=%s \", $1, $2}'")
    mpid = jvm_pid(MINION)
    udp_awk = ("awk 'NR==1{for(i=1;i<=NF;i++)h[i]=$i} NR==2{for(i=1;i<=NF;i++) "
               "if(h[i]~/InDatagrams|InErrors|RcvbufErrors|MemErrors/) printf \"%s=%s \",h[i],$i}'")
    mst = sh(MINION, f"sudo grep -E '^(Threads|FDSize)' /proc/{mpid}/status | awk '{{printf \"%s=%s \", $1, $2}}'; "
                     f"echo openfds=$(sudo ls /proc/{mpid}/fd | wc -l); "
                     f"grep -A1 '^Udp:' /proc/net/snmp | {udp_awk}")
    with open(f"{OUT}/rung-{tag}-nmt.txt", "w") as fh:
        fh.write(nmt)
    with open(f"{OUT}/rung-{tag}-threads.txt", "w") as fh:
        fh.write(states + "\n--- Collectd pool ---\n" + coll)

    def kv(s):
        return {k.rstrip(":"): v for k, v in (x.split("=") for x in s.split() if "=" in x)}

    def nmt_mb(cat):
        # "-                    Thread (reserved=1151MB, committed=122MB)"
        for ln in nmt.splitlines():
            t = ln.strip().lstrip("-").strip()
            if t.startswith(cat + " (") and "committed=" in t:
                return int(t.split("committed=")[1].split("MB")[0])
        for ln in nmt.splitlines():
            if ln.startswith("Total:") and cat == "Total" and "committed=" in ln:
                return int(ln.split("committed=")[1].split("MB")[0])
        return None

    c, m = kv(status), kv(mst)
    v, nv = (float(x) for x in csw.split()) if csw.strip() else (float("nan"), float("nan"))
    return {"core_threads": int(c.get("Threads", 0)), "core_fdsize": int(c.get("FDSize", 0)),
            "core_rss_mb": int(c.get("VmRSS", 0)) // 1024,
            "nmt_thread_mb": nmt_mb("Thread"), "nmt_gc_mb": nmt_mb("GC"), "nmt_total_mb": nmt_mb("Total"),
            "csw_vol_per_s": v, "csw_invol_per_s": nv,
            "minion_threads": int(m.get("Threads", 0)), "minion_fdsize": int(m.get("FDSize", 0)),
            "minion_openfds": int(m.get("openfds", 0)),
            "udp_in": int(m.get("InDatagrams", 0)), "udp_inerr": int(m.get("InErrors", 0)),
            "udp_rcvbuferr": int(m.get("RcvbufErrors", 0)), "udp_memerr": int(m.get("MemErrors", 0))}


def measure(threads, pid, lim, prev):
    t0 = datetime.datetime.now(datetime.UTC)
    before = snapshot(pid, f"{threads}-before")
    time.sleep(WINDOW)
    t1 = datetime.datetime.now(datetime.UTC)
    after = snapshot(pid, f"{threads}-after")
    S, E = t0.strftime("%Y-%m-%dT%H:%M:%SZ"), t1.strftime("%Y-%m-%dT%H:%M:%SZ")
    svc = q(f'opennms_collectd_collectableservicecount{{{CJ}}}', E)
    done = q(f'increase(opennms_collectd_taskscompleted{{{CJ}}}[{WINDOW}s])', E)
    pend = rng(f'opennms_collectd_taskqueuependingcount{{{CJ}}}', S, E)
    ratio = rng(f'opennms_collectd_taskcompletionratio{{{CJ}}}', S, E)
    thr = rng(f'opennms_collectd_activethreads{{{CJ}}}', S, E)
    cpu = rng(f'100 - avg(rate(node_cpu_seconds_total{{{CN},mode="idle"}}[5m]))*100', S, E)
    mcpu = rng(f'100 - avg(rate(node_cpu_seconds_total{{{MN},mode="idle"}}[5m]))*100', S, E)
    heap = rng(f'java_lang_memory_heapmemoryusage_used{{{CJ}}}/1073741824', S, E)
    gc = rng(f'rate(java_lang_g1_old_generation_collectioncount{{{CJ}}}[5m])*60', S, E)
    tput = done / WINDOW
    rec = {"threads": threads, "services": svc, "window": [S, E],
           "collections_done": round(done), "required": round(svc / INTERVAL * WINDOW),
           "completion": round(done / (svc / INTERVAL * WINDOW), 4) if svc else None,
           "throughput_per_s": round(tput, 3),
           "gain_vs_prev": round(tput / prev - 1, 3) if prev else None,
           "queue_drains": bool(pend) and min(pend) == 0, "queue_max": max(pend) if pend else None,
           "queue_zero_frac": round(sum(1 for x in pend if x == 0) / len(pend), 3) if pend else None,
           "ratio_median": round(statistics.median(ratio), 4) if ratio else None,
           "threads_mean": round(statistics.mean(thr), 1) if thr else None,
           "threads_max": max(thr) if thr else None,
           "core_cpu_pct": round(statistics.mean(cpu), 1) if cpu else None,
           "core_cpu_max": round(max(cpu), 1) if cpu else None,
           "minion_cpu_pct": round(statistics.mean(mcpu), 1) if mcpu else None,
           "heap_gib": round(statistics.mean(heap), 2) if heap else None,
           "old_gc_per_min": round(statistics.mean(gc), 2) if gc else None,
           "before": before, "after": after}
    rec["PASS"] = bool(rec["queue_drains"] and (rec["ratio_median"] or 0) >= 0.99)

    # ---- stop signals, each against a limit read from the host
    a = after
    stops = []
    if a["core_threads"] >= THREADS_FRAC * lim["core"]["tasksmax"]:
        stops.append(f"core Threads {a['core_threads']} within 10% of TasksMax {lim['core']['tasksmax']}")
    if a["minion_openfds"] >= FDS_FRAC * lim["minion"]["nofile"]:
        stops.append(f"minion open fds {a['minion_openfds']} within 10% of NOFILE {lim['minion']['nofile']}")
    if a["core_rss_mb"] >= lim["core"]["memtotal_mb"] - RSS_HEADROOM_MB:
        stops.append(f"core RSS {a['core_rss_mb']} MB within {RSS_HEADROOM_MB} MB of RAM {lim['core']['memtotal_mb']}")
    if (a["udp_rcvbuferr"] - before["udp_rcvbuferr"]) > 0 or (a["udp_memerr"] - before["udp_memerr"]) > 0:
        dr, dm = a["udp_rcvbuferr"] - before["udp_rcvbuferr"], a["udp_memerr"] - before["udp_memerr"]
        stops.append(f"minion UDP drops in window: RcvbufErrors +{dr} MemErrors +{dm}")
    if rec["core_cpu_pct"] and rec["core_cpu_pct"] >= CPU_STOP:
        stops.append(f"core CPU {rec['core_cpu_pct']}% at or above {CPU_STOP}%")
    if rec["gain_vs_prev"] is not None and rec["gain_vs_prev"] < MIN_GAIN and not DETACH:
        stops.append(f"throughput gain {rec['gain_vs_prev']:+.1%} below {MIN_GAIN:.0%} per doubling")
    rec["peak_frac"] = round(rec["threads_max"] / threads, 3) if rec["threads_max"] else None
    if DETACH and rec["peak_frac"] is not None and rec["peak_frac"] < DETACH:
        stops.append(f"burst peak {rec['threads_max']:.0f} is {rec['peak_frac']:.0%} of pool {threads}, "
                     f"under {DETACH:.0%}: the pool absorbs the scheduling wave")
    rec["stop_signals"] = stops
    with open(RESULTS, "a") as fh:
        fh.write(json.dumps(rec) + "\n")
    log(f"    tput={tput:.2f}/s ({rec['completion']:.1%} of required, gain {rec['gain_vs_prev']}) "
        f"PASS={rec['PASS']} L={rec['threads_mean']}/{rec['threads_max']} (peak {rec['peak_frac']:.0%}) "
        f"cpu={rec['core_cpu_pct']}% "
        f"rss={a['core_rss_mb']}MB nmt_thread={a['nmt_thread_mb']}MB gc={rec['old_gc_per_min']}/min "
        f"invol_csw={a['csw_invol_per_s']}/s minion_fds={a['minion_openfds']} "
        f"udp_drops={a['udp_rcvbuferr']+a['udp_memerr']}")
    for s in stops:
        log(f"    STOP: {s}")
    return rec


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--start", type=int, default=100)
    ap.add_argument("--cap", type=int, default=1600)
    ap.add_argument("--fleet", type=int, default=3000)
    ap.add_argument("--step", type=int, default=0,
                    help="linear increment instead of doubling (0 = double)")
    ap.add_argument("--detach", type=float, default=0.0,
                    help="stop when the window's peak occupancy stays under this fraction of the pool, "
                         "e.g. 0.95; answers how large the pool must be to absorb the scheduling burst")
    a = ap.parse_args()
    OUT = a.out
    RESULTS, LOG = f"{OUT}/pool-sweep.jsonl", f"{OUT}/pool-sweep.log"

    DETACH = a.detach
    mode = f"+{a.step} per rung" if a.step else "doubling"
    log(f"pool sweep: start {a.start}, {mode} to cap {a.cap}, fleet held at {a.fleet:,}"
        + (f", stop when burst peak < {DETACH:.0%} of pool" if DETACH else ""))
    lim = read_limits()
    log(f"  limits: {json.dumps(lim)}")
    with open(f"{OUT}/pool-sweep-limits.json", "w") as fh:
        json.dump(lim, fh, indent=1)
    netem = sh(MINION, "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
                       "labuser@netsim-benchmark-01 'tc qdisc show dev enp6s19' 2>/dev/null | head -1")
    log(f"  netem: {netem.strip()}")
    assert "netem" in netem, "latency injection is not applied; refusing to sweep without the control"
    svc0 = q(f'opennms_collectd_collectableservicecount{{{CJ}}}')
    assert abs(svc0 - a.fleet) < 10, f"fleet is {svc0:.0f}, expected about {a.fleet}"
    prep = prepare_jvm()

    prev = None
    threads = a.start
    last_pass = None
    while threads <= a.cap:
        log(f"=== RUNG threads={threads} ===")
        set_threads(threads)
        pid = restart_and_wait()
        wait_steady()
        rec = measure(threads, pid, lim, prev)
        # The fleet is held at a size the starting pool cannot complete, so an
        # incomplete cycle at a low rung is the expected starting state, not a
        # ceiling. Climb while nothing binds; the interesting events are the
        # first rung that completes, and the first signal that fires.
        if rec["PASS"]:
            if last_pass is None:
                log(f"  first completing pool: threads={threads}")
            last_pass = threads
        if rec["stop_signals"]:
            detached = any(s.startswith("burst peak") for s in rec["stop_signals"])
            log(f"{'=== burst absorbed' if detached else '!!! ceiling'} at threads={threads}: "
                f"{'; '.join(rec['stop_signals'])}")
            break
        if last_pass and not rec["PASS"]:
            log(f"!!! threads={threads} stopped completing after {last_pass} did: regression, stopping")
            break
        prev = rec["throughput_per_s"]
        threads = threads + a.step if a.step else threads * 2
    else:
        log(f"cap {a.cap} reached without a stop")
    if last_pass:
        log(f"=== largest completing pool {last_pass}; plan recommends 80% of the largest pool "
            f"before a stop signal, see the jsonl ===")
    else:
        log("=== no pool size completed the cycle at this fleet within the cap ===")
    log("=== sweep complete ===")
