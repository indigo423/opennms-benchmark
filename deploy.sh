#!/usr/bin/env bash
# deploy.sh — provision infrastructure and bootstrap all VMs, or tear it down
#
# Usage:
#   ./deploy.sh --provider <azure|kvm> [--destroy] [--tf-args "<extra terraform args>"] [-v|-vv|-vvv|-vvvv]
#
# Examples:
#   ./deploy.sh --provider azure
#   ./deploy.sh --provider kvm
#   ./deploy.sh --provider azure --destroy
#   ./deploy.sh --provider azure --tf-args "-var 'operator_cidr=1.2.3.4/32'"
#   ./deploy.sh --provider kvm -vvv

set -euo pipefail

usage() {
  echo "Usage: $0 --provider <azure|kvm> [--destroy] [--tf-args <extra terraform args>] [-v|-vv|-vvv|-vvvv]"
  exit 1
}

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
    *) usage ;;
  esac
done

[[ -z "$PROVIDER" ]] && usage
[[ "$PROVIDER" != "azure" && "$PROVIDER" != "kvm" ]] && { echo "Error: provider must be 'azure' or 'kvm'"; usage; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform/$PROVIDER"

if $DESTROY; then
  echo "==> Destroying infrastructure ($PROVIDER)..."
  cd "$TF_DIR"
  terraform init -upgrade -input=false
  # shellcheck disable=SC2086
  terraform destroy \
    -var-file="../lab.tfvars" \
    -var-file="${PROVIDER}.tfvars" \
    -input=false \
    -auto-approve \
    $TF_EXTRA_ARGS
  rm -f "$REPO_ROOT/ansible-inventory.yml"
  echo "==> Done. All $PROVIDER lab resources destroyed."
  exit 0
fi

echo "==> [1/3] Provisioning infrastructure ($PROVIDER)..."
cd "$TF_DIR"
terraform init -upgrade -input=false
# shellcheck disable=SC2086
terraform apply \
  -var-file="../lab.tfvars" \
  -var-file="${PROVIDER}.tfvars" \
  -input=false \
  -auto-approve \
  $TF_EXTRA_ARGS

# KVM only: auto-discover the monitoring VM's external IP and regenerate the
# inventory with it as the jump host. The IP is DHCP-assigned on br0 and is
# only known after the VM boots, so it cannot be set at plan time.
if [[ "$PROVIDER" == "kvm" ]]; then
  LIBVIRT_HOST=$(terraform output -raw libvirt_host 2>/dev/null || true)
  IP_MONITORING=$(terraform output -raw ip_monitoring 2>/dev/null || true)
  ADMIN_USER=$(terraform output -raw admin_user 2>/dev/null || true)

  if [[ -n "$LIBVIRT_HOST" && -n "$IP_MONITORING" ]]; then
    echo "==> Discovering monitoring VM external IP (SSH via $LIBVIRT_HOST -> $IP_MONITORING)..."
    JUMP_HOST=""
    for i in $(seq 1 24); do
      # ProxyJump through the KVM host to reach monitoring's mgmt IP (NAT network),
      # then query all non-internal IPv4 addresses to find the br0 external IP.
      JUMP_HOST=$(ssh \
        -o StrictHostKeyChecking=no \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ProxyJump="$LIBVIRT_HOST" \
        "${ADMIN_USER}@${IP_MONITORING}" \
        'ip -4 addr | grep inet | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -v "^192\.0\.2\.\|^127\."' \
        2>/dev/null | head -1 || true)
      [[ -n "$JUMP_HOST" ]] && break
      echo "    waiting for external IP... ($i/24)"
      sleep 5
    done

    if [[ -n "$JUMP_HOST" ]]; then
      echo "    found: $JUMP_HOST — regenerating inventory..."
      # shellcheck disable=SC2086
      terraform apply \
        -var-file="../lab.tfvars" \
        -var-file="${PROVIDER}.tfvars" \
        -var "jump_host=$JUMP_HOST" \
        -input=false \
        -auto-approve \
        $TF_EXTRA_ARGS
    else
      echo "    warning: could not discover monitoring external IP after 2 minutes; jump host not configured"
    fi
  fi
fi

echo "==> [2/3] Bootstrapping VMs..."
cd "$REPO_ROOT"
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i ansible-inventory.yml \
  $ANSIBLE_VERBOSITY \
  bootstrap/site.yml

echo "==> [3/3] Deploy OpenNMS Horizon..."
cd "$REPO_ROOT"
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i ansible-inventory.yml \
  $ANSIBLE_VERBOSITY \
  ansible-opennms/site.yml \
  --extra-vars="@./opennms-lab-vars.yml"
