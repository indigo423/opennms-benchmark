# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repository.

## What this repo is

An infrastructure-as-code lab for benchmarking [OpenNMS Horizon](https://www.opennms.com/).
Terraform provisions VMs on one of four providers, Ansible configures them, and experiments
drive load against the result. Explicitly not for building production environments.

## The front door is `make`

Do not invoke `terraform`, `ansible-playbook` or the linters directly. CI calls these same
targets and nothing else, so bypassing them is how local and CI drift apart. `make help`
lists everything.

```bash
make deploy PROVIDER=kvm DEPLOYMENT=mimir-ha-min   # provision + configure
make destroy PROVIDER=kvm                          # prompts; CONFIRM=yes to skip
make plan PROVIDER=azure
make lint                                          # every check CI runs
make deployments                                   # list topology specs
```

Providers: `azure`, `kvm`, `proxmox`, `vmware`. `DEPLOYMENT` is consumed by `kvm` only.

## Architecture

Four layers, orchestrated by `deploy.sh` (which `make deploy` wraps):

1. **`terraform/<provider>/`** — provisions VMs and writes `ansible-inventory.yml`.
2. **`bootstrap/`** — base tooling on every VM: Docker, Traefik, Prometheus, Grafana,
   Jaeger, nl6, Kafka UI, …
3. **OpenNMS stack** — the `indigo423.opennms` Galaxy collection pinned in
   `requirements.yml`, applied by `opennms-playbook.yml`. Not a submodule.
4. **`experiments/<name>/`** — self-contained playbooks reconfiguring the stack for one
   scenario, plus the tooling to drive and measure load.

`deployments/<slug>/` is a separate axis: a provider-agnostic *topology* spec
(`topology.yml` — which components, how many, which subnets) with its Ansible overlay.
`terraform/kvm` consumes it directly; the other providers do not yet. See
`deployments/README.md`.

Variables layer root → deployment → experiment: `opennms-lab-vars.yml`, then
`deployments/<slug>/opennms-lab-vars.yml`, then `experiments/<name>/opennms-lab-vars.yml`.

## Gotchas

- **VM addresses are provider-dependent — never hardcode one.** `kvm` derives them from
  per-role blocks (`role_block_size`, `terraform/kvm/main.tf`); `azure` uses the fixed
  `ip_*` values in `terraform/lab.tfvars`. They disagree for every role except `database`:
  `192.0.2.200` is Core on `kvm` and Monitoring on `azure`. Read the generated
  `ansible-inventory.yml` instead. Tracked in #161.
- `ansible.cfg` owns `roles_path`. Never set `ANSIBLE_ROLES_PATH` — the env var overrides
  the file, and CI has already silently drifted that way once.
- `ansible-inventory.yml` (generated) and `vault_pass.secret` are gitignored. The vault
  password comes from `ANSIBLE_VAULT_PASSWORD_FILE`.
- Lint targets take their file lists from `git ls-files`, so a new script is covered the
  moment it is tracked — and not at all while it is untracked.
- `indigo423.opennms` is pinned by git SHA for benchmark reproducibility. Bump it only in a
  deliberate PR, never automatically.

## Conventions

- **VM names** — `<function>-<env>-<seq>`, e.g. `core-benchmark-01`. Functions: `db`,
  `core`, `minion`, `kafka`, `netsim`, `mon`, `es`, `sen`.
- **Experiments** — `c<cores>km<minions>_<cpu>c<ram>g_<broker>_<load>`, e.g.
  `c1km1_4c16g_kfk_pm_snmp`.
- **Deployments** — the directory slug, and `name:` inside `topology.yml`, must match.

## Git workflow

`main` is protected: pull requests only, 13 required status checks, no direct pushes.
Conventional Commits. Every commit needs `git commit -s` (DCO, enforced by a bot) and an
`Assisted-by: ClaudeCode:<model>` trailer. Work starts from an issue — reference it with
`Closes #<n>`.

## Further reading

`README.md` for network layout and per-provider host prep; `docs/` for the architecture,
deployment and development guides.
