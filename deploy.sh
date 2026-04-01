#!/usr/bin/env bash
# deploy.sh — provision lab infrastructure and deploy OpenNMS Horizon
#
# Workflow:
#   1. terraform apply  — creates VMs and writes ansible-inventory.yml
#   2. ansible-playbook bootstrap/site.yml  — installs base tooling
#   3. ansible-playbook ansible-opennms/site.yml  — deploys OpenNMS stack
#
# For KVM and Proxmox the monitoring VM gets a DHCP address on an external
# bridge.  The script SSH-probes that address after the first apply, then
# re-runs apply with -var jump_host=<ip> so the inventory is correct.
#
set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 --provider <azure|kvm|proxmox> [OPTIONS]

Options:
  --provider  <azure|kvm|proxmox>   Target infrastructure provider (required)
  --destroy                         Tear down all lab resources
  --tf-args   "<args>"              Extra arguments passed verbatim to terraform
  -v|-vv|-vvv|-vvvv                 Ansible verbosity
  -h|--help                         Show this message

Examples:
  $0 --provider azure
  $0 --provider kvm
  $0 --provider proxmox
  $0 --provider azure --destroy
  $0 --provider proxmox --tf-args "-var proxmox_insecure=true"
  $0 --provider kvm -vvv
EOF
}

# Print usage to stderr and exit non-zero (used on bad arguments).
error_usage() { usage >&2; exit 1; }

step() { echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    warning: $*" >&2; }

# ── argument parsing ──────────────────────────────────────────────────────────

PROVIDER=""
DESTROY=false
TF_EXTRA_ARGS=""
ANSIBLE_VERBOSITY=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider) PROVIDER="$2"; shift 2 ;;
    --destroy)  DESTROY=true; shift ;;
    --tf-args)  TF_EXTRA_ARGS="$2"; shift 2 ;;
    -v|-vv|-vvv|-vvvv) ANSIBLE_VERBOSITY="$1"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; error_usage ;;
  esac
done

[[ -z "$PROVIDER" ]] && { echo "Error: --provider is required" >&2; error_usage; }
case "$PROVIDER" in
  azure|kvm|proxmox) ;;
  *) echo "Error: provider must be 'azure', 'kvm', or 'proxmox'" >&2; error_usage ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform/$PROVIDER"
TFVARS_FILE="$TF_DIR/${PROVIDER}.tfvars"

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "Error: $TFVARS_FILE not found." >&2
  echo "       Copy ${TFVARS_FILE}.example → $TFVARS_FILE and fill in your values." >&2
  exit 1
fi

# ── provider-specific extra vars ──────────────────────────────────────────────

# Emit extra -var flags needed before a plan/apply (Azure: operator CIDR).
# All log output goes to stderr so it is not captured by callers.
provider_tf_vars() {
  if [[ "$PROVIDER" == "azure" ]]; then
    local op_ip
    op_ip=$(host -4 myip.opendns.com resolver1.opendns.com 2>/dev/null \
            | awk '/has address/ {print $NF; exit}' || true)
    if [[ -n "$op_ip" ]]; then
      info "detected operator IP: $op_ip" >&2
      echo "-var operator_cidr=${op_ip}/32"
    else
      warn "could not detect public IP; SSH access on monitoring VM will be open to *"
    fi
  fi
}

# SSH through the hypervisor to the monitoring VM's management IP and return
# the first non-internal IPv4 address (the DHCP external bridge address).
# Retries for up to 2 minutes.
discover_jump_host() {
  local hypervisor="$1" mgmt_ip="$2" admin_user="$3"
  local jump_host=""
  for i in $(seq 1 24); do
    jump_host=$(ssh \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o ProxyJump="$hypervisor" \
      "${admin_user}@${mgmt_ip}" \
      'ip -4 addr | grep inet | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -v "^192\.0\.2\.\|^127\."' \
      2>/dev/null | head -1 || true)
    [[ -n "$jump_host" ]] && break
    info "waiting for external IP on monitoring VM... ($i/24)"
    sleep 5
  done
  echo "$jump_host"
}

# ── terraform wrappers ────────────────────────────────────────────────────────

tf_init() {
  terraform -chdir="$TF_DIR" init -upgrade -input=false
}

tf_apply() {
  local extra_vars="${1:-}"
  # shellcheck disable=SC2086
  terraform -chdir="$TF_DIR" apply \
    -var-file="../lab.tfvars" \
    -var-file="${PROVIDER}.tfvars" \
    ${extra_vars} \
    -input=false \
    -auto-approve \
    $TF_EXTRA_ARGS
}

tf_destroy() {
  local extra_vars="${1:-}"
  # shellcheck disable=SC2086
  terraform -chdir="$TF_DIR" destroy \
    -var-file="../lab.tfvars" \
    -var-file="${PROVIDER}.tfvars" \
    ${extra_vars} \
    -input=false \
    -auto-approve \
    $TF_EXTRA_ARGS
}

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

# ── destroy path ──────────────────────────────────────────────────────────────

if $DESTROY; then
  step "Destroying infrastructure ($PROVIDER)..."
  tf_init
  tf_destroy "$(provider_tf_vars)"
  rm -f "$REPO_ROOT/ansible-inventory.yml"
  step "Done. All $PROVIDER lab resources destroyed."
  exit 0
fi

# ── deploy path ───────────────────────────────────────────────────────────────

step "[1/3] Provisioning infrastructure ($PROVIDER)..."
tf_init
tf_apply "$(provider_tf_vars)"

# KVM and Proxmox: the monitoring VM's external (jump host) IP is DHCP-assigned
# after boot and cannot be known at plan time.  Discover it via SSH through the
# hypervisor, then re-apply to regenerate the Ansible inventory with ProxyJump.
if [[ "$PROVIDER" == "kvm" || "$PROVIDER" == "proxmox" ]]; then
  IP_MONITORING=$(tf_output ip_monitoring)
  ADMIN_USER=$(tf_output admin_user)

  if [[ "$PROVIDER" == "kvm" ]]; then
    HYPERVISOR=$(tf_output libvirt_host)
  else
    # Proxmox: derive SSH host from the API endpoint URL.
    PROXMOX_ENDPOINT=$(tf_output proxmox_endpoint)
    HYPERVISOR=$(echo "$PROXMOX_ENDPOINT" | sed 's|https\?://||; s|[:/].*||')
  fi

  if [[ -n "$HYPERVISOR" && -n "$IP_MONITORING" ]]; then
    step "Discovering monitoring VM external IP (via $HYPERVISOR → $IP_MONITORING)..."
    JUMP_HOST=$(discover_jump_host "$HYPERVISOR" "$IP_MONITORING" "$ADMIN_USER")

    if [[ -n "$JUMP_HOST" ]]; then
      info "found: $JUMP_HOST — regenerating inventory with jump host..."
      tf_apply "$(provider_tf_vars) -var jump_host=$JUMP_HOST"
    else
      warn "could not discover external IP after 2 minutes; jump host not configured"
    fi
  fi
fi

step "[2/3] Bootstrapping VMs..."
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$REPO_ROOT/bootstrap/site.yml"

step "[3/3] Deploying OpenNMS Horizon..."
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$REPO_ROOT/ansible-opennms/site.yml" \
  --extra-vars="@$REPO_ROOT/opennms-lab-vars.yml"
