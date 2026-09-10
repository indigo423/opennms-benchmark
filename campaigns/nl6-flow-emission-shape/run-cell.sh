#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Capture nl6's flow emission on the wire, for one (build, cadence) cell.
# Usage: run.sh <build> <tick_secs> <window_secs>
set -euo pipefail
BUILD="$1"; TICK="$2"; WINDOW="$3"
IP=$(ip -4 -br a show dev enp1s0 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
[ -n "$IP" ] || IP=$(hostname -I | awk '{print $1}')
OUT="/tmp/cap-${BUILD}-${TICK}s"
rm -f "$OUT.pcap" "$OUT.log"

sudo pkill -f 'nl6-(pre|post)' 2>/dev/null || true
sudo ip netns del nl6sim 2>/dev/null || true
sleep 2

# Collector is this host: nothing listens, so datagrams are still emitted and
# tcpdump observes exactly what left the exporter. A real listener would only
# add a component between nl6 and the measurement.
cd /tmp   # nl6 loads resources/ relative to the working directory
# shellcheck disable=SC2024  # the redirect is the caller's, deliberately: the
# log belongs to the invoking user, only the simulator needs root (TUN/netns).
sudo /tmp/nl6-"$BUILD" \
  -port 8080 \
  -flow-tick-interval "$TICK" \
  -flow-active-timeout 30 \
  -flow-inactive-timeout 15 \
  > "$OUT.log" 2>&1 &
sleep 12

curl -sf -X POST http://localhost:8080/api/v1/devices \
  -H 'Content-Type: application/json' \
  -d "{\"start_ip\":\"10.42.0.1\",\"device_count\":1,\"netmask\":\"16\",
       \"resource_file\":\"cisco_ios.json\",
       \"flow\":{\"collector\":\"$IP:2055\",\"protocol\":\"netflow9\",
                 \"active_timeout\":\"30s\",\"inactive_timeout\":\"15s\"}}" \
  >/dev/null || { echo "DEVICE CREATE FAILED"; tail -5 "$OUT.log"; exit 1; }

# Warm-up so the first fill is behind us, then capture the steady state.
sleep 45
sudo timeout "$((WINDOW+5))" tcpdump -i any -n -w "$OUT.pcap" 'udp port 2055' 2>/dev/null &
TCPD=$!
sleep "$WINDOW"
sudo pkill -INT tcpdump 2>/dev/null || true
wait $TCPD 2>/dev/null || true

curl -sf http://localhost:8080/api/v1/flows/status > "$OUT.status.json" 2>/dev/null || true
sudo pkill -f 'nl6-(pre|post)' 2>/dev/null || true
sleep 2
echo "done ${BUILD} tick=${TICK}s -> $(sudo stat -c %s "$OUT.pcap") bytes"
