#!/bin/bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Counter-balanced pass: pr runs FIRST in each pair, so that any monotonic lab drift
# now penalises the baseline instead of the variant. If pr still loses here, the effect
# is real; if it wins, the first pass was measuring drift.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
OUT=ab-391-runs
SUT=labuser@192.168.11.33
udp() { ssh -q -o BatchMode=yes "$SUT" "awk '/^Udp:/{l=\$0} END{}  /^Udp: [0-9]/{print \$2, \$4, \$5}' /proc/net/snmp" 2>/dev/null; }
run() {
  local TAG="$1" DB="$2" LABEL="$3"
  ./ab-391.sh deploy "$TAG" "$DB" 2>&1 | grep -E "ready|ERROR"
  local B A
  B=$(udp)
  ./ab-391.sh measure "$LABEL" "$DB" 4300 4m $OUT 2>&1 | grep -E "^  |ERROR|REFUS"
  A=$(udp)
  echo "    udp InDatagrams/InErrors/RcvbufErrors before=[$B] after=[$A]"
  python3 -c "
b='$B'.split(); a='$A'.split()
if len(b)==3 and len(a)==3:
    ind, ie, rb = (int(a[i])-int(b[i]) for i in range(3))
    print(f'    delta: InDatagrams={ind:,} InErrors={ie:,} RcvbufErrors={rb:,}')
"
}
for r in 1 2 3; do
  echo "=========== counter-balanced replicate $r (pr first) ==========="
  run ab-pr391-amd64 riptide_ab391_pr   "cb-pr-4300-r$r"
  run ab-base-amd64  riptide_ab391_base "cb-base-4300-r$r"
done
echo "MATRIX2 COMPLETE"
