---
title: Development Guide
description: Prerequisites, setup, and workflow for working on opennms-benchmark
date: 2026-03-20
---

# Development Guide

## Prerequisites

### All deployments

- Git (to clone and manage submodules)
- Ansible (any recent version)
- SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`

### Azure deployments

- [Azure CLI (`az`)](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) — authenticated with `az login`
- Azure subscription with permission to create resource groups and VMs
- Terraform >= 1.5

### KVM/local deployments

- KVM host with libvirt and `virsh` installed
- Ubuntu 24.04 LTS cloud image downloaded to the libvirt storage pool
- Terraform >= 1.5

## Clone and Initialize

```bash
git clone https://github.com/opennms-forge/opennms-benchmark.git
cd opennms-benchmark
git submodule init
git submodule update
```

## Working with Terraform

### Azure

```bash
# Set your SSH public key
export TF_VAR_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)

# Edit azure.tfvars — set operator_cidr to your public IP
# operator_cidr = "203.0.113.5/32"

cd terraform/azure
terraform init
terraform apply -var-file=../lab.tfvars -var-file=azure.tfvars
```

### KVM

```bash
# Download the Ubuntu 24.04 cloud image first
sudo wget -O /var/lib/libvirt/images/noble-server-cloudimg-amd64.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

# Set your SSH public key
export TF_VAR_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)

cd terraform/kvm
terraform init
terraform apply -var-file=../lab.tfvars -var-file=kvm.tfvars
```

After `terraform apply`, the `inventory` module writes `ansible-inventory.yml` to the repository root.

## Modifying Terraform

- **Shared network/IP changes** — edit `terraform/lab.tfvars`. These values are load-bearing; they propagate to Ansible inventory, OpenNMS config, and Prometheus scrape targets. Change them consistently.
- **Azure-specific changes** — edit `terraform/azure/azure.tfvars` or modules under `terraform/azure/modules/`.
- **KVM-specific changes** — edit `terraform/kvm/kvm.tfvars` or modules under `terraform/kvm/modules/`.
- **New VM type or NIC** — add to both the `network/` and `compute/` modules for the relevant provider, and update `terraform/modules/cloud-init/` if the VM needs different networking.
- **cloud-init templates** — `terraform/modules/cloud-init/templates/`. Changes here affect all VMs.

### Lint and validate

```bash
# Format
terraform fmt -recursive terraform/

# Validate Azure
cd terraform/azure && terraform init -backend=false && terraform validate

# Validate KVM
cd terraform/kvm && terraform init -backend=false -upgrade && terraform validate

# TFLint
cd terraform/azure && tflint --init && tflint --recursive
cd terraform/kvm  && tflint --init && tflint --recursive
```

CI runs these checks automatically on pull requests that touch `terraform/**`.

### Validating a rendered topology

```bash
make validate-topology
```

Renders every spec in `deployments/` through `terraform console` and asserts the
result could actually be provisioned: no address assigned twice, no named route
whose target role is absent or lacks the required NIC, no node without a
management address, and no next hop that is not an address some node in that
spec holds.

That last one is the check that did not exist when a hardcoded `net_sim_gateway`
pointed at nothing for two days with every gate green (#171). `terraform
validate` checks types, not relationships between values, and preconditions only
run at plan time.

It reads no host-specific config and needs no hypervisor, credentials or state.
`tests/topology-fixtures/` holds specs that must be *rejected*, one per failure
mode, so a regression in the check itself is caught rather than reported as a
clean run.

> [!NOTE]
> This runs in `make lint` but is **not** a CI gate yet — the job stalls on a
> GitHub runner for reasons not yet diagnosed. Tracked in #173. Until that is
> resolved it only protects people who run `make lint` before pushing.

## Working with Ansible

### Bootstrap VMs

```bash
cd bootstrap
ansible-playbook -i inventory site.yml
```

Run selectively by tag:

```bash
ansible-playbook -i inventory site.yml --tags monitoring
ansible-playbook -i inventory site.yml --tags net-snmp
```

### Update packages

```bash
cd bootstrap
ansible-playbook -i ../ansible-inventory.yml update-playbook.yml
```

### Reboot all VMs

```bash
cd bootstrap
ansible-playbook -i ../ansible-inventory.yml reboot-playbook.yml
```

### Deploy the OpenNMS stack

```bash
ansible-galaxy collection install -r requirements.yml --force-with-deps

ansible-playbook --user labuser --become \
  -i ansible-inventory.yml \
  opennms-playbook.yml \
  --extra-vars="@opennms-lab-vars.yml"
```

**Note:** After deployment, the Prometheus JMX exporter requires a manual restart of OpenNMS Core. See [ansible-opennms issue #57](https://github.com/opennms-forge/ansible-opennms/issues/57).

### Modifying the OpenNMS stack

Edit `opennms-lab-vars.yml` to change the OpenNMS version, JVM heap, Kafka settings, or PostgreSQL credentials. These are global defaults. Experiments can override any variable in their own `opennms-lab-vars.yml`.

## Running an Experiment

```bash
cd experiments/<experiment-name>
ansible-playbook -i opennms-lab-inventory.yml experiment.yml \
  --extra-vars="@../../opennms-lab-vars.yml" \
  --extra-vars="@opennms-lab-vars.yml"  # if the experiment has overrides
```

## Provisioning Test Nodes

After running an experiment, provision simulated SNMP nodes into OpenNMS:

```bash
cd experiments/inventory

# Generate a new batch (if needed)
./generate_nodes.sh

# Import a batch via the OpenNMS REST API
./provisioning.sh 01   # imports 1k-batch01.xml
./provisioning.sh 02   # imports 1k-batch02.xml
# ... up to 10 batches = 10,000 nodes
```

## Network Access to the Lab

Only the monitoring VM has a public IP. To reach other VMs from your local machine:

**Option 1 — SSH tunneling through the monitoring VM**

```bash
ssh -L 8980:192.0.2.200:8980 labuser@<monitoring-public-ip>
```

**Option 2 — Tailscale (recommended for full access)**

```bash
# On the monitoring VM:
sudo sysctl -w net.ipv4.ip_forward=1
sudo tailscale up --accept-routes --advertise-routes=192.0.2.192/26

# Approve the route in the Tailscale web UI
# Then all 192.0.2.0/24 addresses are reachable from your machine
```

## Git Workflow

- Never push directly to `main`. All changes require a pull request.
- Sign off all commits: `git commit -s -m "feat: my change"`
- Commit message format: `<type>: <description>` (feat, fix, docs, chore)
- CI validates Terraform on every PR touching `terraform/**`

## Iterating on the OpenNMS Galaxy Collection

The OpenNMS deployment automation lives in the `indigo423.opennms` Ansible Galaxy collection (source repo: `github.com/opennms-forge/ansible-opennms`). It is pinned by git SHA in `requirements.yml` so that benchmark runs are bit-for-bit reproducible.

### Bumping the pinned SHA

When upstream lands a change you want to consume in the lab:

```bash
# 1. Replace the version in requirements.yml with the new SHA from upstream.
# 2. Re-install and re-deploy:
ansible-galaxy collection install -r requirements.yml --force-with-deps
ansible-playbook --user labuser --become \
  -i ansible-inventory.yml opennms-playbook.yml \
  --extra-vars="@opennms-lab-vars.yml"
```

SHA bumps are deliberate, manual PRs — Renovate/Dependabot are intentionally not configured to auto-bump this pin, because a benchmark whose substrate silently changes between runs is uninterpretable.

### Iterating on a role locally without an upstream PR cycle

For active development of a role, point `requirements.yml` at a local checkout temporarily:

```yaml
# Local-dev override — NEVER commit this form
collections:
  - name: /Users/me/work/ansible-opennms
    type: dir
  # ... other collections unchanged
```

Then run `ansible-galaxy collection install -r requirements.yml --force` to pick up the local copy. **Revert this entry before committing** — the canonical pin is git+SHA, never `type: dir`.
