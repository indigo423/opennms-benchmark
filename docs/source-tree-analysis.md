---
title: Source Tree Analysis
description: Annotated directory structure of the opennms-benchmark repository
date: 2026-09-08
---

# Source Tree Analysis

This document describes every significant directory and file in the repository and explains what it does.

It is a snapshot, and a snapshot of a tree goes stale silently.
Where a list changes often, this document names the command that prints the current answer instead of copying it: `make help`, `make providers`, `make deployments`, `make experiments`.
Prefer those over this page when the two disagree, and correct the page.

## Top-Level Structure

```text
opennms-benchmark/
├── Makefile                  # The front door. Every deploy, lint and check target
├── deploy.sh                 # Provision + configure, wrapped by `make deploy`
├── show.sh                   # Show deployed resources, wrapped by `make show`
├── ansible.cfg               # The one Ansible configuration. roles_path, SSH, strict collections
├── opennms-playbook.yml      # OpenNMS stack entry point: invokes indigo423.opennms.* roles
├── endpoints-playbook.yml    # Renders lab-endpoints.<provider>.yml for a running lab
├── opennms-lab-vars.yml      # Global OpenNMS stack variables (version, DB, Kafka, JVM)
├── requirements.yml          # Galaxy collection pins, including indigo423.opennms by git SHA
├── constraints.txt           # The pinned Python/Ansible dependency closure
├── renovate.json             # Update automation, including the custom version-pin managers
├── group_vars/               # Inventory-scoped variables for the root playbooks
├── templates/                # Jinja templates owned by the root playbooks
├── terraform/                # VM provisioning, one root per provider
├── bootstrap/                # Ansible: base tooling on every VM
├── deployments/              # Provider-agnostic topology specs and their Ansible overlays
├── experiments/              # Per-scenario playbooks and the tooling that drives them
├── tests/                    # Fixtures asserting the repository's own checks still fail
├── docs/                     # Project documentation (this folder)
├── assets/                   # Images and diagrams referenced by README.md
├── .github/workflows/        # CI: ansible-lint, code-lint, terraform-lint
├── validate-collections.py   # Assert installed collections match the declared closure
├── validate-doc-inventories.py # Assert documented ansible-playbook commands name a real inventory
├── validate-renovate-pins.py # Assert each update annotation is bound to the pin it names
├── validate-topology.sh      # Assert every deployment spec renders a provisionable topology
├── compare-role-defaults.sh  # Diff local variables against the pinned collection's defaults
├── render-diagrams.sh        # Render the topology diagrams under assets/
├── .ansible-lint             # ansible-lint config
├── .yamllint                 # yamllint config
├── ruff.toml                 # ruff config
├── CLAUDE.md                 # AI assistant guidance for this repository
└── README.md                 # Project overview and quick-start guide
```

Generated files are gitignored and appear only in a deployed checkout: `ansible-inventory.<provider>.yml` from Terraform, and `lab-endpoints.<provider>.{yml,json}` from `endpoints-playbook.yml`.
There is one set per provider, so two labs can be operated from one checkout.

`ansible.cfg` is the only Ansible configuration governing a runnable invocation.
Ansible reads `./ansible.cfg` from the working directory and never searches parent directories, so every documented command runs from the repository root and `deploy.sh` exports `ANSIBLE_CONFIG` explicitly.

## terraform/

Provisions the lab. `make providers` lists the roots.

```text
terraform/
├── lab.tfvars                # Shared network and IP variables
├── lab-addresses.tfvars      # Address assignments
├── disk-sizes.tfvars         # Per-role disk sizing
├── aws/                      # AWS provider root; consumes a deployment topology
├── azure/                    # Azure provider root; deploys the fixed baseline
├── kvm/                      # KVM/libvirt provider root; consumes a deployment topology
├── proxmox/                  # Proxmox provider root; consumes a deployment topology
├── vmware/                   # VMware provider root; deploys the fixed baseline
│                             #   each provider root also has modules/network and
│                             #   modules/compute of its own
├── proxmox/preflight/        # A separate root, not a provider: checks a Proxmox
│                             #   host before the lab is provisioned
└── modules/                  # Shared modules
    ├── cloud-init/           # cloud-init user-data and network-config per VM
    ├── topology/             # Turns a deployments/<slug>/topology.yml spec into resources
    ├── inventory/            # Writes ansible-inventory.<provider>.yml (fixed-baseline providers)
    ├── topology-inventory/   # Writes ansible-inventory.<provider>.yml (topology-driven providers)
    └── diagram/              # Emits the data render-diagrams.sh draws
```

Every provider root carries `providers.tf` and `variables.tf`. Read those for the current version constraints rather than trusting a copy here.

The rest is not uniform. `aws` has no `.tflint.hcl`, though `make tflint` still runs there. Only `azure` ships a committed `azure.tfvars`; `aws`, `kvm`, `proxmox` and `vmware` ship `<provider>.tfvars.example`, because the real file carries host-specific values and is gitignored. Copy the example before a first deploy.

**Addresses are provider-dependent.** `kvm` derives them from per-role blocks; `azure` uses the fixed `ip_*` values in `lab-addresses.tfvars`, not `lab.tfvars`, which holds only CIDRs and the admin user. They disagree for every role except `database`. Read the generated inventory, never a literal.

## bootstrap/

Base tooling on every VM, applied after provisioning.

```text
bootstrap/
├── site.yml                  # Entry point: imports preparation-playbook.yml
├── preparation-playbook.yml  # Main bootstrap playbook (7 plays)
├── update-playbook.yml       # APT update across the lab
├── reboot-playbook.yml       # Reboot all VMs
├── proxmox-hypervisor-playbook.yml # Prepare a Proxmox host, via `make prepare-hypervisor`
├── bin/
│   └── validate-handlers.py  # Assert no two roles in one play define the same handler name
└── roles/
    ├── common/               # Base packages, shell config, SSH hardening, journald
    ├── apt_update/           # apt-get update/upgrade, honouring lab package holds
    ├── etc_hosts/            # /etc/hosts from the inventory topology
    ├── docker_ce/            # Docker Engine
    ├── app_starter/          # Brings the container units up in order
    ├── traefik/              # Reverse proxy fronting the monitoring services
    ├── prometheus/           # Metrics store and scrape config
    ├── grafana/              # Dashboards and datasources, provisioned from files
    ├── pyroscope/            # Continuous profiling server
    ├── kibana/               # Log UI
    ├── kafka_ui/             # Kafka UI
    ├── pgadmin/              # PostgreSQL UI
    ├── nl6/                  # Network simulator driving synthetic devices
    ├── net_snmp/             # snmpd on the simulator host
    ├── ip_forwarding/        # Routing for the simulated device ranges
    ├── rp_filter/            # Reverse-path filtering, relaxed for the simulator
    ├── proxmox_hypervisor/   # Host preparation, used by its own playbook
    └── reboot/               # Reboot and wait for SSH
```

The seven plays target `all` twice, then `docker_engine`, `mon_servers`, `net_sim`, `minion` and `kafka_ui`.

There is no inventory inside this directory. The repository root owns it.

## deployments/

A provider-agnostic *topology* spec plus its Ansible overlay. `make deployments` lists them.

```text
deployments/
├── README.md                 # What a topology spec is and how providers consume it
├── <slug>/
│   ├── topology.yml          # Which components, how many, which subnets
│   ├── opennms-lab-vars.yml  # Optional variable overlay, layered after the root file
│   └── playbook.yml          # Optional: replaces opennms-playbook.yml outright for
│                             #   this slug (deploy.sh). Four slugs use it
├── bin/
│   ├── topology-descriptor.py # Canonical descriptor for a spec
│   └── validate-library.py    # Invariants spanning the whole deployment library
└── roles/                    # Roles the deployment overlay applies
    ├── kafka_metrics_report/
    ├── nl6_loadtest/
    ├── opennms_collectd_tuning/
    ├── opennms_kafka_producer/
    ├── opennms_minion_listeners/
    ├── opennms_pyroscope_agent/
    ├── opennms_tarball_prereqs/
    ├── opennms_thresholding_off/
    ├── postgres_tuning/
    ├── rustfs/
    └── victorialogs/
```

`terraform/aws`, `terraform/kvm` and `terraform/proxmox` consume a spec directly. `azure` and `vmware` do not yet.

The directory slug and the `name:` inside `topology.yml` must match.

## experiments/

Self-contained playbooks that reconfigure the stack for one scenario without reprovisioning. `make experiments` lists the runnable ones.

```text
experiments/
├── README.md                 # The layer's structure and what legacy/ is
├── <name>/
│   ├── experiment.yml        # The playbook
│   ├── opennms-lab-vars.yml  # Optional overlay, layered last
│   └── roles/                # Experiment-local roles
├── roles/                    # Roles shared across experiments
│   ├── nl6_fleet/            # Builds and reshapes the simulated device fleet
│   ├── opennms_requisition/  # Loads requisitions into OpenNMS
│   └── kafka_offsets/        # Reads consumer offsets for reporting
├── inventory/                # Requisition and fleet helpers, not an experiment
├── nms-20027-painless-flows/ # Standalone harness with its own runner
└── legacy/                   # Reference, not runnable
    ├── c1km1_4c16g_kfk_pm_snmp/
    ├── c1km1_4c16g_kfk_snmptraps/
    ├── c1km1_4c16g_kfk_syslog/
    └── c1km1_4c16g_rrd_pm_snmp/
```

The naming scheme encodes the scenario: `c<cores>km<minions>_<cpu>c<ram>g_<broker>_<load-type>`.

**`legacy/` is reference, not runnable.** Those four predate the current structure and are kept for the configuration they encode. All four carry their own `ansible.cfg`, and three carry an inventory of some kind, which the current layout does not: `c1km1_4c16g_kfk_pm_snmp` and `c1km1_4c16g_rrd_pm_snmp` have both an `inventory` and an `opennms-lab-inventory.yml`, `c1km1_4c16g_kfk_snmptraps` has only the latter, and `c1km1_4c16g_kfk_syslog` has neither. Those inventories hold pre-`role_block_size` addresses. All three `opennms-lab-inventory.yml` files group hosts under the hyphenated `opennms-stack` while both templates emit `opennms_stack`, and the two ini `inventory` files use `onms_core` and `onms_minion`, so every one of them names a group nothing produces. Their `ansible.cfg` sets `remote_user = labuser`, which matches no lab the repository provisions; their own inventories set no user at all. They also still configure Jaeger, whose role was removed from the lab. Running one targets hosts that do not exist.

## Variables

Three layers, applied root → deployment → experiment:

```text
opennms-lab-vars.yml                      # 1. global
deployments/<slug>/opennms-lab-vars.yml   # 2. topology overlay
experiments/<name>/opennms-lab-vars.yml   # 3. scenario overlay
```

`group_vars/` is separate and is read by the root playbooks directly:

```text
group_vars/
├── all/vars.yml              # Ports, topic names, profiling switch, instrument pins
├── core/vars.yml             # OpenNMS Core host variables
├── grafana/vars.yml          # Grafana host variables
├── net_sim/vars.yml          # Simulator host variables, including the nl6 image pin
└── opennms_stack/
    ├── vars.yml              # Stack-wide variables
    └── vault.yml             # Encrypted secrets (ANSIBLE_VAULT_PASSWORD_FILE)
```

**A pin belongs where the play that reads it will see it.** `deploy.sh` runs `bootstrap/site.yml` with no `--extra-vars`, so a key placed in `opennms-lab-vars.yml` is never read by a bootstrap role: it does not warn, it does not fail, and the role default silently wins. Pins for bootstrap roles go in `group_vars/`.

## tests/

Fixtures whose only job is to fail. Each proves that a check still detects the defect it was written for; a check whose failure path is never exercised quietly stops working.

```text
tests/
├── doc-fixtures/             # A document naming inventories that do not exist
├── handler-fixtures/         # Two roles in one play defining the same handler name
├── renovate-fixtures/        # An update annotation bound to the wrong pin
└── topology-fixtures/        # Deployment specs that must be rejected
```

## Checks

`make lint` runs everything CI runs. Each check is also a target of its own, which is how CI invokes them.

| Target | Asserts |
|---|---|
| `fmt`, `validate`, `tflint` | Terraform formatting, validity and lint, per provider root, plus `validate-extra-roots` for `proxmox/preflight` |
| `lint-ansible` | ansible-lint at the production profile |
| `lint-shell`, `lint-python`, `lint-yaml` | shellcheck, ruff, yamllint |
| `lint-actions` | actionlint and zizmor on the workflows |
| `validate-deployments`, `validate-topology`, `validate-library` | Deployment specs render a provisionable topology |
| `validate-handlers` | No two roles in one play share a handler name |
| `validate-renovate-pins` | Each update annotation is bound to the pin it names |
| `validate-doc-inventories` | Each documented `ansible-playbook` names an inventory that exists |
| `validate-collections` | Installed collections match the declared closure |

File lists come from `git ls-files`, so a new script is covered the moment it is tracked, and not at all while it is untracked.

## .github/workflows/

```text
.github/workflows/
├── ansible-lint.yml          # ansible-lint against the installed collection closure
├── code-lint.yml             # Shell, Python, YAML, Actions, and the validate-* targets
└── terraform-lint.yml        # Format, validate and TFLint per provider root
```

CI invokes Makefile targets and nothing else, so local and CI commands cannot drift.
It runs the individual targets rather than the aggregate `lint`, which means a new check must be added to a workflow explicitly: being in `make lint` alone gates nothing.
