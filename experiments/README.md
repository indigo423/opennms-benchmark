# Experiments

An **experiment** is the workload: which protocols are driven, at what rate, against how many devices, and the requisition that matches.
The **deployment** is the system under test.
The **campaign** is the sealed record of a run, and it lives in `campaigns/`.

Keeping the three apart is what lets one topology serve several benchmarks. It is why nothing about load belongs in `deployments/`, and why nothing about the system under test belongs in an experiment's or a record's name.

```bash
make experiment PROVIDER=<provider> EXPERIMENT=<name>
```

That runs `experiments/<name>/experiment.yml` against the generated inventory, with the root variables and the experiment's own overlay layered on top.

## What an experiment may assume

**The generated inventory.** `ansible-inventory.<provider>.yml` is written by Terraform and names every host and group. An experiment never ships its own copy: a hand-maintained inventory drifts from the lab silently, and a play that targets an address nothing answers on produces a clean zero rather than an error.

**The endpoints manifest.** `lab-endpoints.<provider>.yml` (and its `.json` sibling) says where telemetry is accepted and where results are read, for the deployment as provisioned. Regenerate it any time with `make endpoints PROVIDER=… DEPLOYMENT=…`. An experiment reads it rather than restating addresses and ports:

```yaml
ingestion:
  syslog: {host: …, port: …, via: minion}
  traps:  {host: …, port: …, via: minion}
measurement:
  kafka: {bootstrap: …, topics: {metrics: …}}
generators:
  nl6: {url: …, sim_network: …}
observability:
  pyroscope: {url: …}
```

The tools installed on the monitoring node already read it from `/etc/lab-endpoints.json`, so `kafka-metrics-report` and `nl6-loadtest` need no endpoint arguments.

**Group names come from the topology spec.** `core`, `minion`, `database`, `message_broker`, `mon_servers`, `net_sim`. Not `onms_core` or `onms_minion`; those never existed in a generated inventory.

## What an experiment owns

- The fleet: how many simulated devices, created through the nl6 API, and the collectors and protocols they export to.
- The requisition matching that fleet.
- Rate, window and profile for each scenario.
- Any OpenNMS configuration that describes the *workload* rather than the system under test, such as `collectd-configuration.xml`.

Device addresses must fall inside the deployment's `sim_network`.
`nl6-loadtest` asserts this: outside it there is no Minion route and no forwarding rule, so load is sent and silently discarded while the system under test appears to have dropped it.

## Layout

```
experiments/
  <name>/
    experiment.yml         # the playbook; hosts: core, minion, …
    opennms-lab-vars.yml   # optional overlay, layered after the root vars
    roles/                 # experiment-local roles
  flows-es-vs-victorialogs/    # standalone harness with its own runner
  nms-20027-painless-flows/    # standalone harness with its own runner
  inventory/               # requisition and fleet helpers, not an experiment
  legacy/                  # pre-rebuild, reference only — see below
  roles/                   # roles shared across experiments
```

Everything here can be run. One test decides whether a directory belongs: it has an `experiment.yml`, or it has its own `bin/` runner, or it is shared tooling. `make experiments` lists the first kind, which is now the whole of `experiments/*/experiment.yml` rather than a subset of the tree.

**A record of a run that has already happened belongs in `campaigns/`, not here.** It has no playbook and no runner, because the run is over and what remains is its evidence. See `campaigns/README.md`, which indexes every one of them.

The two standalone harnesses predate this structure, carry their own scripts and reports, and are run directly rather than through the front door.

No `ansible.cfg`, no `inventory`, no `opennms-lab-inventory.yml`. The repository root owns all three.

## A record and its experiment share a slug

`experiments/pm-snmp-target/experiment.yml` is the workload; `campaigns/pm-snmp-target/results/` is what it produced. Same slug, other tree, and that convention is the only association there is.

It follows that nothing about the system under test belongs in a directory name on either side. `deployments/` owns the system under test, and where a record needs to say which heap, which pool or which `max-repetitions` it ran at, the index in `campaigns/README.md` carries it. Sixteen records were named that way before, and seven of them differ in nothing else.

## `legacy/` is reference, not runnable

The four `c1km1_*` directories predate this structure and are kept for the configuration they encode, which is worth preserving. They cannot be run as they stand:

- Their inventories carry addresses from before the `role_block_size` refactor. `c1km1_4c16g_kfk_pm_snmp/inventory` names `192.0.2.197` and `192.0.2.199`; the lab now uses `192.0.2.200` and `192.0.2.208`. Running one targets two hosts that do not exist.
- Two of them use `onms_core` and `onms_minion`, group names no generated inventory has ever produced.
- Their `ansible.cfg` sets `remote_user = labuser`, which matches no lab the repository provisions: the generated inventory sets `ansible_user` from the provider's admin user, `ubuntu` on kvm and `azureuser` elsewhere. Their own inventories set no user at all, so the stale `labuser` is what a run would use.
- All three `opennms-lab-inventory.yml` files group hosts under `opennms-stack`, hyphenated, while both inventory templates emit `opennms_stack`. So every one of them names at least one group nothing produces, not only the two ini inventories above.
- They mix system-under-test configuration with workload, which is what `deployments/` now owns.

Read them for what they configure. Do not point them at a lab.
