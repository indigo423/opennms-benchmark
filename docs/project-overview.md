---
title: Project Overview
description: High-level summary of the opennms-benchmark lab project
date: 2026-03-20
---

# Project Overview

## Purpose

opennms-benchmark is a reproducible benchmarking lab for [OpenNMS Horizon](https://www.opennms.com/). It addresses a specific challenge: sizing and scaling OpenNMS for large deployments is difficult because real-world performance depends on factors outside OpenNMS itself — network latency, agent response time, service availability.

This lab eliminates those variables by provisioning a controlled 6-VM environment where every component runs on a dedicated VM, every network path is isolated to its own subnet, and up to 10,000 simulated SNMP nodes respond predictably. Experiments swap specific configuration parameters and measure the result.

This is a lab and benchmarking tool, **not a production deployment template.**

## Technology Summary

| Category | Technology |
|---|---|
| IaC | Terraform >= 1.5 |
| Cloud target | Azure (azurerm ~> 3.0) |
| Local target | KVM/libvirt (dmacvicar/libvirt ~> 0.7.0) |
| Configuration management | Ansible |
| Operating system | Ubuntu 24.04 LTS |
| OpenNMS | Horizon 34.1.0 (default) |
| Message broker | Apache Kafka (KRaft) |
| Database | PostgreSQL |
| Observability | Prometheus · Grafana · Jaeger |
| Container runtime | Docker Engine CE |
| CI | GitHub Actions |

## Architecture Type

Single-project Infrastructure-as-Code repository with a four-layer pipeline:

1. **Provision** — Terraform creates 6 VMs, 4 subnets, NICs, and cloud-init payloads
2. **Bootstrap** — Ansible installs OS tooling, monitoring services (Prometheus, Grafana, Jaeger), SNMP simulator, and Docker
3. **Deploy OpenNMS stack** — Ansible (`indigo423.opennms` Galaxy collection, pinned by git SHA in `requirements.yml`) deploys PostgreSQL, Kafka, OpenNMS Core, and OpenNMS Minion
4. **Run experiments** — per-scenario Ansible playbooks reconfigure the OpenNMS stack and load simulated nodes

## Repository Structure

```text
opennms-benchmark/
├── terraform/            # VM provisioning (Azure + KVM)
├── bootstrap/            # OS + monitoring stack setup
├── opennms-playbook.yml  # OpenNMS stack deployment entry point
├── requirements.yml      # Galaxy collection pins (indigo423.opennms + transitives)
├── experiments/          # Per-scenario benchmark configurations
├── azcli/                # Legacy Azure CLI script (reference only)
├── opennms-lab-vars.yml  # Global OpenNMS variables
└── ansible-inventory.<provider>.yml # Static Ansible inventory
```

## Available Experiments

| Experiment | Load Type | Timeseries |
|---|---|---|
| `legacy/c1km1_4c16g_kfk_pm_snmp` | SNMP polling | Kafka/OSGI |
| `legacy/c1km1_4c16g_kfk_snmptraps` | SNMP traps | Kafka/OSGI |
| `legacy/c1km1_4c16g_kfk_syslog` | Syslog ingestion | Kafka/OSGI |
| `legacy/c1km1_4c16g_rrd_pm_snmp` | SNMP polling | RRD (jrrd2) |

## Service URLs

After a full deployment, these services are available on the lab network:

| Service | URL | Credentials |
|---|---|---|
| OpenNMS UI | `http://192.0.2.200:8980/opennms` | admin / admin |
| Grafana | `http://192.0.2.200:3000` | admin / admin |
| Jaeger | `http://192.0.2.200:16686` | — |
| Kafka UI | `http://192.0.2.204:8080` | — |
| Prometheus | `http://192.0.2.200:9090` | — |

## Related Resources

- [opennms-forge/ansible-opennms](https://github.com/opennms-forge/ansible-opennms) — source repo for the `indigo423.opennms` Galaxy collection
- [Project Wiki](https://github.com/opennms-forge/opennms-benchmark/wiki) — experiment results and analysis
