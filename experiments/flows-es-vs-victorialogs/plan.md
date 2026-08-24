<!--
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0
-->

# Stage-0 plan: OpenNMS flow backend A/B — Elasticsearch (painless) vs. VictoriaLogs

This plan text is copied verbatim into `experiment.plan` of every run manifest.

## Question

For OpenNMS flow persistence and querying on identical hardware, how does the
VictoriaLogs backend (`features/flows/victorialogs`, LogsQL) compare to the
Elasticsearch backend on its post-NMS-20027 path (inline Painless
`proportional_sum`, no drift plugin) — in sustained IPFIX ingest capacity and
in flow-query latency?

## Hypothesis

VictoriaLogs sustains at least the same ingest rate at lower store-side CPU
and disk footprint, and answers the dense whole-window query shape within the
same order of magnitude as Elasticsearch. (Directional expectation from the
backend's design notes; the experiment measures it either way.)

## Independent variable

The flow storage backend, declared as `sut.config_delta`:

- **variant-a-es-painless** — `org.opennms.features.flows.persistence.elastic.cfg`
  present (`elasticUrl=http://192.168.11.36:9200`, `proportionalSumStrategy=painless`);
  VictoriaLogs cfg absent (module self-disables).
- **variant-b-victorialogs** — `org.opennms.features.flows.persistence.victorialogs.cfg`
  present (`url=http://192.168.11.36:9428`, `httpCompression=false`,
  `skipVictoriaLogsPersistence=false`, `skipVictoriaLogsQueries=false`);
  Elasticsearch cfg absent.

Nothing else in `${OPENNMS_HOME}/etc` may differ between the variants.
`httpCompression=false` removes the transport confound the backend's own
blueprint documents (VL would otherwise gzip while the ES client does not).

## Variants

| Variant | Persist + query path | Store service active on 192.168.11.36 |
|---|---|---|
| A `es-painless` | Elasticsearch 8.18.2, Painless scripted_metric | `elasticsearch.service` (VL stopped) |
| B `victorialogs` | VictoriaLogs 1.52.0, LogsQL | `victoria-logs.service` (ES stopped) |

The inactive store's service is stopped during measured windows so the idle
engine cannot steal page cache or CPU on the shared flow-store VM.

## Controls (pinned; all enter the comparability key)

- **One build**: OpenNMS Horizon 37.0.0-SNAPSHOT @ `bddd104c1016aedcdf5f3cf69c1ae9485b94cdcc`
  (= NMS-20027 `03b6b6dd8cf` cherry-picked onto `ronny-poc/victorialogs-flows`
  @ `b00f049ec32`; local branch `bench/nms-20027-vs-victorialogs`).
  Assembly core tarball sha256
  `ce8b7c9044b6c04af3f9f97234fcdd3c00207c101451a76e8f73758a8b0e5e52`,
  installed once on the core VM (skill ssh-tarball provisioner); variants flip
  etc config only.
- **Deployment**: `deployments/es-victorialogs` on the KVM provider —
  core `xlarge` (4 vCPU/16 GiB, 192.168.11.35), flow-store `large`
  (4 vCPU/8 GiB, 192.168.11.36) carrying both engines, PostgreSQL 18 `small`
  (192.168.11.37). All on the physical lab bridge.
- **JVM**: identical heap/GC flags both variants (probed via `jcmd VM.flags`
  into the manifest, not asserted from config).
- **Telemetryd**: identical `telemetryd-configuration.xml` (stock file +
  `Multi-UDP-9999` listener enabled) in both variants — part of the shared
  config delta, applied identically.
- **tss backend**: identical (default RRD; not exercised by the flow axes).
- **Workload**: nl6 on monkey-head (off-box), same fleet, same scenario
  parameters and `seed` for every window; `workload.generator_version` = the
  running nl6 version/digest.
- **Elasticsearch cluster**: stock collection install (ES 8.18.2 + drift
  plugin 2.0.7 present but idle — the painless path does not use it); shard
  request cache disabled on `netflow-*` before query trials (the
  nms-20027 experiment measured 10.7 s cold vs 0.04 s cached — trials would
  otherwise benchmark the cache).

## Dependent metrics

1. **Ingest axis** (`workload.axis=push-telemetry`, IPFIX):
   per steady-state window — offered (nl6 ledger `in_window`) vs received
   (telemetryd counters over the same `[T0,T1)`) vs persisted (store doc
   count delta); core CPU + GC timeline; flow-store CPU/IO.
2. **Query axis**: latency of the fixed query set (dense whole-window and
   sparse fine-window shapes, `queries/queries.json`) via the core flow REST
   API; median/p95/min–max over trials 2–6.
3. **Correctness diff** (mandatory): a dual-write phase populates BOTH stores
   with the same flow stream, then the identical query set is answered by
   each backend (flip the query-service registration) and the returned
   series/totals are diffed. The report presents the latency delta and the
   correctness delta side by side.

## Load axis / axes

Push telemetry, IPFIX only (one protocol per scenario). nl6 scenario `rate`
is export cadence, not flow volume (~constant flows/s per exporter, measured
~7.9 on this nl6 version by the riptide experiment) — offered load is scaled
by exporter count, and the realized flows/s is whatever the ledger says.

## Scope and claim class

Generator off-box (monkey-head), SUT on dedicated VMs → **relative A/B and
absolute capacity claims are valid** for this host class. Not claimable:
distributed-path effects (no Minion/Kafka in the path). KVM guests cannot pin
the host governor; the hypervisor (mad-monkey) runs no other active VMs
during the experiment — recorded in `host.hygiene_notes`.

## Trials / warmup

- Ingest: per variant, ≥5 min ramp (excluded), then 3 windows × 15 min
  steady state, each reconciled independently.
- Query: 6 trials of the full query set per variant, trial 1 discarded.
- Correctness: one dual-write window (15 min), then the query set against
  each backend once; diff.

## Shared fixtures

Build once (tarball above). nl6 fleet created once. Each variant ingests its
own corpus from the same seeded scenario (the store is the thing under test,
so a shared stored corpus is impossible by construction); corpus identity
(doc count + seed + window) goes into `workload.fixtures` per run, and the
query trials of a variant run against that variant's own corpus, doc count
verified unchanged before and after.

## Correctness confound

Both query paths implement the NMS-20001-corrected proportional attribution
(painless on ES, ProportionalSumQuery on VL), so gross totals should agree —
but VL's `maxFlowDurationMs` (default 120 000 ms) silently under-attributes
flows longer than its cap, and `ElasticFuzziness` documents expected rounding
differences. The dual-write diff quantifies all of it; no speed claim ships
without it.

## Wall-clock budget

| Step | Time |
|---|---|
| Lab deploy + tarball provision | ~1.5 h |
| Variant A: ramp + 3×15 min + queries | ~1.5 h |
| Variant B: same | ~1.5 h |
| Dual-write + correctness diff | ~0.75 h |
| **Total** | **~5.5 h** |
