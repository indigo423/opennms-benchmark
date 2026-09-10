#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""One line per minute through an outage test: collector, JVM, machines and the event path.

Prometheus for the gauges; the events and alarms tables on the database VM for the
event path, because eventd and alarmd expose no counters to the JMX exporter.
Short sleeps only: a long sleep in a background shell on this workstation is throttled.
"""
import datetime
import json
import subprocess
import sys
import time
import urllib.parse
import urllib.request

P = "http://192.168.10.40:9090/prometheus"
CJ = 'instance="core-benchmark-01:9299"'
CPU = '100 - avg(rate(node_cpu_seconds_total{{instance="{h}-benchmark-01:9100",mode="idle"}}[1m])) * 100'
Q = {
    "services": f'opennms_collectd_collectableservicecount{{{CJ}}}',
    "pending": f'opennms_collectd_taskqueuependingcount{{{CJ}}}',
    "active": f'opennms_collectd_activethreads{{{CJ}}}',
    "done_s": f'rate(opennms_collectd_taskscompleted{{{CJ}}}[1m])',
    "core%": CPU.format(h="core"), "minion%": CPU.format(h="minion"), "db%": CPU.format(h="db"),
    "heap_gib": f'java_lang_memory_heapmemoryusage_used{{{CJ}}} / 2^30',
    "oldgc_min": f'rate(java_lang_g1_old_generation_collectioncount{{{CJ}}}[5m]) * 60',
    "snmp_mbit": ('rate(node_network_receive_bytes_total{instance="minion-benchmark-01:9100",device="enp6s20"}[1m])'
                  ' * 8 / 1e6'),
    "core_load": 'node_load1{instance="core-benchmark-01:9100"}',
}
LAST_MIN = "eventtime > now() - interval '1 minute'"
SQL = (f"select (select count(*) from events where {LAST_MIN}),"
       f"(select count(*) from events where {LAST_MIN} and eventuei like '%dataCollectionFailed'),"
       f"(select count(*) from events where {LAST_MIN} and eventuei like '%dataCollectionSucceeded'),"
       "(select count(*) from alarms),"
       "(select count(*) from alarms where severity > 3 and alarmacktime is null)")


def q(expr):
    try:
        u = f"{P}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        d = json.load(urllib.request.urlopen(u, timeout=30))["data"]["result"]
        return float(d[0]["value"][1]) if d else float("nan")
    except Exception:
        return float("nan")


def db():
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "StrictHostKeyChecking=no",
           "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
           "-J", "labuser@192.168.10.40", "labuser@db-benchmark-01",
           f"sudo -u postgres psql -qtA -F'|' -d onms_benchmark -c \"{SQL}\""]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout
        row = [ln for ln in out.splitlines() if ln and ln[0].isdigit()]
        return [int(x) for x in row[-1].split("|")] if row else [None] * 5
    except Exception:
        return [None] * 5


out = sys.argv[1]
with open(out, "a") as fh:
    fh.write("time services pending active done_s core% minion% db% heap_gib oldgc_min snmp_mbit core_load "
             "events_1m dcfailed_1m dcsucceeded_1m alarms alarms_open_major\n")
while True:
    t0 = time.time()
    vals = {k: q(e) for k, e in Q.items()}
    ev = db()
    dec = ("done_s", "core%", "minion%", "db%", "heap_gib", "oldgc_min", "snmp_mbit", "core_load")
    line = (datetime.datetime.now(datetime.UTC).strftime("%H:%M:%S") + " " +
            " ".join(f"{vals[k]:.1f}" if k in dec else f"{vals[k]:.0f}" for k in Q) +
            " " + " ".join("-" if x is None else str(x) for x in ev))
    with open(out, "a") as fh:
        fh.write(line + "\n")
    time.sleep(max(1, 60 - (time.time() - t0)))
