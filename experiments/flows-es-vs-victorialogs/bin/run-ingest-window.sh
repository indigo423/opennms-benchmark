#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# One reconciled ingest window: nl6 scenario over the fleet, store doc-count
# before/after, vmstat sampling on core + store. Ledger and counts land in
# results/<variant>/window-<label>/.
#   run-ingest-window.sh <variant> <devices> <window e.g. 15m> <label>
# The nl6 'rate' field is export cadence, not flow volume — offered load is
# scaled by device count; the realized number is whatever the ledger says.
# shellcheck disable=SC1091,SC2029,SC2086,SC2153
# env.sh resolves at runtime; $SSH_OPTS must word-split; ssh commands
# expand on the client by design - the heredocs carry only local values.
set -euo pipefail
. "$(dirname "$0")/env.sh"
V=${1:?variant}; DEVICES=${2:?devices}; WINDOW=${3:?window}; LABEL=${4:?label}
OUT="$EXP_DIR/results/$V/window-$LABEL"; mkdir -p "$OUT"

store_count() {
  case "$V" in
    variant-a-es-painless|dual-write)
      curl -sf "http://$STORE_IP:9200/netflow-*/_count" | jq -r '.count // 0' ;;
  esac
  case "$V" in
    variant-b-victorialogs)
      curl -sf "http://$STORE_IP:9428/select/logsql/query" --data-urlencode 'query=* | stats count() as c' | jq -r '.c // 0' ;;
    dual-write)
      curl -sf "http://$STORE_IP:9428/select/logsql/query" --data-urlencode 'query=* | stats count() as c' | jq -r '.c // 0' ;;
  esac
}

# Fleet: ensure DEVICES nl6 devices exporting flows at the core's Multi-UDP-9999.
EXISTING=$(curl -sf "$NL6/api/v1/devices" | jq "[.data[] | select(.flow.collector==\"$CORE_IP:9999\")] | length")
if [ "$EXISTING" -lt "$DEVICES" ]; then
  BODY=$(jq -n --arg n "$((DEVICES - EXISTING))" \
    '{start_ip:"10.42.50.1", device_count:($n|tonumber), netmask:"16",
      flow:{collector:"'"$CORE_IP"':9999", protocol:"ipfix"}}')
  R=$(curl -s -X POST "$NL6/api/v1/devices" -H 'Content-Type: application/json' -d "$BODY")
  echo "$R" | jq -e '.success == true' >/dev/null || { echo "ABORT: fleet create rejected: $R" >&2; exit 1; }
fi

PARTS=$(curl -sf "$NL6/api/v1/devices" | jq -c "[.data[] | select(.flow.collector==\"$CORE_IP:9999\") | .ip] | sort_by(split(\".\") | map(tonumber)) | .[:$DEVICES]")

# Sampling loops (5 s cadence) on both hosts for the whole window.
for H in "$CORE:core" "$STORE:store"; do
  ssh $SSH_OPTS "${H%%:*}" "nohup vmstat 5 > /tmp/vmstat-$LABEL.log 2>&1 & echo \$!" > "$OUT/.pid-${H##*:}"
done

C0=$(store_count); T0=$(python3 -c 'import time;print(int(time.time()*1000))')

BODY=$(jq -n --argjson p "$PARTS" --arg w "$WINDOW" \
  '{participants:$p, protocol:"ipfix", rate:1, window:$w, drain:"10s", seed:7}')
HTTP=$(curl -s -o "$OUT/create.json" -w '%{http_code}' -X POST "$NL6/api/v1/scenarios" -H 'Content-Type: application/json' -d "$BODY")
[[ "$HTTP" =~ ^2 ]] || { echo "ABORT: scenario create http=$HTTP $(head -c 200 "$OUT/create.json")" >&2; exit 4; }
ID=$(jq -r '.id' "$OUT/create.json")
curl -sf -X POST "$NL6/api/v1/scenarios/$ID/arm" > "$OUT/arm.json"
curl -sf -X POST "$NL6/api/v1/scenarios/$ID/start" >/dev/null
echo "window $LABEL: scenario $ID, $DEVICES devices, $WINDOW"

SECS=$(python3 -c "import re;m=re.match(r'^(\d+)(s|m)$','$WINDOW');print(int(m.group(1))*(60 if m.group(2)=='m' else 1))")
sleep $((SECS + 15))
curl -sf -X POST "$NL6/api/v1/scenarios/$ID/stop" > "$OUT/ledger.json" \
  || curl -sf "$NL6/api/v1/scenarios/$ID/report" > "$OUT/ledger.json"

sleep 20   # persist queue drain before the closing count
C1=$(store_count); T1=$(python3 -c 'import time;print(int(time.time()*1000))')

for H in "$CORE:core" "$STORE:store"; do
  ssh $SSH_OPTS "${H%%:*}" "kill $(cat "$OUT/.pid-${H##*:}") 2>/dev/null; cat /tmp/vmstat-$LABEL.log" > "$OUT/vmstat-${H##*:}.log" || true
done

jq -n --arg t0 "$T0" --arg t1 "$T1" --arg c0 "$C0" --arg c1 "$C1" --arg secs "$SECS" \
      --slurpfile l "$OUT/ledger.json" \
  '{t0:($t0|tonumber), t1:($t1|tonumber), window_s:($secs|tonumber),
    store_count_before:($c0|tonumber? // $c0), store_count_after:($c1|tonumber? // $c1),
    offered_in_window:$l[0].summary.in_window, send_failures:$l[0].summary.send_failures,
    dropped:($l[0].summary.dropped // 0)}' > "$OUT/counts.json"
cat "$OUT/counts.json"
