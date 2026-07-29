#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
# Ladder driver for the riptide #382 batching benchmark.
# $1 = variant label (batch_off | batch_on)   $2 = outdir   $3 = window   $4... = participant counts
set -uo pipefail
VARIANT="$1"; OUTDIR="$2"; WINDOW="$3"; shift 3
DB="riptide_${VARIANT}"
GEN="192.168.11.73"
CH="ubuntu@192.168.11.34"
mkdir -p "$OUTDIR"

ch() { ssh -o BatchMode=yes "$CH" "clickhouse-client --query \"$1\"" 2>/dev/null | tr -d '\r'; }

echo "=== variant=$VARIANT db=$DB window=$WINDOW rates=$* ==="
for AGG in "$@"; do
  # AGG is a participant count: nl6 rate controls export cadence only, so offered
  # load scales with the number of simulated exporters (~8 flows/s each).
  T0=$(ch "SELECT now()")
  ROWS0=$(ch "SELECT count() FROM $DB.flows")

  ssh -o BatchMode=yes "$GEN" "/tmp/run_scenario.sh $AGG $WINDOW /tmp/${VARIANT}-${AGG}.json step-${AGG}dev" 2>&1 \
    | grep -E "^(step|  step)"

  sleep 12   # let async/batched inserts settle before closing the window
  T1=$(ch "SELECT now()")
  ROWS1=$(ch "SELECT count() FROM $DB.flows")
  ch "SYSTEM FLUSH LOGS" >/dev/null

  INS=$(ch "SELECT count() FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND has(databases,'$DB') AND event_time BETWEEN '$T0' AND '$T1'")
  WROWS=$(ch "SELECT ifNull(sum(written_rows),0) FROM system.query_log WHERE type='QueryFinish' AND query_kind='Insert' AND has(databases,'$DB') AND event_time BETWEEN '$T0' AND '$T1'")
  PARTS=$(ch "SELECT count() FROM system.part_log WHERE event_type='NewPart' AND database='$DB' AND event_time BETWEEN '$T0' AND '$T1'")
  PARTS_FLOWS=$(ch "SELECT count() FROM system.part_log WHERE event_type='NewPart' AND database='$DB' AND table='flows' AND event_time BETWEEN '$T0' AND '$T1'")

  scp -q -o BatchMode=yes "$GEN:/tmp/${VARIANT}-${AGG}.json" "$OUTDIR/nl6-${VARIANT}-${AGG}.json" 2>/dev/null
  SENT=$(python3 -c "import json;print(json.load(open('$OUTDIR/nl6-${VARIANT}-${AGG}.json'))['summary']['in_window'])" 2>/dev/null || echo 0)
  PERSISTED=$((ROWS1 - ROWS0))
  python3 - "$OUTDIR/steps-${VARIANT}.jsonl" <<EOF
import json,sys
rec = dict(variant="$VARIANT", devices=$AGG, window="$WINDOW",
           t0="$T0", t1="$T1", sent=$SENT, persisted=$PERSISTED,
           inserts=${INS:-0}, written_rows=${WROWS:-0}, parts_total=${PARTS:-0}, parts_flows=${PARTS_FLOWS:-0})
rec["loss"] = rec["sent"] - rec["persisted"]
rec["loss_pct"] = round(100.0*rec["loss"]/rec["sent"], 3) if rec["sent"] else None
open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
print("  -> sent=%d persisted=%d loss=%d (%.3f%%) inserts=%d rows/insert=%.0f parts=%d (flows=%d)" % (
    rec["sent"], rec["persisted"], rec["loss"], rec["loss_pct"] or 0.0, rec["inserts"],
    (rec["written_rows"]/rec["inserts"]) if rec["inserts"] else 0, rec["parts_total"], rec["parts_flows"]))
EOF
done
echo "=== $VARIANT ladder complete ==="
