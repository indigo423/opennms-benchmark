#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Full measured sequence for one variant: 5-min ramp window (discarded),
# 3 x 15-min reconciled steady-state windows, query trials over the corpus
# span, run manifest. Assumes apply-variant.sh <variant> has already run.
#   run-variant.sh <variant> [devices]
# shellcheck disable=SC1091,SC2029,SC2086,SC2153
# env.sh resolves at runtime; $SSH_OPTS must word-split; ssh commands
# expand on the client by design - the heredocs carry only local values.
set -euo pipefail
. "$(dirname "$0")/env.sh"
V=${1:?variant}; DEVICES=${2:-200}
BIN="$(dirname "$0")"

"$BIN/run-ingest-window.sh" "$V" "$DEVICES" 5m ramp
for w in w1 w2 w3; do
  "$BIN/run-ingest-window.sh" "$V" "$DEVICES" 15m "$w"
done

T0=$(jq -r '.t0' "$EXP_DIR/results/$V/window-w1/counts.json")
T1=$(jq -r '.t1' "$EXP_DIR/results/$V/window-w3/counts.json")
"$BIN/run-queries.sh" "$V" "$T0" "$T1"
"$BIN/emit-manifest.sh" "$V" "${V##variant-}-1"
echo "=== $V complete ==="
