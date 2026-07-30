#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# A/B driver for riptide#391 (bounded + accounted enrich/persist handoff).
#
# One variable: the image. Baseline is main @ 94bdd4d (which already carries the #389 template-scan
# fix), variant is the PR head. Both images are built from the same Dockerfile in the same session,
# both run with identical env, against the same 4400-exporter nl6 fleet, alternating so that any
# drift in the lab shows up as disagreement between replicates rather than as a fake effect.
#
#   ab-391.sh deploy  <tag> <db>
#   ab-391.sh measure <label> <db> <devices> <window> <outdir>
#
# The measure step refuses to report an idle window: nl6 rejects a scenario while an earlier one
# still holds the participants, and `curl -sf` swallows the 409, which has twice produced a tidy
# table of zeroes that read like a real result.
set -uo pipefail

SUT=labuser@192.168.11.33
CH=ubuntu@192.168.11.34
GEN=192.168.11.73
NL6=http://192.168.11.73:8080

ch() { ssh -q -o BatchMode=yes "$CH" "clickhouse-client --query \"$1\"" 2>/dev/null | tr -d '\r'; }

deploy() {
  local TAG="$1" DB="$2"
  echo "--- deploying riptide:$TAG -> database $DB"
  ssh -q -o BatchMode=yes "$SUT" "sudo docker rm -f riptide >/dev/null 2>&1; \
    sudo docker run -d --name riptide --network host \
      -e TZ=UTC -e LOGGING_LEVEL_ROOT=WARN \
      -e RIPTIDE_CLICKHOUSE_ENDPOINT=http://192.168.11.34:8123 \
      -e RIPTIDE_CLICKHOUSE_USERNAME=default \
      -e RIPTIDE_CLICKHOUSE_DATABASE=$DB \
      -e RIPTIDE_RECEIVERS_IPFIX_TYPE=ipfix \
      -e RIPTIDE_RECEIVERS_IPFIX_HOST=0.0.0.0 \
      -e RIPTIDE_RECEIVERS_IPFIX_PORT=9999 \
      riptide:$TAG >/dev/null" || return 1
  # /readyz turns 200 only once the receiver is bound and listening
  for i in $(seq 1 40); do
    if ssh -q -o BatchMode=yes "$SUT" 'curl -sf -m 3 http://localhost:8080/readyz >/dev/null 2>&1'; then
      echo "    ready after ${i}s"
      ssh -q -o BatchMode=yes "$SUT" 'sudo docker inspect riptide --format "    image={{.Config.Image}} started={{.State.StartedAt}}"'
      return 0
    fi
    sleep 1
  done
  echo "    ERROR: /readyz never came up"; ssh -q "$SUT" 'sudo docker logs --tail 30 riptide'; return 1
}

# nl6 permits one active scenario; a leftover holds the participants and silently starves the run.
clear_scenarios() {
  local ids
  ids=$(curl -sf -m 15 "$NL6/api/v1/scenarios" | python3 -c \
    'import json,sys; print(" ".join(s["id"] for s in json.load(sys.stdin).get("scenarios",[])))' 2>/dev/null)
  for id in $ids; do
    curl -s -m 15 -X POST "$NL6/api/v1/scenarios/$id/stop" >/dev/null 2>&1
    curl -s -m 15 -X DELETE -o /dev/null -w "    cleared $id -> %{http_code}\n" "$NL6/api/v1/scenarios/$id"
  done
}

measure() {
  local LABEL="$1" DB="$2" DEV="$3" WINDOW="$4" OUTDIR="$5"
  mkdir -p "$OUTDIR"
  clear_scenarios

  local T0 ROWS0 T1 ROWS1
  T0=$(ch "SELECT now()")
  ROWS0=$(ch "SELECT count() FROM $DB.flows" 2>/dev/null); ROWS0=${ROWS0:-0}

  ssh -o BatchMode=yes "$GEN" "/tmp/run_scenario.sh $DEV $WINDOW /tmp/ab-${LABEL}.json ${LABEL}" 2>&1 \
    | grep -Ev "^\s*$"

  sleep 12   # let the batch flusher drain before closing the window
  T1=$(ch "SELECT now()")
  ROWS1=$(ch "SELECT count() FROM $DB.flows")
  ch "SYSTEM FLUSH LOGS" >/dev/null

  local INS WROWS SPAN
  INS=$(ch "SELECT count() FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND has(databases,'$DB') AND event_time BETWEEN '$T0' AND '$T1'")
  WROWS=$(ch "SELECT ifNull(sum(written_rows),0) FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND has(databases,'$DB') AND event_time BETWEEN '$T0' AND '$T1'")
  SPAN=$(ch "SELECT toUInt32(dateDiff('second','$T0','$T1'))")

  scp -q -o BatchMode=yes "$GEN:/tmp/ab-${LABEL}.json" "$OUTDIR/nl6-${LABEL}.json" 2>/dev/null
  # the collector's own view of what it shed, straight from the log
  ssh -q -o BatchMode=yes "$SUT" 'sudo docker logs riptide 2>&1 | tail -400' > "$OUTDIR/riptide-${LABEL}.log" 2>/dev/null

  python3 - "$OUTDIR" "$LABEL" "$DB" "$DEV" "$WINDOW" "${ROWS1:-0}" "$ROWS0" "${INS:-0}" "${WROWS:-0}" "${SPAN:-0}" <<'PY'
import json, sys, os, re
outdir, label, db, dev, window, rows1, rows0, ins, wrows, span = sys.argv[1:11]
rows1, rows0, ins, wrows, span, dev = int(rows1), int(rows0), int(ins), int(wrows), int(span), int(dev)
persisted = rows1 - rows0
try:
    s = json.load(open(f"{outdir}/nl6-{label}.json"))["summary"]
    sent, armed, fails = s["in_window"], s.get("participants_armed"), s.get("send_failures")
except Exception:
    sent, armed, fails = 0, None, None

secs = int(re.match(r"^(\d+)([sm])$", window).group(1)) * (60 if window.endswith("m") else 1)
rec = dict(label=label, db=db, devices=dev, window=window, window_s=secs, span_s=span,
           armed=armed, send_failures=fails, sent=sent, persisted=persisted,
           offered_per_s=round(sent / secs, 1) if sent else 0,
           persisted_per_s=round(persisted / secs, 1),
           inserts=ins, rows_per_insert=round(wrows / ins) if ins else 0,
           loss=sent - persisted,
           loss_pct=round(100.0 * (sent - persisted) / sent, 3) if sent else None)
drops = 0
log = f"{outdir}/riptide-{label}.log"
if os.path.exists(log):
    for line in open(log, errors="replace"):
        m = re.search(r"(\d[\d,]*) records dropped so far", line)
        if m:
            drops = max(drops, int(m.group(1).replace(",", "")))
rec["logged_dispatch_drops"] = drops
open(f"{outdir}/steps.jsonl", "a").write(json.dumps(rec) + "\n")

# An idle window must never render as a result.
if rec["persisted_per_s"] < 100 or sent == 0:
    print(f"  !! REFUSING: sent={sent} persisted={persisted} — the window was effectively idle.")
    print("     Check that the scenario armed and no earlier scenario held the participants.")
    sys.exit(3)

print(f"  {label}: offered={rec['offered_per_s']:,.0f}/s  persisted={rec['persisted_per_s']:,.0f}/s  "
      f"loss={rec['loss_pct']}%  inserts={ins} rows/insert={rec['rows_per_insert']:,}  "
      f"armed={armed} send_failures={fails} logged_drops={drops:,}")
PY
}

case "${1:?usage: ab-391.sh deploy|measure ...}" in
  deploy)  shift; deploy "$@" ;;
  measure) shift; measure "$@" ;;
  clear)   clear_scenarios ;;
  *) echo "unknown subcommand $1" >&2; exit 2 ;;
esac
