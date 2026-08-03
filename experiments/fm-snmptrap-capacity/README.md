<!--
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0
-->
# fm-snmptrap-capacity

The maximum sustained SNMP trap rate a deployment accepts without data loss.

## What this measures, and why it is not `fm-snmptrap`

`fm-snmptrap` sweeps a fixed ladder at 30-second windows and reports a fidelity table.
It answers *"does this path carry traffic, and does fidelity move with rate"*.
It cannot answer *"what is the maximum sustained rate"*: 30 seconds at 2500 traps/s is 75k traps, which Kafka sink batching, the eventd queue and Postgres absorb and then drain during the settle.
A rate that passes at 30 seconds can collapse over 15 minutes.

The answer here is **R_max**: the highest offered fleet-wide rate passing all three tiers.

| Tier | Criterion | Answers |
|---|---|---|
| 1 socket | Minion UDP `InErrors` + `RcvbufErrors` delta is 0 | Did the kernel drop traps before OpenNMS saw them? |
| 2 handoff | Sink consumer lag returns to its pre-rung level | Is the Minion keeping up, or is the Core behind? |
| 3 end-to-end | `vs-ref >= ftc_fidelity_floor` and no decline across per-minute buckets | Did anything fail to persist? |

Report all three. Where they diverge is the diagnosis: tier 1 alone means the Minion's socket buffer is too small, tier 2 alone means the Core consumer is the limit, tier 3 alone with 1 and 2 clean means eventd or Postgres.

Tier 2 reads **lag**, not the offset delta.
The sink batches at a rate-dependent size, so the delta counts Kafka messages rather than traps and cannot be compared against the generator's ledger ([#215](https://github.com/indigo423/opennms-benchmark/issues/215)).
Lag is immune to batch size, and it is also the only honest drain signal: the simulated fleet emits continuously, so waiting for a count to stop moving never fires.

## The path is pinned to trapd → eventd → database

`SNMP_Authen_Failure` ships with:

```xml
<alarm-data reduction-key="%uei%:%dpname%:%nodeid%" alarm-type="3" auto-clean="true"/>
```

Every authenticationFailure trap from a node reduces onto one alarm, and alarmd's auto-clean then **deletes the older events backing it**.
The traps are received, decoded and persisted normally. The rows are removed afterwards.

Measured on the lab, at the ten-device fleet this was first found on: **ten alarms, one per node, carrying a summed counter of 61,672**, against an events table holding a few hundred survivors. The traps arrived. The rows did not stay.

With alarmd pinned off the same harness persisted 1,133,649 events against 1,133,400 sent — a ratio of 1.0002, the excess being the fleet's own background traps.

This is fatal to a row-counting measurement in a way a filter would not be.
A filter removes a fixed share of the workload, and a reference ratio normalises that away.
This removes rows *after* they are counted in, asynchronously, so the surviving share depends on when the bracket closes: the same 2,990-trap run showed 1,099 survivors moments after finishing and settled towards ~50% later.
The correction moves with load, which is the independent variable, so no reference can absorb it.

`ftc_core_services` therefore pins two daemons off, for two different reasons:

| Daemon | Why | Class |
|---|---|---|
| `ALARMD` | Performs auto-clean, which deletes the rows the sweep counts | Correctness |
| `EVENTTRANSLATOR` | Per-event hot-path work unrelated to trap ingestion | Isolation |

Neither is the **Event Correlator**, which `kafka-exclusive` already ships disabled (`CORE_SERVICE_CORRELATOR_ENABLED="false"`) — the deletions happened with the correlator off.
Both default to `true` in the shipped `service-configuration.xml`, so both are in the path unless pinned.

Disabling daemons rather than editing the event definition is deliberate.
Editing `SNMP_Authen_Failure` fixes the symptom for one UEI while leaving alarm creation and reduction on the hot path, so the benchmark would still be timing alarmd, and it mutates a stock definition that outlives the run.

"With alarm processing" and "with event translation" are each their own experiment against this same harness.

This was previously mis-diagnosed as an ingress discard ([#212](https://github.com/indigo423/opennms-benchmark/issues/212)).
Nothing was ever dropped.

## Loss is still relative to a measured reference

With auto-clean off the reference should land near 1.0, but it is measured rather than assumed.
An assumed 1.0 is exactly what hid this bug for two releases: the ratio sat at 0.500 and read as a plausible property of the workload.
The reference rung, run at the lowest sweep rate before the sweep and again inside it, defines what "lost nothing" means for this workload against this deployment, and `vs-ref` is measured against it.

## Controls

Sources are **provisioned** (foreign source `nl6-ft`, ICMP and SNMP only), so trapd resolves each trap against a cached node instead of paying a lookup miss per trap.
The requisition is built here rather than through the `opennms_requisition` role, because that role emits a `gNMI-Telemetry` service and `oc.*` meta-data, and TELEMETRYD is enabled on `kafka-exclusive` — an OpenConfig connector streaming from every node would be uncontrolled load.

**The fleet's syslog is silent** (`ftc_syslog_collector: ""`), so this measures the trap path and only the trap path.
Left on, the fleet emits syslog every 10 seconds per device down the same Minion sink, Kafka topic, eventd queue and Postgres table the traps use.
That stream competes for the exact capacity under test.
Excluding it from the count by `eventsource`, which the sweep does, removes it from the arithmetic but not from the system, so R_max comes out depressed by an amount nothing in the table reveals.

`ftc_device_count` is a pinned control, not a variable.
Rate is per device, so the claim is scoped to this fleet shape: 10,000/s from 100 sources is not necessarily the same workload as 10,000/s from 10, because trapd may key work by source.

It is set to **100** because 10 could not drive the deployment hard enough.
Asking ten devices for a fleet-wide 10,000/s means 1,000 traps/s out of each simulated agent, and nl6 ran out of headroom there — it delivered 563,490 of 600,000 (93.9%), and the delivery gate correctly refused to report that as a property of the deployment.
Spreading the same fleet-wide rate over 100 devices asks a tenth as much of each, and is the more realistic shape anyway.

**The `events` table size is a control.** Insert throughput is a function of table size and its 13 btree indexes, so a run starting from an arbitrary table is not reproducible, and R_max drifts downward as the sweep itself adds rows. Reset before Phase B and again before Phase C:

```sql
-- with OpenNMS stopped
truncate table events cascade;
vacuum full analyze events;
```

## Running the phases

The bisection between phases is an operator decision: Ansible has no loop that expresses a search, and encoding one would mean a shell block doing the real work or a driver script bypassing `make`.
Each phase is one run with an explicit ladder.

**Phase A — bracket.** Coarse ladder, 60s windows. Makes no claims; finds the two adjacent rates spanning the first tier-3 failure.

```bash
make experiment EXPERIMENT=fm-snmptrap-capacity DEPLOYMENT=kafka-exclusive
```

**Phase B — bisect.** 15-minute steady state between the Phase A bracket. Expect at least one rate that passed Phase A to fail here; that gap quantifies how much burst the deployment absorbs.

```bash
make experiment EXPERIMENT=fm-snmptrap-capacity DEPLOYMENT=kafka-exclusive \
  EXTRA_VARS='{"ftc_rates":[25,50,75,100],"ftc_window":"15m"}'
```

**Phase C — confirm.** Three trials at the surviving rate and three at the next step above. The upper set must fail for R_max to mean anything: a confirmed maximum needs a repeatable pass *and* a repeatable failure one step up.

```bash
make experiment EXPERIMENT=fm-snmptrap-capacity DEPLOYMENT=kafka-exclusive \
  EXTRA_VARS='{"ftc_rates":[75,75,75,100,100,100],"ftc_window":"15m"}'
```

## What a result claims

**Claims:** this deployment, on this provider, at this Horizon version, with a single Minion and single broker, sustains N traps/s fleet-wide from 10 provisioned simulated sources for the window with no measurable loss at socket, handoff or persistence — and at the next step up, loss appears at a named stage.

**Does not claim:** anything about a different fleet shape, multi-Minion scaling, or the *persisted* trap rate as a capacity figure. The persisted rate is roughly half the offered rate because of the discard. The headline is offered rate, because that is what the deployment has to absorb.

Scope is the distributed lab with the generator off-box, so absolute capacity claims are legal here.
A rung where the generator itself fell short fails the run rather than being recorded: that measures the generator, and publishing it as R_max would publish the generator's ceiling as the deployment's.
