#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Show what a provider currently has deployed, from two directions:
#
#   Terraform state  — what Terraform believes it created
#   the provider     — what actually exists
#
# The gap between them is the point. Terraform state alone cannot answer "did
# the destroy leave anything behind", because a leftover is by definition
# something state no longer tracks. Anything present at the provider but absent
# from state is either an interrupted apply, a failed destroy, or something
# created by hand — and on a metered provider it is billing either way.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROVIDER=""
DEPLOYMENT=""

usage() {
  cat <<EOF
Usage: $0 --provider <aws|azure|kvm|proxmox|vmware> [--deployment <slug>]

Shows deployed resources for PROVIDER: Terraform's view, the provider's view,
and anything that appears in one but not the other.
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider)   PROVIDER="$2"; shift 2 ;;
    --deployment) DEPLOYMENT="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *) echo "Error: unknown argument '$1'" >&2; usage ;;
  esac
done

[[ -z "$PROVIDER" ]] && { echo "Error: --provider is required" >&2; usage; }

case "$PROVIDER" in
  aws|azure|kvm|proxmox|vmware) ;;
  *) echo "Error: unknown provider '$PROVIDER'" >&2; usage ;;
esac

TF_DIR="$REPO_ROOT/terraform/$PROVIDER"
[[ -d "$TF_DIR" ]] || { echo "Error: $TF_DIR does not exist" >&2; exit 1; }

step() { echo; echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    warning: $*" >&2; }

# ── Terraform's view ──────────────────────────────────────────────────────────

step "Terraform state ($PROVIDER)"

STATE="$TF_DIR/terraform.tfstate"
tf_count=0

if [[ ! -f "$STATE" ]]; then
  info "no state file — this provider has never been applied from here"
else
  tf_count=$(python3 - "$STATE" <<'PY'
import json, sys
from collections import Counter
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    print(0); sys.exit()
c = Counter()
for r in s.get("resources", []):
    # data sources are lookups, not things that exist
    if r.get("mode") == "data":
        continue
    c[r["type"]] += len(r.get("instances", []))
total = sum(c.values())
for k, v in sorted(c.items(), key=lambda x: (-x[1], x[0])):
    print(f"    {v:>4}  {k}", file=sys.stderr)
print(f"    serial {s.get('serial', '?')}", file=sys.stderr)
print(total)
PY
)
  if [[ "$tf_count" == "0" ]]; then
    info "state is empty — Terraform believes nothing is deployed"
  fi
  info "-----"
  info "$tf_count resource(s) tracked"
fi

# ── the provider's view ───────────────────────────────────────────────────────

step "Live at the provider ($PROVIDER)"

case "$PROVIDER" in
  aws)
    if ! command -v aws >/dev/null 2>&1; then
      warn "aws CLI not installed — cannot check what actually exists"
      exit 0
    fi
    export AWS_EC2_METADATA_DISABLED=true
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && aws configure export-credentials --format env >/dev/null 2>&1; then
      eval "$(aws configure export-credentials --format env)"
      unset AWS_PROFILE
    fi
    if ! aws sts get-caller-identity >/dev/null 2>&1; then
      warn "no usable AWS credentials — showing Terraform state only"
      warn "sign in first, e.g. aws login"
      exit 0
    fi
    info "account: $(aws sts get-caller-identity --query Account --output text)"

    # Quoted: each element is one AWS CLI filter expression, and the commas
    # are part of it rather than element separators.
    filter=("Name=tag:project,Values=benchmark")
    [[ -n "$DEPLOYMENT" ]] && filter+=("Name=tag:deployment,Values=$DEPLOYMENT")

    # Query each service directly rather than the tagging API: that API keeps
    # returning deleted resources for a day or so, which would report a
    # completed teardown as a pile of leftovers.
    inst=$(aws ec2 describe-instances --filters "${filter[@]}" \
             Name=instance-state-name,Values=pending,running,stopping,stopped \
             --query 'Reservations[].Instances[]' --output json 2>/dev/null || echo '[]')
    n_inst=$(echo "$inst" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')

    n_vpc=$(aws ec2 describe-vpcs --filters "${filter[@]}" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)
    # shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
    n_nat=$(aws ec2 describe-nat-gateways --filter "${filter[@]}" \
              --query 'length(NatGateways[?State==`available`||State==`pending`])' --output text 2>/dev/null || echo 0)
    n_eip=$(aws ec2 describe-addresses --filters "${filter[@]}" --query 'length(Addresses)' --output text 2>/dev/null || echo 0)
    n_eni=$(aws ec2 describe-network-interfaces --filters "${filter[@]}" --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
    n_sub=$(aws ec2 describe-subnets --filters "${filter[@]}" --query 'length(Subnets)' --output text 2>/dev/null || echo 0)
    n_sg=$(aws ec2 describe-security-groups --filters "${filter[@]}" --query 'length(SecurityGroups)' --output text 2>/dev/null || echo 0)
    n_vol=$(aws ec2 describe-volumes --filters "${filter[@]}" --query 'length(Volumes)' --output text 2>/dev/null || echo 0)

    live=$(( n_inst + n_vpc + n_nat + n_eip + n_eni + n_sub + n_sg + n_vol ))

    if [[ "$live" -eq 0 ]]; then
      info "nothing tagged project=benchmark${DEPLOYMENT:+ / deployment=$DEPLOYMENT} exists"
    else
      # Billable first: these are the ones worth noticing after a destroy.
      printf '    %-18s %s\n' "instances"       "$n_inst"
      printf '    %-18s %s\n' "nat gateways"    "$n_nat"
      printf '    %-18s %s\n' "elastic ips"     "$n_eip"
      printf '    %-18s %s\n' "ebs volumes"     "$n_vol"
      printf '    %-18s %s\n' "vpcs"            "$n_vpc"
      printf '    %-18s %s\n' "subnets"         "$n_sub"
      printf '    %-18s %s\n' "security groups" "$n_sg"
      printf '    %-18s %s\n' "network ifaces"  "$n_eni"

      if [[ "$n_inst" -gt 0 ]]; then
        echo
        echo "$inst" | python3 -c '
import json, sys
for i in json.load(sys.stdin):
    name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "?")
    print(f"    {name:<24} {i[\"InstanceType\"]:<12} {i[\"State\"][\"Name\"]:<10} {i.get(\"PrivateIpAddress\",\"-\")}")
'
      fi
    fi

    # ── the bit state alone cannot tell you ───────────────────────────────────
    step "Reconciliation"
    if [[ "$tf_count" -eq 0 && "$live" -gt 0 ]]; then
      warn "$live resource(s) exist at AWS but Terraform tracks none."
      warn "Left over from a failed destroy, or created outside Terraform."
      [[ "$n_nat" -gt 0 || "$n_eip" -gt 0 || "$n_inst" -gt 0 ]] && \
        warn "Some of these bill by the hour. Remove them before they are forgotten."
    elif [[ "$tf_count" -gt 0 && "$live" -eq 0 ]]; then
      warn "Terraform tracks $tf_count resource(s) but none exist at AWS."
      warn "They were probably removed by hand; 'terraform plan' will want to rebuild them."
    elif [[ "$tf_count" -eq 0 && "$live" -eq 0 ]]; then
      info "clean — nothing tracked, nothing deployed"
    else
      info "Terraform tracks $tf_count resource(s); $live tagged resource(s) live at AWS."
      info "Counts differ by design — one Terraform resource is not one AWS object."
      info "Run 'make plan PROVIDER=aws' for an authoritative drift check."
    fi
    ;;

  kvm|proxmox|vmware|azure)
    info "no live query implemented for '$PROVIDER'."
    info "Terraform state above is the only view; 'make plan PROVIDER=$PROVIDER' shows drift."
    ;;
esac

echo
