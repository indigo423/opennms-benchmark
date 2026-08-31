# Deployment Library

A **deployment** is a "topology under test": which components run, how many nodes of each, and how they are grouped, expressed as provider-agnostic data.
One deployment can be provisioned onto any Terraform provider and can host many **experiments** (the workloads run against it).

The split matters.
A deployment describes the *system under test*; an experiment describes the *load*.
Keeping them apart is what lets one topology serve several benchmarks instead of being rebuilt for each.

```
deployments/
  <slug>/
    topology.yml            # the provider-agnostic spec (source of truth)
    opennms-lab-vars.yml    # optional Ansible overlay (kvm/aws only)
    playbook.yml            # optional playbook replacement (kvm/aws only)
  roles/                    # repo-local Ansible roles, on ansible.cfg's roles_path
  bin/
    topology-descriptor.py  # derive the canonical descriptor from a spec
```

## Status (Phase 2)

The specs and tooling here are live.
The Terraform **consumption** of a spec, translating it into a provider's `local.topology` so `make deploy DEPLOYMENT=… PROVIDER=…` provisions it, lands in Phase 2b, once the Phase 1 `for_each` refactor (topology-as-data) is merged per provider.
Until then, `make deployments` and `make deployment` list and validate the library, and the descriptor tool works standalone.

## Spec schema (`topology.yml`)

```yaml
name: mimir-ha                 # must equal the directory slug
description: 3-node HA Mimir stack, multi-Minion, nl6 load
roles:                         # keyed by component role
  elasticsearch:
    count: 3                   # node count (0 or omit = excluded)
    size: large                # t-shirt class (see below)
    subnets: [mgmt, db]        # ordered; first is the mgmt/primary NIC
    groups: [elasticsearch, docker_engine]   # Ansible inventory groups
  minion:
    count: 2
    size: small
    subnets: [mgmt, kafka, sim]
    routes: { sim: net_sim }   # named static route on the given subnet's NIC
    groups: [minion]
  monitoring:
    count: 1
    size: small
    subnets: [mgmt, external]
    public_ip: true            # jump host (external/DHCP NIC + public reachability)
    groups: [mon_servers, docker_engine, grafana]
```

### Roles to component codes

Each role maps to a stable 2–3 character code used in the canonical descriptor:

| role | code | role | code |
|---|---|---|---|
| `core` | `on` | `elasticsearch` | `es` |
| `minion` | `mn` | `mimir` | `mm` |
| `sentinel` | `sn` | `victoriametrics` | `vm` |
| `database` | `pg` | `rustfs` | `rs` |
| `kafka` | `kf` | `loadgen` (nl6) | `nl6` |
| `rrd` | `rr` | | |

`monitoring` is always-present infrastructure (Grafana, Prometheus, Jaeger) and is **excluded** from the descriptor.
`loadgen` is the nl6 generator, included by default; opt out by omitting the role or setting `count: 0`.
Opting out means also removing any `routes: { sim: net_sim }` from the spec, since that named route resolves to the generator (see below).

Keep `loadgen` at `count: 1`.
A named route's next hop is a single address, so only one node can serve it, and nl6 starts every generator at the same `nl6_auto_start_ip`, so a second generator duplicates the first rather than extending it.
Not currently enforced; see #173.

### Size classes (provider translates to concrete resources)

| class | vCPU | RAM | notes |
|---|---|---|---|
| `tiny` | 2 | 2 GiB | **shape/wiring test beds only.** Enough to start a service, not to measure one: a 2 GiB Elasticsearch gets a ~1 GiB heap. Never use in a benchmark topology |
| `small` | 2 | 4 GiB | db, kafka, minion, netsim, mon |
| `medium` | 2 | 8 GiB | |
| `large` | 4 | 8 GiB | elasticsearch |
| `xlarge` | 4 | 16 GiB | core |
| `xxlarge-mem` | 8 | 32 GiB | standalone VictoriaMetrics target; memory rises with vCPU because the store sizes its caches by RAM |

Each provider owns the class to SKU/flavour mapping (Azure `Standard_D*`, Hetzner `cx*`, or explicit `cores`/`memory` for libvirt and proxmox).
Disk sizes come from the provider's `disk_sizes_gb`, keyed by role.

Size is part of the experiment, not decoration.
A component that gains work relative to `baseline` usually needs a class with it: `kfk-exclusive` raises `kafka` to `medium` because that broker carries the entire metric stream on top of the IPC traffic, and a broker that saturates first makes the benchmark measure Kafka instead of OpenNMS.

### Subnets

`mgmt` (management plus Ansible/SSH), `db`, `kafka`, `sim` (SNMP simulation), `external` (DHCP bridge for the monitoring jump host), `lab` (the physical bridge LAN, statically addressed).
Interface order in `subnets` fixes NIC order on the VM.

Addresses on the internal subnets are derived by the provider from per-role blocks.
Do not assume them.
Two escape hatches exist for hosts that something outside the lab has to reach:

```yaml
roles:
  elasticsearch:
    subnets: [lab]                                       # physical bridge, not a NAT network
    addresses: { lab: ["192.168.11.33"] }                # pin per subnet, one entry per node
    routes: { lab: { to: "10.42.0.0/16", via: "192.168.11.73" } }   # inline route…
  minion:
    routes: { sim: net_sim }                             # …or a named shared route
```

The two forms are validated differently.
A **named** route resolves its next hop from a role inside the same spec, so the provider fails the plan unless that role is present *and* attached to the subnet the route needs: `net_sim` requires a `loadgen` with a `sim` NIC.
An **inline** `{ to, via }` deliberately points outside the topology and is not checked; use it when the next hop is a machine the spec does not provision.

Both preconditions are plan-time only.
`make validate-topology` renders every spec and asserts the same invariants without a hypervisor, so run it before pushing.
It is not yet a CI gate (#173), so CI will not catch a spec that validates against the schema but cannot be provisioned.

A `lab` NIC needs the provider to know the bridge LAN: `subnet_lab` (CIDR, for the prefix and gateway) and `lab_nameservers` (a physical LAN, unlike the libvirt NAT networks, usually runs no resolver on its gateway).
Pinned addresses are the deployment's contract with whatever is off-box.
The reason to use them is a generator or client that cannot discover the lab's addressing.

## Ansible overlay

A topology says which machines exist.
Some deployments also need to say how the stack on those machines is configured, and two optional files do that:

| File | Effect |
|---|---|
| `opennms-lab-vars.yml` | layered after the root `opennms-lab-vars.yml` as a second `--extra-vars` |
| `playbook.yml` | **replaces** `opennms-playbook.yml` for this deployment |

**Both are honoured for `kvm` and `aws` only.**
On `azure`, `proxmox` and `vmware` they are silently ignored, so a deployment that depends on them provisions and then comes up misconfigured with no warning.
Say so in the spec's `description` and in the index row below.

Two things to know before writing an overlay:

**Ansible replaces dicts, it does not merge them.**
`ansible.cfg` sets no `hash_behaviour`, so a dict in the overlay replaces whatever it shadows, wholesale.
That is exactly what you want for `opennms_properties_timeseries` (replacing it is how the collection's RRDTool defaults are removed) and a trap for `kafka_server_properties` (a partial override drops the KRaft settings and the broker will not start).
Restate the full dict, or do not touch it.

**A replacement playbook should import, not duplicate.**
`playbook.yml` substitutes for the whole stock playbook, so copying its plays guarantees drift.
Import it and add only what is new:

```yaml
- name: Deploy the stock OpenNMS stack
  ansible.builtin.import_playbook: ../../opennms-playbook.yml

- name: Something this deployment needs
  hosts: core
  become: true
  roles:
    - some_repo_local_role
```

Repo-local roles live in `deployments/roles/` and resolve by bare name, because `ansible.cfg` already has that directory on `roles_path`.
Reach for one only when the pinned `indigo423.opennms` collection cannot express the setting as a variable.

## Identifier scheme

- **slug** is the human handle (kebab-case), equals the directory name, and is used as hostname prefix, Terraform workspace, and Grafana label.
- **canonical descriptor** is machine-derived from the spec: `<count><code>` tokens in a fixed order joined by `-`, for example `3es-3mm-1pg-3sn-3kf-1on-2mn-nl6`.
  It is the reproducibility fingerprint recorded on results.

```bash
make deployment DEPLOYMENT=mimir-ha        # or:
python3 deployments/bin/topology-descriptor.py deployments/mimir-ha/topology.yml
```

Descriptor component order: `es mm vm ch ak rp rs rr pg sn kf on mn nl6`.

## Specs are asserted in CI

Every spec here is rendered through each spec-driven provider's own locals — `kvm`, `aws` and `proxmox` — and checked on every pull request by the **Deployment Topologies** job (`make validate-topology`). Four invariants, all of which `terraform validate` and `topology-descriptor.py` miss:

- two interfaces handed the **same address**
- a **named route** whose target role is absent from the spec, or present without the NIC the route needs
- a node with **no management address**, which Ansible would have no way to reach
- a **next hop that no node in the spec holds** — a well-formed address belonging to nothing

The last is the one that motivated the check. `es-nostore`, `rrd-minimal` and `vm-cluster-minion` all carried a dangling route for months while every gate stayed green, because `terraform validate` checks types rather than relationships between values, and resource preconditions only run at plan time.

Adding or editing a spec therefore means `make validate-topology` has to pass. It needs no hypervisor, credentials or state — `terraform console` evaluates the locals without contacting one — and `tests/topology-fixtures/` holds specs that must be *rejected*, one per invariant, so a regression in the check itself shows up as a fixture that stopped failing rather than as a quiet clean run.

## Deployment index

| slug | descriptor | notes |
|---|---|---|
| `baseline` | `1es-1pg-1kf-1on-1mn-nl6` | the current single-node lab (reference) |
| `mimir-ha` | `3es-3mm-1pg-3sn-3kf-1on-2mn-nl6` | full HA Mimir plus Sentinel |
| `rrd-minimal` | `1rr-1pg-1kf-1on-1mn` | RRDTool on core, minimal |
| `vm-cluster-es` | `1es-3vm-1pg-1on` | VictoriaMetrics cluster plus ES flows |
| `es-nostore` | `1es-1pg-1kf-1on-1mn` | ES flows, no metrics TSDB |
| `kfk-exclusive` | `1pg-1kf-1on-1mn-nl6` | Kafka-exclusive metric forwarding: `baseline` minus Elasticsearch, no local TSDB. Ships an overlay and a `playbook.yml`, so **kvm/aws only** |
| `vm-cluster-minion` | `3vm-1pg-1kf-1on-1mn` | VictoriaMetrics cluster plus minion |
| `vm-single` | `1vm-1pg-1on` | single VictoriaMetrics |
| `vm-target` | `1vm` | **standalone target**, one VictoriaMetrics on the physical `lab` bridge for a stack provisioned elsewhere to `remote_write` to. Declares the `lab` subnet and ships an overlay, so **kvm only**: `aws` and `proxmox` fail the deployment at plan time |
| `mimir-single` | `1mm-1pg-1on` | single Mimir |
| `es-cluster-min` | `3es` | **component test bed**, verifies Elasticsearch cluster formation on a footprint that fits the lab (28 GB) |
| `kafka-cluster-min` | `3kf` | **component test bed**, verifies KRaft cluster formation (shared cluster ID, quorum, RF 3) at 28 GB |
| `mimir-cluster-min` | `3mm-1rs` | **component test bed**, verifies Mimir cluster formation against shared object storage at 36 GB |
| `mimir-ha-min` | `3es-3mm-1rs-1pg-3sn-3kf-1on-2mn-nl6` | **shape test bed**, the HA wiring at 50 GB on `tiny` nodes; proves the topology, not suited for measuring |

**Reading the index.**
`rrd-minimal` lists RRDTool without a Core, but RRD is a Core storage strategy, so it and `baseline` both include `core` with the strategy set at the Ansible layer.
`kfk-exclusive` lists no TSDB component at all for the same reason inverted: its metrics leave via the Kafka Producer, so the `metrics` topic is the store.

**Test beds are not benchmarks.**
The four entries marked above exist to prove a component forms a cluster or a topology wires up on hardware that fits the lab.
They are sized to boot, not to measure, and a number taken from one means nothing.

**Not every component deploys yet.**
Specs naming mimir, victoriametrics or sentinel are valid data now, but their Ansible roles and provider translation are still to come.
Such a spec will validate and will not yet deploy.
