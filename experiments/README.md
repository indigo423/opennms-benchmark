# Experiments

An **experiment** is the workload: which protocols are driven, at what rate, against how many devices, and the requisition that matches.
The **deployment** is the system under test.
Keeping them apart is what lets one topology serve several benchmarks, and it is why nothing about load belongs in `deployments/`.

```bash
make experiment EXPERIMENT=<name>
```

That runs `experiments/<name>/experiment.yml` against the generated inventory, with the root variables and the experiment's own overlay layered on top.

## What an experiment may assume

**The generated inventory.** `ansible-inventory.yml` is written by Terraform and names every host and group. An experiment never ships its own copy: a hand-maintained inventory drifts from the lab silently, and a play that targets an address nothing answers on produces a clean zero rather than an error.

**The endpoints manifest.** `lab-endpoints.yml` (and its `.json` sibling) says where telemetry is accepted and where results are read, for the deployment as provisioned. Regenerate it any time with `make endpoints PROVIDER=… DEPLOYMENT=…`. An experiment reads it rather than restating addresses and ports:

```yaml
ingestion:
  syslog: {host: …, port: …, via: minion}
  traps:  {host: …, port: …, via: minion}
measurement:
  kafka: {bootstrap: …, topics: {metrics: …}}
generators:
  nl6: {url: …, sim_network: …}
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
  legacy/                  # pre-rebuild, reference only — see below
  inventory/               # requisition and fleet helpers, not an experiment
  nms-20027-painless-flows/    # standalone harness with its own runner
  riptide-flow-capacity/       # standalone harness with its own runner
```

`make experiments` lists only the playbook-driven ones. The two standalone harnesses predate this structure, carry their own scripts and reports, and are run directly rather than through the front door.

No `ansible.cfg`, no `inventory`, no `opennms-lab-inventory.yml`. The repository root owns all three.

## `legacy/` is reference, not runnable

The four `c1km1_*` directories predate this structure and are kept for the configuration they encode, which is worth preserving. They cannot be run as they stand:

- Their inventories carry addresses from before the `role_block_size` refactor. `c1km1_4c16g_kfk_pm_snmp/inventory` names `192.0.2.197` and `192.0.2.199`; the lab now uses `192.0.2.200` and `192.0.2.208`. Running one targets two hosts that do not exist.
- Two of them use `onms_core` and `onms_minion`, group names no generated inventory has ever produced.
- Their `ansible.cfg` sets `remote_user = labuser` while the inventory sets `ansible_user: ubuntu`.
- They mix system-under-test configuration with workload, which is what `deployments/` now owns.

Read them for what they configure. Do not point them at a lab.
