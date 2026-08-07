#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Timed trials of the fixed query set against the core flow REST API.
#   run-queries.sh <variant-or-label> <T0-ms> <T1-ms> [trials]
# Results: results/<label>/queries/timings.jsonl (+ raw bodies of trial 2 for
# the correctness diff). Trial 1 is warmup and discarded by the report.
# shellcheck disable=SC1091,SC2029,SC2086,SC2153
# env.sh resolves at runtime; $SSH_OPTS must word-split; ssh commands
# expand on the client by design - the heredocs carry only local values.
set -euo pipefail
. "$(dirname "$0")/env.sh"
L=${1:?label}; T0=${2:?t0-ms}; T1=${3:?t1-ms}; TRIALS=${4:-6}
OUT="$EXP_DIR/results/$L/queries"; mkdir -p "$OUT/raw"

STEP_DENSE=$(( (T1 - T0) / 288 ))
STEP_SPARSE=$(( (T1 - T0) / 4500 ))

# Variant A only: the shard request cache would otherwise answer repeated
# identical queries (measured 10.7 s cold vs 0.04 s cached in nms-20027).
if curl -sf "http://$STORE_IP:9200" >/dev/null 2>&1; then
  curl -sf -X PUT "http://$STORE_IP:9200/netflow-*/_settings" \
    -H 'Content-Type: application/json' -d '{"index.requests.cache.enable": false}' >/dev/null || true
fi

: > "$OUT/timings.jsonl"
N=$(jq '.queries | length' "$EXP_DIR/queries/queries.json")
for trial in $(seq 1 "$TRIALS"); do
  for i in $(seq 0 $((N - 1))); do
    NAME=$(jq -r ".queries[$i].name" "$EXP_DIR/queries/queries.json")
    SHAPE=$(jq -r ".queries[$i].shape" "$EXP_DIR/queries/queries.json")
    P=$(jq -r ".queries[$i].path" "$EXP_DIR/queries/queries.json" \
      | sed "s/\${T0}/$T0/g; s/\${T1}/$T1/g; s/\${STEP_DENSE}/$STEP_DENSE/g; s/\${STEP_SPARSE}/$STEP_SPARSE/g")
    BODY_FILE=/dev/null
    [ "$trial" -eq 2 ] && BODY_FILE="$OUT/raw/$NAME.json"
    R=$(curl -s -u admin:admin -o "$BODY_FILE" -w '{"code":%{http_code},"time_s":%{time_total}}' "$BASE_URL$P")
    echo "$R" | jq -c --arg n "$NAME" --arg s "$SHAPE" --argjson t "$trial" \
      '. + {name:$n, shape:$s, trial:$t}' >> "$OUT/timings.jsonl"
  done
  echo "trial $trial/$TRIALS done"
done
jq -s 'group_by(.name) | map({name:.[0].name, shape:.[0].shape,
  median_s:(map(select(.trial>1).time_s)|sort|.[length/2|floor]),
  errors:(map(select(.code!=200))|length)})' "$OUT/timings.jsonl"
