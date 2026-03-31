#!/usr/bin/env bash
# Render per-provider network diagrams from terraform/modules/diagram/templates/
# without running terraform apply.
#
# Reads subnet CIDRs from terraform/lab.tfvars and uses envsubst to fill
# the .tftpl templates, writing outputs to assets/<provider>/.
#
# Requirements: envsubst  (part of GNU gettext)
#   macOS:  brew install gettext
#   Debian: apt-get install gettext-base
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="$REPO_ROOT/terraform/lab.tfvars"
TPLS="$REPO_ROOT/terraform/modules/diagram/templates"

# --- dependency check -------------------------------------------------------
if ! command -v envsubst &>/dev/null; then
  echo "error: envsubst not found." >&2
  echo "  macOS:  brew install gettext" >&2
  echo "  Debian: apt-get install gettext-base" >&2
  exit 1
fi

# --- parse subnet vars from lab.tfvars --------------------------------------
_extract() {
  grep "^$1" "$TFVARS" | sed 's/[^"]*"\([^"]*\)".*/\1/'
}

export subnet_mgmt  ; subnet_mgmt=$(  _extract subnet_mgmt)
export subnet_db    ; subnet_db=$(    _extract subnet_db)
export subnet_kafka ; subnet_kafka=$( _extract subnet_kafka)
export subnet_sim   ; subnet_sim=$(   _extract subnet_sim)

# --- render for each provider -----------------------------------------------
VARS='${subnet_mgmt}${subnet_db}${subnet_kafka}${subnet_sim}'

for provider in azure kvm proxmox; do
  outdir="$REPO_ROOT/assets/$provider"
  mkdir -p "$outdir"
  envsubst "$VARS" < "$TPLS/ck1m.svg.tftpl"    > "$outdir/ck1m.svg"
  envsubst "$VARS" < "$TPLS/ck1m.drawio.tftpl" > "$outdir/ck1m.drawio"
  echo "rendered assets/$provider/ck1m.{svg,drawio}"
done
