# Campaigns

A **campaign** is the sealed record of a benchmark that has already run.
It is evidence, not configuration, and there is nothing here to execute: no `experiment.yml`, no runner.
The workload that produced it lives in `experiments/`, and the system under test in `deployments/`.

That is the whole distinction. If a directory can be run it belongs in `experiments/`; if it is the record of a run it belongs here.
`make experiments` lists the runnable ones and deliberately says nothing about this tree.

## Reading a record

A record is self-contained and addresses its own contents relatively, so its path can change without anything inside it breaking.
Most carry `results/report.md`, the narrative, with a `manifest-1.json` beside it describing the run's provenance: the system under test, the host, the workload, the window, and the questions the run does and does not answer.

The bulk of a capture is not in git.
`.gitignore` tracks the manifest, the config, the checksums and the report, and leaves the payload on disk: `hosts/`, `prometheus/series/`, `kafka/`, `bundle/` and the report tarball run to tens of GB per record, and one `SHA256SUMS` here covers 3,966 files and 72.7 GiB.
A clone therefore holds the findings and the provenance, not the raw artifact.

## Linking a record to its experiment

Same slug, other tree.
`campaigns/pm-snmp-target/results/` is the record of `experiments/pm-snmp-target/experiment.yml`.
That is a convention rather than a key in a file, and it is the only association there is.

## The records

Fleet sizes are collectable services unless stated. "Binds" names the resource that ran out.

| Record | Variable it moved | Fleet | Finding | Read against |
|---|---|---|---|---|
| `pm-snmp-target` | the 72M/h target | — | 79.3M metrics/h sustained | `pm-snmp-14k` |
| `pm-snmp-14k` | fleet size, cleanroom | 14,004 → 15,004 | limit bracketed, pass to fail | `-cleanroom` |
| `pm-snmp-14k-cleanroom` | steady state at the limit | 14,000 | 292.1M metrics/h over 84 cycles | `pm-snmp-14k` |
| `pm-snmp-agent-latency` | agent latency, 100 threads | 2,500 → 3,000 | knee; the pool binds | `-pool200`, `-mr5` |
| `pm-snmp-agent-latency-pool200` | pool 100 → 200 | 5,000 → 5,250 | knee doubles with the pool; the pool binds | `pm-snmp-agent-latency` |
| `pm-snmp-agent-latency-mr5` | `max-repetitions` 2 → 5 | 11,750 → 12,250 | 2.3x on one attribute; **the heap binds at 300 threads**, corrected by `pm-snmp-sizing-rule` | `-pool200`, `-mr5-live` |
| `pm-snmp-agent-latency-mr5-live` | the mr5 knee, live and sealed | 14,250 | 87.2% of required collections; every service in the queue | `-mr5` |
| `pm-snmp-agent-latency-32g-live` | heap 10 → 20 GiB | 17,250 | 100.1% of required collections; nothing to spare | `-32g-pool400-live` |
| `pm-snmp-agent-latency-32g-pool400-live` | pool 300 → 400 on 32 GiB | 19,750 → 20,250 | the processor's knee, the last one in the campaign | `-32g-live` |
| `pm-snmp-kafka-compression` | Kafka codec | 19,250 | Minion lz4 cuts its link traffic to 13%, paid for in Core CPU | `-32g-pool400-live` |
| `pm-snmp-outage` | all agents unreachable, 3 cycles | 11,000 | recovery in one cycle | `pm-snmp-partial-outage` |
| `pm-snmp-partial-outage` | 25 / 50 / 75 / 100% unreachable | 11,000 | every resource falls linearly; an unreachable agent is the cheap outage | `pm-snmp-outage` |
| `pm-snmp-sizing-rule` | **derived, no new measurement** | — | two constants and three limits, fitted across eight knees | every knee search above |

### Sealed captures without a narrative

These are benchmark-capture artifacts that a reported record reads from. They carry `capture.yaml`, `manifest.json`, `SHA256SUMS` and the Prometheus metadata, and no `report.md`.

| Record | What it captures |
|---|---|
| `pm-snmp-14k-live` | the 14k fleet, live |
| `pm-snmp-14k-soak` | the 14k fleet, sustained |
| `pm-snmp-agent-latency-live` | the latency search, live |

The `-live` suffix does not mean "no report": `-mr5-live`, `-32g-live` and `-32g-pool400-live` all carry one and are in the table above. It marks a run against the live lab rather than the cleanroom.

### Records that do not follow the `results/` convention

| Record | Form |
|---|---|
| `pm-snmp-latency` | `HANDOFF.md`, `RUNBOOK.md`, per-rung `.jsonl` and the drivers in `results/bin/`. No report; the sweeps feed `pm-snmp-sizing-rule` |
| `nl6-flow-emission-shape` | `README.md`, `analyse-pcap.py` and tracked `captures/*.pcap`. No `results/` directory at all |

Both are recorded as they are rather than reshaped to fit. A record's value is that it is what was produced.

## Two things a reader should know

**The `pm-snmp-agent-latency` family is one search in seven directories.**
The differentiators are heap size, pool size, `max-repetitions` and cleanroom-versus-live, all properties of the system under test rather than the workload.
Three of the seven are only meaningful read as a pair, which is what the "Read against" column is for.
The directories stay flat because grouping them is a separate judgement, and paths are expensive to move twice.

**`campaigns/pm-snmp-latency/results/bin/runbook_exec.py` names its old `experiments/` path, and that is deliberate.**
`ruff.toml` excludes that directory because the value of a driver there is being byte-for-byte what produced the `.jsonl` beside it.
Editing a path inside one to tidy it up would break the guarantee the exclusion exists to protect.
Read `experiments/pm-snmp-latency/` in that file as `campaigns/pm-snmp-latency/`.
