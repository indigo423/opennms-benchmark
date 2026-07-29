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
#   $1  ssh target for the SUT            (e.g. labuser@192.168.11.33)
#   $2  window in seconds                 (default 120)
#   $3  output prefix                     (default profile-<utc-timestamp>)
#   $4  container name on the SUT          (default riptide)
#
# Requires: ssh to the SUT, sudo there for `docker exec`, python3 locally.
# The JFR tooling used is the JDK inside the container, so no local JDK needed.
set -uo pipefail

SUT="${1:?usage: profile-listener.sh <ssh-target> [window-seconds] [out-prefix] [container]}"
WINDOW="${2:-120}"
OUT="${3:-profile-$(date -u +%Y%m%dT%H%M%SZ)}"
CONTAINER="${4:-riptide}"
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

echo "=== done: ${OUT}.cpu.txt  ${OUT}.profile.txt  ${OUT}.jfr ==="
