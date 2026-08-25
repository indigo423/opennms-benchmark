#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# pace-flow-scenarios §6: does a flow scenario emit at its requested rate ON THE
# WIRE? Usage: run6.sh <rate> <window_secs>
set -euo pipefail
RATE="$1"; WINDOW="$2"
# The veth peer: on-link from inside the nl6sim netns, so flow export needs no
# routing at all. The netns has no route to the host mgmt subnet, which is why
# pointing the collector at the VM address produced "network is unreachable".
IP=10.254.0.1
OUT="/tmp/s6-rate${RATE}-w${WINDOW}"
rm -f "$OUT.pcap" "$OUT.log" "$OUT.report.json"

# Remove the container OUTRIGHT, not just stop it, and delete the veth it left
# behind. A stale veth-sim-host holds the name our own netns setup needs, and
# the result is a fleet with source IPs but no route: every write fails with
# "network is unreachable" while the scenario arms and runs quite happily.
# The ansible role installs nl6 as a SYSTEMD SERVICE running the released
# container. `docker rm -f` is not enough: systemd restarts it within seconds,
# it re-binds :8080, and our own binary then exits with "address already in
# use" -- silently, into a log nobody reads -- while every request goes to the
# RELEASED build. Every earlier run of this script measured v0.22.1.
sudo systemctl stop nl6.service >/dev/null 2>&1 || true
sudo docker rm -f nl6 >/dev/null 2>&1 || true
sudo pkill -f nl6-paced 2>/dev/null || true
sudo ip netns del nl6sim 2>/dev/null || true
sudo ip link del veth-sim-host 2>/dev/null || true
sleep 3

cd /tmp
# shellcheck disable=SC2024  # the redirect is the caller's, deliberately: only
# the simulator needs root (TUN/netns), the log belongs to the invoking user.
sudo ./nl6-paced -port 8080 -flow-tick-interval 5 \
  -flow-active-timeout 30 -flow-inactive-timeout 15 > "$OUT.log" 2>&1 &
sleep 12

# Assert we are talking to OUR build before measuring anything. Without this the
# whole run silently measures whatever else owns the port.
VER=$(curl -sf http://localhost:8080/api/v1/version | python3 -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null || echo "NONE")
if [ "$VER" != "dev" ]; then
  echo "ABORT: :8080 is served by version '$VER', not our dev build" >&2
  tail -3 "$OUT.log" >&2
  exit 1
fi

# Five participants, explicit type so the profile is the one the model used.
curl -sf -X POST http://localhost:8080/api/v1/devices -H 'Content-Type: application/json' \
  -d "{\"start_ip\":\"10.42.0.1\",\"device_count\":5,\"netmask\":\"16\",
       \"resource_file\":\"cisco_ios.json\",
       \"flow\":{\"collector\":\"$IP:2055\",\"protocol\":\"netflow9\",
                 \"active_timeout\":\"30s\",\"inactive_timeout\":\"15s\"}}" >/dev/null

# WARM the caches to the profile population first: that is the state a real run
# starts from, and the state that hid the never-converging defect.
sleep 90

SPEC="{\"participants\":[\"10.42.0.1\",\"10.42.0.2\",\"10.42.0.3\",\"10.42.0.4\",\"10.42.0.5\"],
       \"protocol\":\"netflow9\",\"rate\":$RATE,\"window\":\"${WINDOW}s\",\"drain\":\"5s\",\"seed\":7}"
SID=$(curl -sf -X POST http://localhost:8080/api/v1/scenarios -H 'Content-Type: application/json' \
      -d "$SPEC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
curl -sf -X POST "http://localhost:8080/api/v1/scenarios/$SID/arm" >/dev/null

sudo timeout "$((WINDOW+30))" tcpdump -i any -n -w "$OUT.pcap" 'udp port 2055' 2>/dev/null &
sleep 2
curl -sf -X POST "http://localhost:8080/api/v1/scenarios/$SID/start" >/dev/null
sleep "$((WINDOW+12))"
sudo pkill -INT tcpdump 2>/dev/null || true
sleep 2

curl -sf "http://localhost:8080/api/v1/scenarios/$SID/report" > "$OUT.report.json" 2>/dev/null || true
sudo pkill -f nl6-paced 2>/dev/null || true
echo "done rate=$RATE window=${WINDOW}s -> $(sudo stat -c %s "$OUT.pcap") bytes, id=$SID"
