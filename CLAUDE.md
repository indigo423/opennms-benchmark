# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

This is an infrastructure-as-code benchmarking lab for [OpenNMS Horizon](https://www.opennms.com/). It provisions a 6-VM lab on Azure and runs performance experiments against an OpenNMS stack with up to 10,000 simulated SNMP nodes.

Lab VMs (all in `192.0.2.0/24`):
- `192.0.2.196` — PostgreSQL (database)
- `192.0.2.197` — OpenNMS Core
- `192.0.2.198` — Kafka (message broker)
- `192.0.2.199` — OpenNMS Minion (distributed collector)
- `192.0.2.134` — Net-SNMP Simulator (10.42.0.0/16 SNMP targets)
- `192.0.2.201` — Monitoring (Prometheus, Grafana, Jaeger)

## Architecture

There are three layers:

1. **Azure infrastructure** (`azcli/benchmark-lab.sh`): Creates the VNet, subnets, NICs, NSGs, and VMs via `az` CLI.

2. **Bootstrap** (`bootstrap/`): Prepares all VMs — installs common tools, Docker, Prometheus Node Exporter, Net-SNMP simulator, Kafka UI, Prometheus, Grafana, Jaeger.

3. **OpenNMS stack** (`ansible-opennms/` submodule): Deploys and configures PostgreSQL, Kafka, OpenNMS Core, and OpenNMS Minion using roles in the submodule.

Experiments live in `experiments/` — each subdirectory is a self-contained Ansible playbook that reconfigures the OpenNMS stack for a specific scenario (Kafka vs. RRD timeseries, SNMP metrics vs. syslog vs. traps).

Global lab variables (OpenNMS version, JVM heap, Kafka bootstrap servers, DB host) live in `opennms-lab-vars.yml`. Per-experiment overrides live in `experiments/<name>/opennms-lab-vars.yml`.

## Key Commands

### Deploy Azure infrastructure
```bash
export SSH_PUBLIC_KEY=$(cat ~/.ssh/id_rsa.pub)
cd azcli && ./benchmark-lab.sh
```

### Bootstrap all VMs
```bash
cd bootstrap
ansible-playbook -i inventory site.yml
```

### Deploy the OpenNMS stack
```bash
cd ansible-opennms
ansible-playbook --user labuser --become \
  -i ../ansible-inventory.yml \
  opennms-playbook.yml \
  --extra-vars="@../opennms-lab-vars.yml"
```

### Run a specific experiment
```bash
cd experiments/<experiment-name>
ansible-playbook -i opennms-lab-inventory.yml experiment.yml
```

### Provision test nodes into OpenNMS
```bash
cd experiments/inventory
./generate_nodes.sh          # generates 10,000-node XML batches
./provisioning.sh 01         # imports batch 01 via REST API
```

### SNMP simulation routing (one-time setup after VM boot)
```bash
# On SNMP simulator host — expose 10.42.0.0/16 on loopback
ssh labuser@192.0.2.201 "sudo ip route add local 10.42.0.0/16 dev lo"

# On Minion — route SNMP simulation subnet via simulator
ssh labuser@192.0.2.199 "sudo ip r a 10.42.0.0/16 via 192.0.2.134"
```

### Update packages / reboot
```bash
cd bootstrap
ansible-playbook -i ../ansible-inventory.yml update-playbook.yml
ansible-playbook -i ../ansible-inventory.yml reboot-playbook.yml
```

## Submodule

`ansible-opennms/` is a git submodule from `https://github.com/opennms-forge/ansible-opennms`. After cloning, initialize it with:
```bash
git submodule update --init --recursive
```

## VM Naming Convention

VM names follow the pattern `[function]-[env]-[seq]`:

- **function** — role of the VM:
  - `mon` — Monitoring (Prometheus, Grafana, Jaeger)
  - `core` — OpenNMS Core
  - `minion` — OpenNMS Minion
  - `db` — Database (PostgreSQL)
  - `netsim` — Net-SNMP Simulator
  - `kafka` — Message broker (Kafka)
  - `es` — Elasticsearch
  - `sen` — OpenNMS Sentinel
- **env** — environment name, matching the Azure deployment project name (e.g. `benchmark`)
- **seq** — two-digit zero-padded sequence number (e.g. `01`, `02`)

Examples: `db-benchmark-01`, `core-benchmark-01`, `minion-benchmark-01`, `mon-benchmark-01`

## Experiment Naming Convention

`c<cores>km<minions>_<cpu>c<ram>g_<broker>_<load-type>`

- `c1km1` — 1 Core, 1 Minion
- `4c16g` — VM size (4 vCPU, 16 GB RAM)
- `kfk` / `rrd` — Kafka or RRD timeseries strategy
- `pm_snmp` / `snmptraps` / `syslog` — load type

## Services and Ports

| Service | URL (via Traefik proxy) | Direct URL |
|---|---|---|
| OpenNMS UI | `https://<monitoring>/opennms` | `http://192.0.2.197:8980/opennms` |
| Grafana | `https://<monitoring>/grafana` | `http://192.0.2.200:3000` |
| Jaeger | `https://<monitoring>/jaeger` | `http://192.0.2.200:16686` |
| Prometheus | `https://<monitoring>/prometheus` | `http://192.0.2.200:9090` |
| Kafka UI | `https://<monitoring>/kafka` | `http://192.0.2.198:8080` |

`<monitoring>` is the monitoring VM's external IP or hostname.

## Git Workflow

Never push directly to `main`. All changes must go through a pull request, regardless of size. Create a feature branch, make your changes, then open a PR for review before merging.

All commits must be signed off using `git commit --signoff` (or `-s`), which adds a `Signed-off-by` trailer certifying that you have the right to submit the contribution under the project license (Developer Certificate of Origin). Example:

```bash
git commit -s -m "feat: my change"
```
