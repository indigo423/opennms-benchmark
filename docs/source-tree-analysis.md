---
title: Source Tree Analysis
description: Annotated directory structure of the opennms-benchmark repository
date: 2026-03-20
---

# Source Tree Analysis

This document describes every significant directory and file in the repository and explains what it does.

## Top-Level Structure

```text
opennms-benchmark/
├── azcli/                    # Legacy Azure CLI provisioning script (pre-Terraform)
├── ansible-inventory.<provider>.yml     # Static Ansible inventory for the lab (management IPs)
├── ansible-opennms/          # Git submodule: opennms-forge/ansible-opennms roles
├── assets/                   # Images and diagrams referenced by README.md
├── bootstrap/                # Ansible: VM bootstrapping (OS tooling, monitoring stack)
├── experiments/              # Ansible: per-scenario experiment playbooks
├── opennms-lab-vars.yml      # Global OpenNMS stack variables (version, DB, Kafka, JVM)
├── terraform/                # Terraform: VM provisioning for Azure and KVM
├── docs/                     # Generated project documentation (this folder)
├── .github/workflows/        # CI: Terraform lint and validation
├── CLAUDE.md                 # AI assistant guidance for this repository
└── README.md                 # Project overview and quick-start guide
```

## terraform/

Provisions the 6-VM lab on either Azure or KVM/libvirt. Both providers use identical IP addressing defined in `lab.tfvars`.

```text
terraform/
├── lab.tfvars                # Shared network/IP variables for both providers
├── azure/                    # Azure provider root module
│   ├── main.tf               # Entry point: calls network, compute, inventory modules
│   ├── providers.tf          # azurerm ~> 3.0, local ~> 2.0; requires Terraform >= 1.5
│   ├── variables.tf          # Azure-specific variables (location, VM sizes, priority)
│   ├── azure.tfvars          # Azure variable values (region: eastus, sizes, operator CIDR)
│   ├── .tflint.hcl           # TFLint config for Azure ruleset
│   └── modules/
│       ├── network/          # VNet, 4 subnets, NICs, NSG, public IP, route table
│       └── compute/          # 6 azurerm_linux_virtual_machine resources + cloud-init
├── kvm/                      # KVM/libvirt provider root module
│   ├── main.tf               # Entry point: calls network, compute, inventory modules
│   ├── providers.tf          # dmacvicar/libvirt ~> 0.7.0; requires Terraform >= 1.5
│   ├── variables.tf          # KVM-specific variables (libvirt_uri, storage_pool, image)
│   ├── kvm.tfvars            # KVM variable values (qemu:///system, default pool, Ubuntu image path)
│   ├── .tflint.hcl           # TFLint config for KVM ruleset
│   ├── README.md             # KVM prerequisites and deploy instructions
│   └── modules/
│       ├── network/          # libvirt networks for db, kafka, sim, mgmt subnets
│       └── compute/          # 6 libvirt_domain resources + cloud-init
└── modules/                  # Shared modules (used by both azure/ and kvm/)
    ├── cloud-init/           # Generates cloud-init user-data and network-config per VM
    │   └── templates/
    │       ├── user-data.yaml.tftpl      # SSH user, /etc/hosts, disable package_update
    │       └── network-config.yaml.tftpl # Static IP netplan config per NIC
    └── inventory/            # Generates ansible-inventory.<provider>.yml from Terraform outputs
        └── templates/
            └── inventory.yml.tftpl       # Ansible inventory template
```

## bootstrap/

Ansible playbook that runs once after VMs are provisioned. Installs OS tooling, monitoring services, SNMP simulator, Docker Engine, and Kafka UI.

```text
bootstrap/
├── ansible.cfg               # Ansible config: pipelining, forks=20, SSH agent forwarding
├── site.yml                  # Entry point: imports preparation-playbook.yml
├── preparation-playbook.yml  # Main bootstrap playbook (5 plays)
├── update-playbook.yml       # APT update + optional reboot playbook
├── reboot-playbook.yml       # Reboot all VMs
├── inventory/                # Static bootstrap inventory (host groups)
└── roles/
    ├── apt-update/           # Runs apt-get update/upgrade
    ├── common/               # Base packages, bash config, SSH hardening, journald tuning
    ├── docker-ce/            # Installs Docker Engine (CE); used by monitoring and kafka-ui hosts
    ├── kafka-ui/             # Deploys Kafka UI as a Docker Compose service on kafka VM
    ├── monitoring/           # Deploys Prometheus, Grafana, Jaeger via Docker Compose on mon VM
    │   └── files/
    │       ├── prometheus/   # prometheus.yml (scrapes node:9100, core JMX:9299) + compose.yml
    │       ├── grafana/      # compose.yml + pre-provisioned dashboards and datasources
    │       └── jaeger/       # compose.yml for Jaeger all-in-one
    ├── net-snmp/             # Installs and configures snmpd; adds 10.42.0.0/16 loopback route
    └── reboot/               # Reboots and waits for SSH to return
```

## opennms-playbook.yml + requirements.yml

The OpenNMS stack deployment lives at the repo root as a top-level playbook plus a Galaxy collection pin:

```text
opennms-playbook.yml          # Entry point: invokes indigo423.opennms.* roles
requirements.yml              # Galaxy collection pins:
                              #   - indigo423.opennms (git SHA, source: opennms-forge/ansible-opennms)
                              #   - community.postgresql, community.general, grafana.grafana (version-pinned)
```

The role code is consumed via `ansible-galaxy collection install -r requirements.yml`. Roles are not modified locally — open PRs against the source repo and bump the SHA to consume changes.

## experiments/

Each subdirectory is a self-contained Ansible experiment. The naming scheme encodes the scenario: `c<cores>km<minions>_<cpu>c<ram>g_<broker>_<load-type>`.

```text
experiments/
├── inventory/                # Node generation and provisioning scripts
│   ├── generate_nodes.sh     # Generates 1k-batch*.xml files for 10.42.0.0/16 IPs
│   ├── provisioning.sh       # POSTs batch XML to OpenNMS REST API to import nodes
│   └── 1k-batch*.xml         # Pre-generated 1,000-node requisition batches (10 batches)
│
├── legacy/c1km1_4c16g_kfk_pm_snmp/ # Kafka broker + SNMP polling (performance metrics)
│   ├── experiment.yml        # Playbook: configure core + minion roles
│   ├── opennms-lab-inventory.yml
│   ├── roles/core/           # Deploys kafka-producer, Jaeger, collectd config
│   └── roles/minion/         # Configures Minion for SNMP collection
│
├── legacy/c1km1_4c16g_kfk_snmptraps/ # Kafka broker + SNMP traps + PostgreSQL tuning
│   ├── experiment.yml        # Playbook: configure core + minion + postgresql roles
│   ├── opennms-lab-vars.yml  # Uses OpenNMS 33.1.8
│   ├── roles/core/           # Deploys syslogd, kafka-producer, Jaeger
│   ├── roles/minion/         # Configures Minion for trap collection
│   └── roles/postgresql/     # PostgreSQL performance tuning
│
├── legacy/c1km1_4c16g_kfk_syslog/  # Kafka broker + syslog ingestion + PostgreSQL tuning
│   ├── experiment.yml        # Playbook: configure core + minion + postgresql roles
│   ├── roles/core/           # Deploys syslogd-configuration.xml, kafka-producer
│   ├── roles/minion/         # Configures Minion for syslog collection
│   └── roles/postgresql/     # PostgreSQL performance tuning
│
└── legacy/c1km1_4c16g_rrd_pm_snmp/ # RRD timeseries strategy + SNMP polling (baseline comparison)
    ├── experiment.yml        # Playbook: configure core + minion roles
    ├── opennms-lab-vars.yml  # Overrides timeseries to RRD (jrrd2 strategy)
    └── roles/
        ├── core/             # Core config without Kafka timeseries
        └── minion/           # Minion for SNMP collection
```

## azcli/

Pre-Terraform imperative provisioning script for Azure. Kept for reference. **Prefer `terraform/azure/` for new deployments.**

```text
azcli/
└── benchmark-lab.sh          # az CLI script: resource group, VNet, NICs, VMs, NSG, routing, DNS
```

## .github/

```text
.github/
└── workflows/
    └── terraform-lint.yml    # CI: fmt check, validate (Azure + KVM), TFLint on PRs to terraform/**
```
