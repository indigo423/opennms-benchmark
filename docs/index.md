---
title: opennms-benchmark Documentation Index
description: Master index for AI-assisted development of the opennms-benchmark lab
date: 2026-03-20
---

# opennms-benchmark Documentation Index

## Project Overview

- **Type:** Monolith — Infrastructure-as-Code benchmarking lab
- **Primary Language:** HCL (Terraform), YAML (Ansible), Bash
- **Architecture:** Four-layer IaC pipeline (Provision → Bootstrap → Deploy → Experiment)
- **Targets:** Azure (cloud) and KVM/libvirt (local)

## Quick Reference

| Item | Value |
|---|---|
| OpenNMS version | Horizon 34.1.0 (default) |
| OS | Ubuntu 24.04 LTS |
| IaC tool | Terraform >= 1.5 |
| Config management | Ansible |
| SNMP simulation range | 10.42.0.0/16 (up to 65,534 nodes) |
| Node batches | 10 × 1,000 = 10,000 total |

## Generated Documentation

- [Project Overview](./project-overview.md)
- [Architecture](./architecture.md)
- [Source Tree Analysis](./source-tree-analysis.md)
- [Development Guide](./development-guide.md)
- [Deployment Guide](./deployment-guide.md)

## Existing Documentation

- [README.md](../README.md) — Project introduction, network layout, quick-start commands
- [CLAUDE.md](../CLAUDE.md) — AI assistant guidance, key commands, git workflow
- [terraform/kvm/README.md](../terraform/kvm/README.md) — KVM-specific prerequisites and deploy steps

## Getting Started

### Fresh deployment (Azure)

```bash
# 1. Clone
git clone https://github.com/opennms-forge/opennms-benchmark.git
cd opennms-benchmark

# 2. Provision
export TF_VAR_ssh_public_key=$(cat ~/.ssh/id_rsa.pub)
cd terraform/azure && terraform init
terraform apply -var-file=../lab.tfvars -var-file=azure.tfvars

# 3. Bootstrap
cd ../../bootstrap && ansible-playbook -i inventory site.yml

# 4. Deploy OpenNMS stack
cd ..
make install-collections
ansible-playbook --user labuser --become \
  -i ansible-inventory.yml opennms-playbook.yml \
  --extra-vars="@opennms-lab-vars.yml"

# 5. Run an experiment
make experiment EXPERIMENT=smoke DEPLOYMENT=<slug>
ansible-playbook -i opennms-lab-inventory.yml experiment.yml \
  --extra-vars="@../../opennms-lab-vars.yml"
```

See the [Deployment Guide](./deployment-guide.md) for the full step-by-step guide, KVM instructions, and post-reboot checklist.

### Using this index with AI tools

When planning new features or experiments, provide this file as context:

- **For infrastructure changes:** Reference [Architecture](./architecture.md) and [Source Tree Analysis](./source-tree-analysis.md)
- **For new experiments:** Reference [Architecture](./architecture.md) (Experiments section) and [Development Guide](./development-guide.md)
- **For full deployment questions:** Reference [Deployment Guide](./deployment-guide.md)
