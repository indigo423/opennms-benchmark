#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Tasks 3.2-3.4: drive one nl6 IPFIX loadtest scenario (create -> arm -> start
# -> report), reconcile the send ledger against Elasticsearch, and write
# build/corpus-identity.json. CALIBRATE=1 runs the same path but skips the
# identity write (used to establish the records-per-event ratio first).
#
# Env: DEVICES (default 200), RATE per device/s (default 25), WINDOW (default
# 8000s), DRAIN (default 30s), TOLERANCE_PCT accepted-vs-sent (default 99.5).
set -euo pipefail

# Offered rate MUST match the ES indexing ceiling (~1.8k docs/s tuned): flow
# volume is ~512 records/device/min (~8.5/s), so ~200 participants saturate the
# sink without ballooning Horizon's persist queue over a long window.
DEVICES="${DEVICES:-200}"
RATE="${RATE:-25}"          # NOTE: no-op for flow protocols
WINDOW="${WINDOW:-23400s}"  # 200 dev x ~8.5/s ≈ 1.7k/s -> 40M in ~6.5h; override for smaller corpora
DRAIN="${DRAIN:-30s}"
TOLERANCE_PCT="${TOLERANCE_PCT:-99.5}"
CALIBRATE="${CALIBRATE:-0}"
NL6_API="${NL6_API:-http://localhost:8081/api/v1}"
ES_URL="${ES_URL:-http://localhost:9200}"

EXP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$EXP_DIR/build"

es_count() { curl -sf "$ES_URL/netflow-*/_count" | jq -r '.count' || echo 0; }

# Participants come from nl6's own device inventory (guessing the IP layout
# breaks past 10.42.0.254 — the fleet rolls into 10.42.1.x).
PARTICIPANTS="$(curl -sf "$NL6_API/devices" | jq --argjson n "$DEVICES" '[.data[].ip] | sort | .[:$n]')"
GOT="$(jq 'length' <<<"$PARTICIPANTS")"
[ "$GOT" = "$DEVICES" ] || { echo "ABORT: nl6 has $GOT devices, need $DEVICES" >&2; exit 1; }
PRE_COUNT="$(es_count)"

SCENARIO="$(jq -n --argjson participants "$PARTICIPANTS" \
  --arg protocol ipfix --argjson rate "$RATE" --arg window "$WINDOW" --arg drain "$DRAIN" \
  '{participants: $participants, protocol: $protocol, rate: $rate,
    window: $window, drain: $drain, seed: 42}')"

ID="$(curl -sf -X POST -H 'Content-Type: application/json' -d "$SCENARIO" \
  "$NL6_API/scenarios" | jq -r '.id')"
echo "scenario $ID created ($DEVICES devices x $RATE/s x $WINDOW)"

ARMED="$(curl -sf -X POST "$NL6_API/scenarios/$ID/arm" | jq -r '.participants_armed')"
[ "$ARMED" = "$DEVICES" ] || { echo "ABORT: armed $ARMED of $DEVICES participants" >&2; exit 1; }

curl -sf -X POST "$NL6_API/scenarios/$ID/start" > /dev/null
echo "scenario $ID started"

while :; do
  PHASE="$(curl -sf "$NL6_API/scenarios/$ID" | jq -r '.phase')"
  case "$PHASE" in
    stopped|completed|finished|done|reported) break;;
    failed|aborted) echo "ABORT: scenario phase=$PHASE" >&2; exit 1;;
  esac
  sleep 30
done

# t0/t1 live on the scenario status (the report summary carries no window).
STATUS="$(curl -sf "$NL6_API/scenarios/$ID")"
REPORT="$EXP_DIR/build/seed-report-$ID.json"
curl -sf "$NL6_API/scenarios/$ID/report" > "$REPORT"
# nl6 renders the ledger natively — keep the human-readable form with the results.
mkdir -p "$EXP_DIR/results/nl6"
curl -sf "$NL6_API/scenarios/$ID/report?format=html" > "$EXP_DIR/results/nl6/seed-report-$ID.html" || true

# summary.* only — the report ALSO carries per-device counters; summing
# recursively double-counts the ledger (measured exactly 2x in calibration).
SENT="$(jq '.summary.sent' "$REPORT")"
FAILURES="$(jq '.summary.send_failures' "$REPORT")"
DROPPED="$(jq '.summary.dropped' "$REPORT")"
if [ "${FAILURES:-0}" != "0" ] || [ "${DROPPED:-0}" != "0" ]; then
  echo "ABORT: generator was the bottleneck (send_failures=$FAILURES dropped=$DROPPED) — rerun lower" >&2
  exit 1
fi

# The persist pipeline drains for minutes after T1 (ES-indexing-bound, measured
# ~1.8k docs/s) — follow the count until it reaches the ledger or plateaus.
LAST=-1; STABLE=0
while :; do
  curl -sf -X POST "$ES_URL/netflow-*/_refresh" > /dev/null || true
  POST_COUNT="$(es_count)"
  ACCEPTED=$((POST_COUNT - PRE_COUNT))
  [ "$ACCEPTED" -ge "$SENT" ] && break
  if [ "$POST_COUNT" = "$LAST" ]; then
    STABLE=$((STABLE + 1))
    [ "$STABLE" -ge 6 ] && { echo "count plateaued at $ACCEPTED of $SENT — no further drain for 3 min"; break; }
  else
    STABLE=0
  fi
  LAST="$POST_COUNT"
  sleep 30
done
RATIO="$(jq -n --argjson a "$ACCEPTED" --argjson s "$SENT" '($a / $s * 100 * 100 | round) / 100')"
echo "ledger sent=$SENT accepted=$ACCEPTED (records/event ratio incl. loss: ${RATIO}%)"

if [ "$CALIBRATE" = "1" ]; then
  echo "CALIBRATION ONLY — no corpus-identity written. Report: $REPORT"
  exit 0
fi

if [ "$ACCEPTED" != "$((POST_COUNT))" ] && [ "$PRE_COUNT" != "0" ]; then
  echo "NOTE: ES held $PRE_COUNT pre-existing docs (calibration debris?) —" >&2
  echo "for a clean corpus, wipe first: curl -X DELETE '$ES_URL/netflow-*'" >&2
fi

OK="$(jq -n --argjson a "$ACCEPTED" --argjson s "$SENT" --argjson t "$TOLERANCE_PCT" \
  '($a >= ($s * $t / 100)) and ($a <= ($s * (200 - $t) / 100))')"
if [ "$OK" != "true" ]; then
  echo "ABORT: accepted=$ACCEPTED outside tolerance ${TOLERANCE_PCT}% of sent=$SENT — corpus rejected" >&2
  exit 1
fi

# Official per-device reconciliation (nl6-reconcile, ships with nl6 releases;
# exit 0 = all keys OK, 1 = LOSS/DUP/MISSING/PHANTOM, 2 = usage). Joins the
# ledger's (protocol, source_ip, collector) tuples against ES per-exporter
# counts — only possible when flow-source-per-device=true gave each device its
# own exporter identity; with shared-socket sourcing (cardinality 1) the
# aggregate check above is the gate and this step is skipped.
# find + sort rather than ls: same alphabetical pick, but safe for paths with
# spaces or newlines (SC2012).
RECONCILE_BIN="${RECONCILE_BIN:-$(find "$EXP_DIR/build" -maxdepth 1 -name 'nl6-reconcile-*' 2>/dev/null | sort | head -1 || true)}"
CARD="$(curl -sf "$ES_URL/netflow-*/_search" -H 'Content-Type: application/json' \
  -d '{"size":0,"aggs":{"card":{"cardinality":{"field":"host"}}}}' | jq -r '.aggregations.card.value')"
if [ -n "$RECONCILE_BIN" ] && [ -x "$RECONCILE_BIN" ] && [ "$CARD" -ge "$DEVICES" ]; then
  COLL="$(jq -r '.counters[0].collector' "$REPORT")"
  { echo "protocol,source_ip,collector,received"
    curl -sf "$ES_URL/netflow-*/_search" -H 'Content-Type: application/json' \
      -d "{\"size\":0,\"aggs\":{\"per_dev\":{\"terms\":{\"field\":\"host\",\"size\":$((DEVICES * 2))}}}}" |
      jq -r --arg c "$COLL" '.aggregations.per_dev.buckets[] | "ipfix,\(.key),\($c),\(.doc_count)"'
  } > "$EXP_DIR/build/received-$ID.csv"
  "$RECONCILE_BIN" -report "$REPORT" -received "$EXP_DIR/build/received-$ID.csv" \
    | tee "$EXP_DIR/results/nl6/reconcile-$ID.txt" \
    || { echo "ABORT: nl6-reconcile found loss/duplication — corpus rejected" >&2; exit 1; }
else
  echo "nl6-reconcile skipped (binary: ${RECONCILE_BIN:-none}; exporter cardinality $CARD vs $DEVICES devices) — aggregate check is the gate"
fi

T0_MS="$(jq -r '.t0' <<<"$STATUS" | python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.stdin.read().strip().replace("Z","+00:00")).timestamp()*1000))')"
T1_MS="$(jq -r '.t1' <<<"$STATUS" | python3 -c 'import sys,datetime;print(int(datetime.datetime.fromisoformat(sys.stdin.read().strip().replace("Z","+00:00")).timestamp()*1000))')"

jq -n --argjson doc_count "$POST_COUNT" \
      --argjson window_start_ms "$T0_MS" --argjson window_end_ms "$T1_MS" \
      --arg scenario_id "$ID" --arg report "$(basename "$REPORT")" \
  '{doc_count: $doc_count, window_start_ms: $window_start_ms, window_end_ms: $window_end_ms,
    scenario_id: $scenario_id, seed_report: $report,
    normalization: "netflow.direction: unknown -> ingress (nl6 emits no IPFIX flowDirection)"}' \
  > "$EXP_DIR/build/corpus-identity.json"

# nl6 does not emit IPFIX flowDirection; OpenNMS filters queries by direction,
# so 'unknown' docs are invisible. Normalize deterministically (doc count is
# unchanged; recorded in the corpus identity below).
NORM="$(curl -sf -X POST "$ES_URL/netflow-*/_update_by_query?refresh=true&wait_for_completion=true&requests_per_second=-1" \
  -H 'Content-Type: application/json' \
  -d '{"script":{"source":"if (ctx._source.netflow != null) { ctx._source.netflow.direction = \"ingress\" } else { ctx._source[\"netflow.direction\"] = \"ingress\" }","lang":"painless"},
       "query":{"term":{"netflow.direction":"unknown"}}}')"
echo "direction normalization: $(jq -c '{total, updated, failures: (.failures|length)}' <<<"$NORM")"
[ "$(jq '.failures|length' <<<"$NORM")" = "0" ] || { echo "ABORT: normalization failures" >&2; exit 1; }

# Ingest tuning off: trials need a searchable, settled index.
curl -sf -X PUT "$ES_URL/netflow-*/_settings" -H 'Content-Type: application/json' \
  -d '{"index.refresh_interval":"1s"}' > /dev/null || true
curl -sf -X POST "$ES_URL/netflow-*/_refresh" > /dev/null || true

# The ledger report and corpus identity travel with the results (task 6.1).
mkdir -p "$EXP_DIR/results/nl6"
cp "$REPORT" "$EXP_DIR/results/nl6/" && cp "$EXP_DIR/build/corpus-identity.json" "$EXP_DIR/results/"

echo "corpus admitted — identity:"
cat "$EXP_DIR/build/corpus-identity.json"
