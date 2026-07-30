#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
# Run one nl6 IPFIX scenario over the first N devices that target the benchmark SUT.
# $1=participant count  $2=window (go duration)  $3=output json  $4=label
set -uo pipefail
NL6=http://localhost:8080
COUNT="$1"; WINDOW="$2"; OUT="$3"; LABEL="$4"

PARTS=$(curl -sf $NL6/api/v1/devices | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
mine=[x['ip'] for x in d if x.get('flow',{}).get('collector','').startswith('192.168.11.33')]
mine.sort(key=lambda s: tuple(int(p) for p in s.split('.')))
print(','.join('\"%s\"' % ip for ip in mine[:$COUNT]))")

BODY="{\"participants\":[$PARTS],\"protocol\":\"ipfix\",\"rate\":1,\"window\":\"$WINDOW\",\"drain\":\"5s\",\"seed\":7}"
# Fail loudly. nl6 caps the request body at 64 KiB (~4,369 participants at 10.100.x.y address
# lengths) and permits one active scenario; `curl -sf` turns both into an empty string, which then
# renders downstream as a tidy window of zeroes. That has cost two bogus results already.
HTTP=$(curl -s -o /tmp/create-resp.json -w '%{http_code}' -X POST $NL6/api/v1/scenarios \
  -H 'Content-Type: application/json' -d "$BODY")
case "$HTTP" in 2??) ;; *)
  echo "ERROR: scenario create failed http=$HTTP body_bytes=${#BODY}" >&2
  head -c 300 /tmp/create-resp.json >&2; echo >&2
  exit 4 ;;
esac
ID=$(python3 -c 'import json;print(json.load(open("/tmp/create-resp.json"))["id"])')
curl -sf -X POST "$NL6/api/v1/scenarios/$ID/arm" > "/tmp/arm-$ID.json"
EXCL=$(python3 -c "import json;d=json.load(open('/tmp/arm-$ID.json'));print(len(d.get('excluded',[])))" 2>/dev/null || echo "?")
curl -sf -X POST "$NL6/api/v1/scenarios/$ID/start" > /dev/null
echo "$LABEL id=$ID devices=$COUNT window=$WINDOW excluded=$EXCL started=$(date -u +%H:%M:%S)"
SECS=$(python3 -c "
import re
m=re.match(r'^(\d+)(s|m)\$','$WINDOW'); n=int(m.group(1)); print(n*60 if m.group(2)=='m' else n)")
sleep $((SECS + 8))
curl -sf -X POST "$NL6/api/v1/scenarios/$ID/stop" > "$OUT" || curl -sf "$NL6/api/v1/scenarios/$ID/report" > "$OUT"
python3 -c "
import json;s=json.load(open('$OUT'))['summary']
print('  %s: armed=%s in_window=%s offered=%.0f/s failures=%s' % ('$LABEL',s['participants_armed'],s['in_window'],s['in_window']/$SECS,s['send_failures']))"
