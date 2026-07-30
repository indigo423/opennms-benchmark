#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Profile the riptide collector during a load window: exact per-thread CPU from
# /proc plus a JFR execution-sample profile, aggregated by thread and hot method.
#
# This is the instrument that found riptide#389 (an O(total-exporters) scan in
# UdpSessionManager.lookupOptions saturating the single Netty event-loop thread at
# ~90% of one core while the parser pool sat at 4.3% per thread). Reach for it
# whenever the ladder plateaus with CPU headroom left: throughput alone cannot
# distinguish "not enough parallelism" from "one thread doing O(n) work".
#
# Run it DURING a steady load window — drive load with ladder.sh / run_scenario.sh
# first, wait for steady state, then start this.
#
# Two recordings are taken, because one setting cannot answer both questions:
#
#   cpu   — settings=profile over the whole window: which thread burns CPU, and on what.
#   parks — a SHORT capture with jdk.ThreadPark/jdk.JavaMonitorEnter at threshold 0: which
#           thread blocks, and where. This matters more than it sounds. settings=profile
#           thresholds ThreadPark at 10 ms, so a pipeline doing ~150k sub-millisecond parks per
#           second shows up as ~1% parked and looks healthy; unthresholded it is revealed as
#           context-switch-bound. Diagnosing riptide's ~61k rows/s ceiling turned entirely on
#           this, and the thresholded view actively pointed the wrong way — jdk.ExecutionSample
#           only samples RUNNABLE threads, so the busiest sampled thread was not the bottleneck
#           while the real one sat parked. Keep the park window short: at 150k parks/s a few
#           seconds is already millions of events.
#
#   $1  ssh target for the SUT            (e.g. labuser@192.168.11.33)
#   $2  window in seconds                 (default 120)
#   $3  output prefix                     (default profile-<utc-timestamp>)
#   $4  container name on the SUT          (default riptide)
#   $5  park sub-window in seconds        (default 3)
#
# Requires: ssh to the SUT, sudo there for `docker exec`, python3 locally.
# The JFR tooling used is the JDK inside the container, so no local JDK needed.
set -uo pipefail

SUT="${1:?usage: profile-listener.sh <ssh-target> [window-seconds] [out-prefix] [container]}"
WINDOW="${2:-120}"
OUT="${3:-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
CONTAINER="${4:-riptide}"
PARK_WINDOW="${5:-3}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== profiling $SUT container=$CONTAINER window=${WINDOW}s -> ${OUT}.* ==="

# ---------------------------------------------------------------- remote capture
# Per-thread CPU is read from /proc/<pid>/task/*/stat (fields 14+15, utime+stime)
# rather than parsed out of top: top's first sample is cumulative since process
# start, which silently inflates every number if you forget to discard it.
#
# Both a by-name and a by-TID view are produced on purpose. /proc/<tid>/comm
# truncates thread names to 15 characters, so "udp-listener-ni" aggregates every
# udp-listener-nio-* thread — that ambiguity once made a single saturated thread
# look like it could have been eight threads at ~11% each. The by-TID view settles
# it. Netty pins a DatagramChannel to one event loop for its lifetime
# (netty#1706), so expect exactly one hot listener thread.
ssh -o BatchMode=yes "$SUT" CONTAINER="$CONTAINER" WINDOW="$WINDOW" 'bash -s' <<'REMOTE' > "${OUT}.cpu.txt" 2>&1
set -uo pipefail
PID=$(pgrep -f riptide.jar | head -1)
if [ -z "${PID:-}" ]; then echo "ERROR: no riptide.jar process found" >&2; exit 1; fi
CLK=$(getconf CLK_TCK)
echo "host_pid=$PID cores=$(nproc) clk_tck=$CLK window=${WINDOW}s"

snap() {
  for t in /proc/$PID/task/*/stat; do
    tid=${t#/proc/$PID/task/}; tid=${tid%/stat}
    awk -v tid="$tid" '{n=$2; gsub(/[()]/,"",n); print tid" "n" "$14+$15}' "$t" 2>/dev/null
  done
}

snap > /tmp/prof-before.txt
sudo docker exec "$CONTAINER" jcmd 1 JFR.start name=probe settings=profile \
  duration="${WINDOW}s" filename=/tmp/probe.jfr >/dev/null 2>&1 \
  && echo "jfr_started=yes" || echo "jfr_started=no"

sleep $((WINDOW + 2))
snap > /tmp/prof-after.txt

python3 - "$CLK" "$WINDOW" <<'PY'
import sys, collections
clk, window = int(sys.argv[1]), int(sys.argv[2])
def load(path):
    by_tid, names = {}, {}
    for line in open(path):
        tid, name, ticks = line.split()
        by_tid[tid] = int(ticks); names[tid] = name
    return by_tid, names
b, _ = load('/tmp/prof-before.txt')
a, names = load('/tmp/prof-after.txt')

per_tid = []
per_name = collections.Counter()
for tid, after in a.items():
    delta = after - b.get(tid, 0)
    if delta <= 0:
        continue
    pct = delta / clk / window * 100
    per_tid.append((pct, tid, names[tid]))
    per_name[names[tid]] += pct
per_tid.sort(reverse=True)

print("\n--- per-thread CPU by NAME (%% of ONE core) — names truncated to 15 chars ---")
for name, pct in per_name.most_common(20):
    print(f"  {name:<24s} {pct:6.1f}%")
total = sum(per_name.values())
print(f"  {'TOTAL':<24s} {total:6.1f}%  = {total/100:.2f} cores")

print("\n--- per-TID CPU (settles name-truncation ambiguity), >0.5% only ---")
for pct, tid, name in per_tid:
    if pct > 0.5:
        print(f"  tid={tid:<8s} {name:<24s} {pct:6.1f}%")

# Liveness gate. An idle JVM produces a tidy table of near-zeroes that reads like
# "no bottleneck here" — the most dangerous possible output for a profiler. Refuse
# instead. This has bitten twice: once when the generator stalled after warm-up, and
# once when a previous run's scenario was still holding the participants so the new
# one was rejected and the devices merely idled.
if total < 5.0:
    print(f"\nERROR: total JVM CPU over the window was {total:.1f}% of one core.\n"
          "The collector was essentially idle, so every number above is meaningless.\n"
          "Check that load is actually running (nl6 scenario armed and in its window,\n"
          "no earlier scenario still holding the participants) and re-run.")
    sys.exit(3)
PY
REMOTE
rc=$?
sed -n '1,200p' "${OUT}.cpu.txt"
[ $rc -ne 0 ] && { echo "remote capture failed; see ${OUT}.cpu.txt" >&2; exit $rc; }

# ------------------------------------------------------------- pull the profile
# jfr print runs in the container's JDK, so the operator box needs no JDK.
ssh -o BatchMode=yes "$SUT" \
  "sudo docker exec $CONTAINER jfr print --events jdk.ExecutionSample /tmp/probe.jfr 2>/dev/null | gzip -c" \
  > "${OUT}.exec.txt.gz" 2>/dev/null

if [ ! -s "${OUT}.exec.txt.gz" ]; then
  echo "WARNING: no execution samples retrieved (JFR may not have been running)" >&2
else
  gunzip -c "${OUT}.exec.txt.gz" | python3 "$HERE/aggregate-jfr-profile.py" | tee "${OUT}.profile.txt"
fi

# keep the raw recording too — allocation and GC events are in there as well
ssh -o BatchMode=yes "$SUT" \
  "sudo docker cp $CONTAINER:/tmp/probe.jfr /tmp/probe.jfr >/dev/null 2>&1; sudo chmod a+r /tmp/probe.jfr" 2>/dev/null
scp -q -o BatchMode=yes "$SUT:/tmp/probe.jfr" "${OUT}.jfr" 2>/dev/null \
  && echo "raw recording: ${OUT}.jfr"

# ---------------------------------------------------- blocking: where does it park?
# Unthresholded, and deliberately brief. Without this the thresholded view above will report a
# near-idle-looking ~1% parked while the pipeline is in fact bound by park/unpark churn.
echo
echo "--- park attribution (${PARK_WINDOW}s, threshold 0) ---"
ssh -o BatchMode=yes "$SUT" CONTAINER="$CONTAINER" PARK_WINDOW="$PARK_WINDOW" 'bash -s' <<'REMOTE' | tee "${OUT}.parks.txt"
set -uo pipefail
cat > /tmp/park.jfc <<'JFC'
<?xml version="1.0" encoding="UTF-8"?>
<configuration version="2.0">
  <event name="jdk.ThreadPark">
    <setting name="enabled">true</setting><setting name="stackTrace">true</setting><setting name="threshold">0 ms</setting>
  </event>
  <event name="jdk.JavaMonitorEnter">
    <setting name="enabled">true</setting><setting name="stackTrace">true</setting><setting name="threshold">0 ms</setting>
  </event>
</configuration>
JFC
sudo docker cp /tmp/park.jfc "$CONTAINER":/tmp/park.jfc >/dev/null 2>&1
sudo docker exec "$CONTAINER" jcmd 1 JFR.start name=parks settings=/tmp/park.jfc \
  duration="${PARK_WINDOW}s" filename=/tmp/parks.jfr >/dev/null 2>&1
sleep $((PARK_WINDOW + 5))
sudo docker exec "$CONTAINER" jfr print --events jdk.ThreadPark /tmp/parks.jfr > /tmp/parks.txt 2>/dev/null

python3 - /tmp/parks.txt "$PARK_WINDOW" <<'PY'
import sys, re, collections
# Skip the generic parking plumbing so the reported site is the queue/future actually waited on.
SKIP = ('jdk.internal.misc.Unsafe.', 'java.util.concurrent.locks.LockSupport.',
        'java.util.concurrent.locks.AbstractQueuedSynchronizer')
window = float(sys.argv[2])
byth = collections.Counter(); sites = collections.defaultdict(collections.Counter)
th = None; in_stack = False; frames = []
def flush():
    global th, frames
    if th is None:
        return
    byth[th] += 1
    site = next((f for f in frames if not f.startswith(SKIP)), frames[0] if frames else '?')
    sites[th][site] += 1
    th = None; frames = []
for line in open(sys.argv[1], errors='replace'):
    s = line.strip()
    if s.startswith('jdk.ThreadPark {'):
        flush(); th = '?'; in_stack = False; frames = []
    elif th is not None:
        m = re.match(r'eventThread\s*=\s*"([^"]+)"', s)
        if m:
            th = m.group(1)
        elif s.startswith('stackTrace = ['):
            in_stack = True
        elif in_stack:
            if s.startswith(']'):
                in_stack = False
            elif s and not s.startswith('...'):
                frames.append(re.sub(r'\s+line:.*$', '', s))
flush()
tot = sum(byth.values())
if not tot:
    print("  no park events — was load actually running?")
else:
    print(f"  total parks: {tot:,} in {window:g}s  =  {tot/window:,.0f}/s")
    print(f"  {'thread':<32} {'parks/s':>10} {'share':>7}")
    for t, c in byth.most_common(8):
        print(f"    {t:<30} {c/window:>10,.0f} {100*c/tot:>6.1f}%")
    for t, _ in byth.most_common(3):
        print(f"\n  === {t} — where it parks ===")
        for f, n in sites[t].most_common(3):
            print(f"     {100*n/byth[t]:>5.1f}%  {f}")
    print("\n  Divide parks/s by rows/s: >1 park per row means the pipeline is paying a "
          "\n  context switch per record, and no amount of CPU headroom will help.")
PY
REMOTE

echo "=== done: ${OUT}.cpu.txt  ${OUT}.profile.txt  ${OUT}.parks.txt  ${OUT}.jfr ==="
