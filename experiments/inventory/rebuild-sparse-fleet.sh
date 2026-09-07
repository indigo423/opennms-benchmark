#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Rebuild an nl6 fleet in the pre-v0.29.0 sparse layout: 250 devices per /24
# starting at .1, which is what nl6 v0.28.0 produced and what any foreign source
# imported before the bump enumerates (#293).
#
# v0.29.0 allocates a batch across all 256 addresses of each /24, so a single
# POST of 11,000 devices from 10.42.0.1 ends at 10.42.42.248 instead of
# 10.42.43.250 and moves 252 addresses. A fresh campaign does not care: the
# requisition is regenerated from nl6's device list. An already-imported foreign
# source does, and this script is how that fleet is restored.
#
# Posting one batch per /24 from .1 lands on exactly .1 to .250 under either
# allocation rule, so this reproduces the old layout on any version.
#
# Usage, on the simulator host:
#   rebuild-sparse-fleet.sh [SUBNETS] [PER_SUBNET] [TRAP_COLLECTOR] [SYSLOG_COLLECTOR]
# Defaults rebuild the 11,000-device pm-snmp fleet. The collectors are the
# Minion's sim-network address and the ports lab-endpoints.yml publishes.
#
# It DELETES the existing fleet first: nl6 keeps devices in memory only, so there
# is nothing to merge with.

set -euo pipefail

SUBNETS="${1:-44}"
PER_SUBNET="${2:-250}"
TRAPS="${3:-192.0.2.144:10162}"
SYSLOG="${4:-192.0.2.144:10514}"
RESOURCE_FILE="${RESOURCE_FILE:-cisco_crs_x.json}"
API="${NL6_URL:-http://localhost:8080}/api/v1/devices"

curl -sS -X DELETE "$API" >/dev/null
sleep 3

for n in $(seq 0 $((SUBNETS - 1))); do
  for _ in 1 2 3 4 5 6 7 8; do
    code=$(curl -s -o /tmp/nl6-rebuild-resp.json -w '%{http_code}' \
      -X POST -H 'Content-Type: application/json' \
      -d "{\"start_ip\":\"10.42.$n.1\",\"device_count\":$PER_SUBNET,\"netmask\":\"16\",\"resource_file\":\"$RESOURCE_FILE\",\"traps\":{\"collector\":\"$TRAPS\",\"mode\":\"trap\",\"community\":\"public\",\"inform_timeout\":\"5s\",\"inform_retries\":2},\"syslog\":{\"collector\":\"$SYSLOG\",\"format\":\"5424\",\"transport\":\"udp\"}}" \
      "$API")
    # Only one creation batch runs at a time; a concurrent POST gets 409 with
    # Retry-After: 5 and creates nothing, so retry rather than skip a subnet.
    [ "$code" = "409" ] || break
    sleep 5
  done
  case "$code" in
    200 | 201 | 202) ;;
    *)
      echo "subnet 10.42.$n.0/24 failed: HTTP $code $(head -c 200 /tmp/nl6-rebuild-resp.json)" >&2
      exit 1
      ;;
  esac
done

echo "posted $SUBNETS batches of $PER_SUBNET; verify with:"
echo "  curl -s $API | python3 -c 'import json,sys; print(len(json.load(sys.stdin)[\"data\"]))'"
