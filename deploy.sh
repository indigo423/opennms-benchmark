#!/usr/bin/env bash
# deploy.sh — provision lab infrastructure and deploy OpenNMS Horizon
#
# Workflow:
#   1. terraform apply             — creates VMs and writes ansible-inventory.yml
#   2. ansible-playbook bootstrap  — installs base tooling
#   3. ansible-galaxy collection install — pulls indigo423.opennms and friends
#   4. ansible-playbook opennms    — deploys OpenNMS stack
#   5. ansible-playbook endpoints — writes lab-endpoints.yml, the manifest
#                                    of what listens where on this deployment
#
# For KVM and Proxmox the monitoring VM gets a DHCP address on an external
# bridge.  The script SSH-probes that address after the first apply, then
# re-runs apply with -var jump_host=<ip> so the inventory is correct.
#
set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $0 --provider <aws|azure|kvm|proxmox|vmware> [OPTIONS]

Options:
  --provider   <aws|azure|kvm|proxmox|vmware>  Target infrastructure provider (required)
  --deployment <slug>               Deployment topology from deployments/<slug>/ (kvm; default baseline)
  --destroy                         Tear down all lab resources
  --tf-args    "<args>"             Extra arguments passed verbatim to terraform
  -v|-vv|-vvv|-vvvv                 Ansible verbosity
  -h|--help                         Show this message

Examples:
  $0 --provider azure
  $0 --provider kvm
  $0 --provider kvm --deployment mimir-single
  $0 --provider proxmox
  $0 --provider vmware
  $0 --provider azure --destroy
  $0 --provider proxmox --tf-args "-var proxmox_insecure=true"
  $0 --provider vmware --tf-args "-var vsphere_insecure=true"
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
TF_EXTRA_ARGS=()
ANSIBLE_VERBOSITY=""
DEPLOYMENT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider)   PROVIDER="$2"; shift 2 ;;
    --deployment) DEPLOYMENT="${2:?--deployment requires a value}"; shift 2 ;;
    --destroy)    DESTROY=true; shift ;;
    --tf-args)    read -ra TF_EXTRA_ARGS <<< "$2"; shift 2 ;;
    -v|-vv|-vvv|-vvvv) ANSIBLE_VERBOSITY="$1"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Error: unknown option: $1" >&2; error_usage ;;
  esac
done

[[ -z "$PROVIDER" ]] && { echo "Error: --provider is required" >&2; error_usage; }
case "$PROVIDER" in
  aws|azure|kvm|proxmox|vmware) ;;
  *) echo "Error: provider must be 'aws', 'azure', 'kvm', 'proxmox', or 'vmware'" >&2; error_usage ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ansible.cfg is the single source of truth for roles_path, and Ansible only
# picks it up from the current directory. Every path below is absolute, so the
# caller's cwd is otherwise irrelevant — but without this, invoking the script
# from anywhere other than the repo root loses deployments/roles and fails with
# "the role 'clickhouse' was not found".
export ANSIBLE_CONFIG="$REPO_ROOT/ansible.cfg"
TF_DIR="$REPO_ROOT/terraform/$PROVIDER"
TFVARS_FILE="$TF_DIR/${PROVIDER}.tfvars"

# lab.tfvars is provider-agnostic. lab-addresses.tfvars carries the legacy
# per-host address scheme (#161); aws derives every address from the deployment
# spec and declares none of it, so passing the file would produce a screenful of
# "Value for undeclared variable" on every run. disk-sizes.tfvars applies to
# every provider except azure.
COMMON_VAR_FILES=(-var-file="../lab.tfvars")
if [[ "$PROVIDER" != "aws" ]]; then
  COMMON_VAR_FILES+=(-var-file="../lab-addresses.tfvars")
fi
if [[ "$PROVIDER" == "aws" || "$PROVIDER" == "kvm" || "$PROVIDER" == "proxmox" || "$PROVIDER" == "vmware" ]]; then
  [[ -f "$REPO_ROOT/terraform/disk-sizes.tfvars" ]] || { echo "Error: terraform/disk-sizes.tfvars not found" >&2; exit 1; }
  COMMON_VAR_FILES+=(-var-file="../disk-sizes.tfvars")
fi

if [[ ! -f "$TFVARS_FILE" ]]; then
  echo "Error: $TFVARS_FILE not found." >&2
  echo "       Copy ${TFVARS_FILE}.example → $TFVARS_FILE and fill in your values." >&2
  exit 1
fi

# Deployment selection: the `deployment` Terraform variable is declared only on
# spec-driven providers (kvm and aws). The matching Ansible config overlay
# (deployments/<slug>/opennms-lab-vars.yml) is layered onto the OpenNMS play.
DEPLOYMENT_VARS=()
if [[ -n "$DEPLOYMENT" && ( "$PROVIDER" == "kvm" || "$PROVIDER" == "aws" ) ]]; then
  DEPLOYMENT_VARS=(-var "deployment=$DEPLOYMENT")
fi
DEPLOYMENT_VARS_FILE=""
if [[ -n "$DEPLOYMENT" && ( "$PROVIDER" == "kvm" || "$PROVIDER" == "aws" ) && -f "$REPO_ROOT/deployments/$DEPLOYMENT/opennms-lab-vars.yml" ]]; then
  DEPLOYMENT_VARS_FILE="--extra-vars=@$REPO_ROOT/deployments/$DEPLOYMENT/opennms-lab-vars.yml"
fi

# ── AWS credentials ───────────────────────────────────────────────────────────

# Terraform resolves credentials from env vars, the shared credentials file,
# `sso-session` profiles, process credentials and IMDS. It does NOT read the
# token cache that `aws login` writes, so a perfectly working CLI can sit next
# to a Terraform run that cannot authenticate at all -- and the symptom is a
# two-minute IMDS probe followed by "No valid credential sources found", which
# points nowhere useful.
#
# Export whatever the CLI has already resolved, and disable the IMDS fallback so
# a genuine absence of credentials fails in a second rather than two minutes.
ensure_aws_credentials() {
  [[ "$PROVIDER" == "aws" ]] || return 0

  export AWS_EC2_METADATA_DISABLED=true

  # Requiring an explicit profile is the difference between choosing which
  # identity builds the lab and inheriting whichever one happens to be default.
  # On an account shared with anything else, the default is usually the most
  # privileged identity available -- which is precisely what should not be
  # creating a disposable benchmark bed.
  #
  # Not enforced when destroying: being unable to tear a lab down is worse than
  # tearing it down with more authority than necessary, and a lab nobody can
  # remove keeps billing.
  if [[ -z "${AWS_PROFILE:-}" && "${AWS_ALLOW_DEFAULT_CREDENTIALS:-}" != "1" ]]; then
    if [[ "$DESTROY" == true ]]; then
      warn "AWS_PROFILE is not set; destroying with whatever credentials are default"
    else
      echo "Error: AWS_PROFILE is not set." >&2
      echo "       Deploying would use whichever AWS credentials happen to be default." >&2
      echo "       On a shared account that is usually your most privileged identity." >&2
      echo "" >&2
      echo "       Choose one explicitly:" >&2
      echo "         AWS_PROFILE=benchmark-lab make deploy PROVIDER=aws DEPLOYMENT=<slug>" >&2
      echo "" >&2
      echo "       Available profiles:" >&2
      aws configure list-profiles 2>/dev/null | sed 's/^/         /' >&2 || true
      echo "" >&2
      echo "       Set AWS_ALLOW_DEFAULT_CREDENTIALS=1 to bypass (CI, or static keys" >&2
      echo "       supplied by the environment rather than a profile)." >&2
      exit 1
    fi
  fi

  if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] && aws configure export-credentials --format env >/dev/null 2>&1; then
    info "exporting AWS credentials resolved by the CLI${AWS_PROFILE:+ (profile: $AWS_PROFILE)}"
    eval "$(aws configure export-credentials --format env)"
    # The export already resolved whatever the profile pointed at, including an
    # assumed role. Leaving AWS_PROFILE set makes the Terraform provider try to
    # resolve it again from scratch, which fails when the source profile has no
    # static credentials of its own -- the usual case when signing in with
    # `aws login` or SSO.
    unset AWS_PROFILE
  fi

  if ! aws sts get-caller-identity >/dev/null 2>&1; then
    echo "Error: no usable AWS credentials." >&2
    echo "       Sign in first, e.g.  aws login   (or  aws configure sso)." >&2
    echo "       Verify with:         aws sts get-caller-identity" >&2
    exit 1
  fi

  local ident
  ident=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo unknown)
  info "aws identity: $ident"

  # A set AWS_PROFILE is not by itself proof of anything -- AWS_PROFILE=default
  # satisfies the check above while still being the unrestricted user. An
  # assumed role is the shape a scoped identity takes, so say so when it is not
  # one. A warning rather than an error: a properly scoped IAM user is a
  # legitimate setup, just not the one this lab is built around.
  case "$ident" in
    *:assumed-role/*) ;;
    unknown) ;;
    *)
      warn "this is an IAM user, not an assumed role."
      warn "  If a scoped role exists, prefer it: AWS_PROFILE=benchmark-lab"
      warn "  See terraform/aws/README.md, 'Running under a restricted role'."
      ;;
  esac
}

# ── provider-specific extra vars ──────────────────────────────────────────────

# Populate PROVIDER_VARS array with extra -var flags needed for this provider.
# Azure and AWS: detect the operator's public IP for the SSH-allow rule.
PROVIDER_VARS=()

set_provider_vars() {
  PROVIDER_VARS=()
  if [[ "$PROVIDER" == "azure" || "$PROVIDER" == "aws" ]]; then
    local op_ip
    op_ip=$(host -4 myip.opendns.com resolver1.opendns.com 2>/dev/null \
            | awk '/has address/ {print $NF; exit}' || true)
    if [[ -n "$op_ip" ]]; then
      info "detected operator IP: $op_ip"
      PROVIDER_VARS=(-var "operator_cidr=${op_ip}/32")
    elif [[ "$PROVIDER" == "aws" ]]; then
      # aws declares operator_cidr with no default, so terraform would prompt.
      # Fail closed: a lab nobody can reach beats a lab open to the internet.
      warn "could not detect public IP; restricting operator SSH to 0.0.0.0/32 (unreachable)"
      PROVIDER_VARS=(-var "operator_cidr=0.0.0.0/32")
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
      -o UserKnownHostsFile=/dev/null \
      -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o ProxyJump="$hypervisor" \
      "${admin_user}@${mgmt_ip}" \
      'ip -4 addr | grep inet | grep -oE "([0-9]{1,3}\.){3}[0-9]{1,3}" | grep -vE "^192\.0\.2\.|^127\.|^172\.(1[6-9]|2[0-9]|3[01])\.|^169\.254\."' \
      2>/dev/null | head -1 || true)
    [[ -n "$jump_host" ]] && break
    info "waiting for external IP on jump host... ($i/24)" >&2
    sleep 5
  done
  echo "$jump_host"
}

# ── terraform wrappers ────────────────────────────────────────────────────────

tf_init() {
  terraform -chdir="$TF_DIR" init -upgrade -input=false
}

tf_apply() {
  terraform -chdir="$TF_DIR" apply \
    "${COMMON_VAR_FILES[@]}" \
    -var-file="${PROVIDER}.tfvars" \
    "${DEPLOYMENT_VARS[@]+"${DEPLOYMENT_VARS[@]}"}" \
    "$@" \
    "${TF_EXTRA_ARGS[@]+"${TF_EXTRA_ARGS[@]}"}" \
    -input=false \
    -auto-approve
}

tf_destroy() {
  terraform -chdir="$TF_DIR" destroy \
    "${COMMON_VAR_FILES[@]}" \
    -var-file="${PROVIDER}.tfvars" \
    "${DEPLOYMENT_VARS[@]+"${DEPLOYMENT_VARS[@]}"}" \
    "$@" \
    "${TF_EXTRA_ARGS[@]+"${TF_EXTRA_ARGS[@]}"}" \
    -input=false \
    -auto-approve
}

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

# ── destroy path ──────────────────────────────────────────────────────────────

if $DESTROY; then
  step "Destroying infrastructure ($PROVIDER)..."
  ensure_aws_credentials
  tf_init
  set_provider_vars
  tf_destroy "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}"
  rm -f "$REPO_ROOT/ansible-inventory.yml"
  step "Done. All $PROVIDER lab resources destroyed."
  exit 0
fi

# ── deploy path ───────────────────────────────────────────────────────────────

step "[1/5] Provisioning infrastructure ($PROVIDER)..."
ensure_aws_credentials
tf_init
set_provider_vars

# aws bills by the hour, so cost_profile defaults to the cheap tier and spend is
# opted into. The trade is that a smoke lab looks exactly like a benchmark bed
# and cannot produce valid numbers, so announce which one is being built before
# it exists rather than after. console evaluates the variable without contacting
# AWS, so this costs nothing and needs no credentials.
COST_PROFILE=""
if [[ "$PROVIDER" == "aws" ]]; then
  COST_PROFILE=$(echo 'var.cost_profile' \
    | terraform -chdir="$TF_DIR" console \
        "${COMMON_VAR_FILES[@]}" \
        -var-file="${PROVIDER}.tfvars" \
        "${DEPLOYMENT_VARS[@]+"${DEPLOYMENT_VARS[@]}"}" \
        "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}" 2>/dev/null \
    | tr -d '"' | tail -n1 || true)
  case "$COST_PROFILE" in
    smoke)
      warn "cost profile: SMOKE — burstable instances, capped disks."
      warn "  Cheap enough to test the stack with. CPU credits deplete under"
      warn "  sustained load, so any benchmark run on this lab is invalid."
      warn "  Measuring? Re-run with: TF_ARGS=\"-var cost_profile=benchmark\""
      ;;
    benchmark)
      info "cost profile: benchmark — fixed-performance instances, full disks."
      info "  This is the expensive tier. Destroy the lab when you are done."
      ;;
    *)
      [[ -n "$COST_PROFILE" ]] && info "cost profile: $COST_PROFILE"
      ;;
  esac
fi

tf_apply "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}"

# KVM and Proxmox: the monitoring VM's external (jump host) IP is DHCP-assigned
# after boot and cannot be known at plan time.  Discover it via SSH through the
# hypervisor, then re-apply to regenerate the Ansible inventory with ProxyJump.
if [[ "$PROVIDER" == "kvm" || "$PROVIDER" == "proxmox" || "$PROVIDER" == "vmware" ]]; then
  # Prefer the topology-derived jump host. ip_monitoring is a static tfvars
  # value and reports the monitoring VM's address even for a deployment that
  # provisions none — probing it there just times out for two minutes and
  # leaves the inventory without a ProxyCommand. Only the spec-driven kvm root
  # exposes ip_jump_host; the others still have a fixed layout where the
  # monitoring VM is always the jump host.
  # On kvm the value is authoritative even when empty: empty means the spec
  # marks no node public_ip, i.e. there is no jump host, and falling back to
  # the static ip_monitoring would reintroduce the very timeout this replaced.
  # The other providers do not expose the output at all, hence the fallback.
  IP_JUMP_HOST=$(tf_output ip_jump_host)
  if [[ "$PROVIDER" != "kvm" && -z "$IP_JUMP_HOST" ]]; then
    IP_JUMP_HOST=$(tf_output ip_monitoring)
  fi
  ADMIN_USER=$(tf_output admin_user)

  if [[ "$PROVIDER" == "kvm" ]]; then
    HYPERVISOR=$(tf_output libvirt_host)
  elif [[ "$PROVIDER" == "proxmox" ]]; then
    # Proxmox: derive SSH host from the API endpoint URL.
    PROXMOX_ENDPOINT=$(tf_output proxmox_endpoint)
    HYPERVISOR=$(echo "$PROXMOX_ENDPOINT" | sed 's|https\?://||; s|[:/].*||')
  else
    # VMware: SSH directly to the ESXi host (or vCenter) to probe the monitoring VM.
    HYPERVISOR=$(tf_output vsphere_server)
  fi

  if [[ -n "$HYPERVISOR" && -n "$IP_JUMP_HOST" ]]; then
    step "Discovering jump host external IP (via $HYPERVISOR → $IP_JUMP_HOST)..."
    JUMP_HOST=$(discover_jump_host "$HYPERVISOR" "$IP_JUMP_HOST" "$ADMIN_USER")

    if [[ -n "$JUMP_HOST" ]]; then
      info "found: $JUMP_HOST — regenerating inventory with jump host..."
      tf_apply "${PROVIDER_VARS[@]+"${PROVIDER_VARS[@]}"}" -var "jump_host=$JUMP_HOST"
    else
      warn "could not discover external IP after 2 minutes; jump host not configured"
    fi
  fi
fi

step "[2/5] Bootstrapping VMs..."
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$REPO_ROOT/bootstrap/site.yml"

step "[3/5] Installing Ansible Galaxy collections..."
ansible-galaxy collection install \
  -r "$REPO_ROOT/requirements.yml" \
  --force-with-deps

# A deployment may ship its own playbook when it stands up a different stack.
# Deployment H (clickhouse-akvorado) deploys no OpenNMS at all, so bolting its
# plays into opennms-playbook.yml would hide a second stack inside a playbook
# named for the first. Every OpenNMS deployment ships no playbook.yml and gets
# the shared one, which keeps its play order — the stack's dependency graph —
# in exactly one place.
# Gated on kvm for the same reason as the vars overlay above: only kvm is
# spec-driven (kvm and aws), so on other providers --deployment does not shape
# the infra and
# a per-deployment playbook would target hosts that were never provisioned.
DEPLOYMENT_PLAYBOOK="$REPO_ROOT/opennms-playbook.yml"
STACK_LABEL="OpenNMS Horizon"
if [[ -n "$DEPLOYMENT" && ( "$PROVIDER" == "kvm" || "$PROVIDER" == "aws" ) && -f "$REPO_ROOT/deployments/$DEPLOYMENT/playbook.yml" ]]; then
  DEPLOYMENT_PLAYBOOK="$REPO_ROOT/deployments/$DEPLOYMENT/playbook.yml"
  STACK_LABEL="$DEPLOYMENT stack"
fi

step "[4/5] Deploying $STACK_LABEL..."
# shellcheck disable=SC2086
ansible-playbook \
  --become \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$DEPLOYMENT_PLAYBOOK" \
  --extra-vars="@$REPO_ROOT/opennms-lab-vars.yml" \
  $DEPLOYMENT_VARS_FILE

# Deliberately its own step rather than a play inside the stack playbook: a
# deployment may replace that playbook outright (see DEPLOYMENT_PLAYBOOK above),
# and generation living inside it would mean such a deployment silently stopped
# producing a manifest. Runs on localhost against the inventory, so it contacts
# no lab host and changes nothing.
step "[5/5] Publishing endpoints..."
# shellcheck disable=SC2086
ansible-playbook \
  -i "$REPO_ROOT/ansible-inventory.yml" \
  $ANSIBLE_VERBOSITY \
  "$REPO_ROOT/endpoints-playbook.yml" \
  --extra-vars="@$REPO_ROOT/opennms-lab-vars.yml" \
  --extra-vars="lab_deployment=${DEPLOYMENT}" \
  --extra-vars="lab_provider=${PROVIDER}" \
  $DEPLOYMENT_VARS_FILE

# Closing reminder. The pre-flight notice scrolls far off screen behind
# Terraform and two Ansible runs, and this is the moment someone starts
# measuring.
if [[ "$COST_PROFILE" == "smoke" ]]; then
  echo
  warn "════════════════════════════════════════════════════════════════"
  warn "  This lab was built with cost_profile=smoke."
  warn "  Burstable instances: fine for testing the stack, invalid for"
  warn "  benchmarking. Numbers from this lab will look plausible and"
  warn "  will be wrong."
  warn "  Every host carries lab_cost_profile=smoke in the inventory."
  warn "════════════════════════════════════════════════════════════════"
elif [[ "$COST_PROFILE" == "benchmark" ]]; then
  echo
  info "cost_profile=benchmark — this lab bills at the full rate."
  info "Run 'make destroy PROVIDER=aws CONFIRM=yes' when you are finished."
fi
