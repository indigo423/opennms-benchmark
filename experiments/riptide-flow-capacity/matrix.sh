#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
OUT=ab-391-runs
for r in 1 2 3; do
  echo "=========== replicate $r ==========="
  ./ab-391.sh deploy ab-base-amd64  riptide_ab391_base 2>&1 | grep -E "ready|ERROR|image="
  ./ab-391.sh measure base-4300-r$r riptide_ab391_base 4300 4m $OUT 2>&1 | grep -E "^  |ERROR|REFUS"
  ./ab-391.sh deploy ab-pr391-amd64 riptide_ab391_pr   2>&1 | grep -E "ready|ERROR|image="
  ./ab-391.sh measure pr-4300-r$r   riptide_ab391_pr   4300 4m $OUT 2>&1 | grep -E "^  |ERROR|REFUS"
done
echo "MATRIX COMPLETE"
