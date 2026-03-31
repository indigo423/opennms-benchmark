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
  grep "^$1\s*=" "$TFVARS" | sed 's/[^"]*"\([^"]*\)".*/\1/'
}

# Extract a named entry from a HCL map block (e.g. vm_names { monitoring = "..." })
_extract_vm() {
  grep "^\s*$1\s*=" "$TFVARS" | sed 's/[^"]*"\([^"]*\)".*/\1/'
}

export subnet_mgmt  ; subnet_mgmt=$(  _extract subnet_mgmt)
export subnet_db    ; subnet_db=$(    _extract subnet_db)
export subnet_kafka ; subnet_kafka=$( _extract subnet_kafka)
export subnet_sim   ; subnet_sim=$(   _extract subnet_sim)

# Management IPs
export ip_monitoring    ; ip_monitoring=$(    _extract ip_monitoring)
export ip_database      ; ip_database=$(      _extract ip_database)
export ip_core          ; ip_core=$(          _extract ip_core)
export ip_kafka         ; ip_kafka=$(         _extract ip_kafka)
export ip_minion        ; ip_minion=$(        _extract ip_minion)
export ip_netsim        ; ip_netsim=$(        _extract ip_netsim)
export ip_elasticsearch ; ip_elasticsearch=$( _extract ip_elasticsearch)

# Per-subnet IPs
export ip_database_db  ; ip_database_db=$(  _extract ip_database_db)
export ip_core_db      ; ip_core_db=$(      _extract ip_core_db)
export ip_es_core      ; ip_es_core=$(      _extract ip_es_core)
export ip_kafka_kafka  ; ip_kafka_kafka=$(  _extract ip_kafka_kafka)
export ip_core_kafka   ; ip_core_kafka=$(   _extract ip_core_kafka)
export ip_minion_kafka ; ip_minion_kafka=$( _extract ip_minion_kafka)
export ip_minion_sim   ; ip_minion_sim=$(   _extract ip_minion_sim)
export ip_netsim_sim   ; ip_netsim_sim=$(   _extract ip_netsim_sim)

# VM names (from vm_names map in lab.tfvars)
export vm_name_monitoring    ; vm_name_monitoring=$(   _extract_vm monitoring)
export vm_name_database      ; vm_name_database=$(     _extract_vm database)
export vm_name_core          ; vm_name_core=$(         _extract_vm core)
export vm_name_kafka         ; vm_name_kafka=$(        _extract_vm kafka)
export vm_name_minion        ; vm_name_minion=$(       _extract_vm minion)
export vm_name_netsim        ; vm_name_netsim=$(       _extract_vm netsim)
export vm_name_elasticsearch ; vm_name_elasticsearch=$(_extract_vm elasticsearch)

# --- render -----------------------------------------------------------------
VARS='${subnet_mgmt}${subnet_db}${subnet_kafka}${subnet_sim}'
VARS+='${ip_monitoring}${ip_database}${ip_core}${ip_kafka}${ip_minion}${ip_netsim}${ip_elasticsearch}'
VARS+='${ip_database_db}${ip_core_db}${ip_es_core}'
VARS+='${ip_kafka_kafka}${ip_core_kafka}${ip_minion_kafka}'
VARS+='${ip_minion_sim}${ip_netsim_sim}'
VARS+='${vm_name_monitoring}${vm_name_database}${vm_name_core}${vm_name_kafka}'
VARS+='${vm_name_minion}${vm_name_netsim}${vm_name_elasticsearch}'

outdir="$REPO_ROOT/assets"
mkdir -p "$outdir"
envsubst "$VARS" < "$TPLS/ck1m.svg.tftpl"    > "$outdir/ck1m.svg"
envsubst "$VARS" < "$TPLS/ck1m.drawio.tftpl" > "$outdir/ck1m.drawio"
echo "rendered assets/ck1m.{svg,drawio}"
