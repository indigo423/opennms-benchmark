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

## Loss is relative to a measured reference

About half of every nl6 trap workload is `authenticationFailure`, which this deployment discards, so the absolute persisted ratio sits near 0.5 with nothing wrong ([#212](https://github.com/indigo423/opennms-benchmark/issues/212)).
`persisted == sent` is therefore not a usable criterion.
The reference rung, run at the lowest sweep rate before the sweep and again inside it, defines what "lost nothing" means for this workload against this deployment.
`vs-ref` is measured against it.

## Controls

Sources are **provisioned** (foreign source `nl6-ft`, ICMP and SNMP only), so trapd resolves each trap against a cached node instead of paying a lookup miss per trap.
The requisition is built here rather than through the `opennms_requisition` role, because that role emits a `gNMI-Telemetry` service and `oc.*` meta-data, and TELEMETRYD is enabled on `kfk-exclusive` — an OpenConfig connector streaming from every node would be uncontrolled load.

`ftc_device_count` is a pinned control, not a variable.
Rate is per device, so the claim is scoped to this fleet shape: 2500/s from 10 sources is not necessarily the same workload as 2500/s from 500, because trapd may key work by source.

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
make experiment EXPERIMENT=fm-snmptrap-capacity DEPLOYMENT=kfk-exclusive
```

**Phase B — bisect.** 15-minute steady state between the Phase A bracket. Expect at least one rate that passed Phase A to fail here; that gap quantifies how much burst the deployment absorbs.

```bash
make experiment EXPERIMENT=fm-snmptrap-capacity DEPLOYMENT=kfk-exclusive \
  EXTRA_VARS='{"ftc_rates":[25,50,75,100],"ftc_window":"15m"}'
```

**Phase C — confirm.** Three trials at the surviving rate and three at the next step above. The upper set must fail for R_max to mean anything: a confirmed maximum needs a repeatable pass *and* a repeatable failure one step up.

```bash
make experiment EXPERIMENT=fm-snmptrap-capacity DEPLOYMENT=kfk-exclusive \
  EXTRA_VARS='{"ftc_rates":[50,50,50,75,75,75],"ftc_window":"15m"}'
```

## What a result claims

**Claims:** this deployment, on this provider, at this Horizon version, with a single Minion and single broker, sustains N traps/s fleet-wide from 10 provisioned simulated sources for the window with no measurable loss at socket, handoff or persistence — and at the next step up, loss appears at a named stage.

**Does not claim:** anything about a different fleet shape, multi-Minion scaling, or the *persisted* trap rate as a capacity figure. The persisted rate is roughly half the offered rate because of the discard. The headline is offered rate, because that is what the deployment has to absorb.

Scope is the distributed lab with the generator off-box, so absolute capacity claims are legal here.
A rung where the generator itself fell short fails the run rather than being recorded: that measures the generator, and publishing it as R_max would publish the generator's ceiling as the deployment's.
