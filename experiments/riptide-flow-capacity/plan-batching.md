# Experiment plan — riptide #382 client-side insert batching

```
Question:              Does client-side ClickHouse insert batching raise riptide's sustained
                       flow-ingest ceiling above the ~3,600 flows/s measured on 0.6.6, and does
                       it preserve delivered == persisted?

Hypothesis:            Yes. The 0.6.6 ceiling is insert-cadence-bound, not CPU-bound (~1.1 of
                       4 vCPU busy, ~150 inserts/s of ~24 rows). Batching at 10k rows / 2s
                       should collapse insert cadence below 1/s and NewPart cadence from ~8/s
                       to <1/s, moving the ceiling to the next bottleneck (enrichment or CPU).
                       Magnitude unknown — that is what the ladder is for.

Independent variable:  sut.config_delta  →  riptide.clickhouse.batch.enabled (true | false)
                       ONE build, one setting flipped. Everything else pinned.

Variants:              A "batch-off"  — batch.enabled=false; async-inserts then derives true
                                        (manage-schema=true), i.e. the pre-change per-record path
                       B "batch-on"   — batch.enabled=true (shipping default: 10k rows / 2s),
                                        async-inserts derives false

Controls:              Build: ONE image from feat/382-batch-clickhouse-inserts (both variants).
                       ClickHouse 26.7.1.1315 on ch-benchmark-01 (192.168.11.34), untouched.
                       Host: riptide-benchmark-01 (192.168.11.33), 4 vCPU, 8 GB, KVM.
                       net.core.rmem_max = 134217728 (the tuned value; kernel drops otherwise
                       confound the ceiling — see baseline finding).
                       Schema: manage-schema=true. Each variant writes to its OWN database
                       (riptide_batch_off / riptide_batch_on), created by manage mode. This
                       leaves the existing `riptide` database (1.57M flows from the 0.6.6
                       baseline) untouched — no destructive truncate — and isolates the two
                       variants' row counts and part_log cadence perfectly.
                       Enrichment: hostname (rDNS) enricher DISABLED in both variants — see
                       Safety below. Identical in both, so not a confound.
                       Generator: nl6 v0.20.x, same scenario, same seed, off-box.

Dependent metric:      PRIMARY   sustained accepted flows/s = highest ladder step where
                                 persisted == delivered (within reconciliation tolerance)
                       SUPPORT   inserts/s (system.query_log, query_kind=Insert)
                                 NewPart/s (system.part_log) for flows + 4 rollup targets
                                 rows-per-insert (written_rows)
                                 riptide CPU / persist latency; queue depth is NOT readable
                                 (no metrics exporter — see Known gap)

Load axis:             push-telemetry (IPFIX over UDP)

Scope:                 single realistic host — SUT on a dedicated VM, generator off-box
Claim class:           absolute capacity IS legal for this scope (and relative A/B)

Trials/warmup:         OVERRIDE of the ≥15-min default, declared deliberately:
                       Phase 1 (bracket) — ladder 1k/2k/4k/8k/16k/32k flows/s, 5 min per step,
                                           first 60 s discarded as ramp. Finds the knee.
                       Phase 2 (confirm) — one 15-min steady window per variant at its knee
                                           step, fully reconciled. This is the reported number.
                       Rationale: a 6-step ladder at 15 min/step × 2 variants is 3 h of steady
                       state alone. Bracketing coarse then confirming long gets the same answer
                       within the budget. The headline figure comes only from Phase 2.

Correctness diff:      REQUIRED (acceptance criterion of #382, and batching changes loss
                       semantics from "throws at the caller" to "counted and dropped").
                       Per window: nl6 send ledger `sent` vs ClickHouse row-count delta over
                       the same window, plus riptide's dropped/failed log lines. A step counts
                       as clean only at zero loss. Rollup sanity: each of the 4 target tables
                       gains rows.

Shared fixtures:       riptide OCI image built once from the PR branch (digest recorded in both
                       manifests). ClickHouse instance shared, table truncated between variants.
                       nl6 scenario file + seed identical across variants.

Wall-clock budget:     build + deploy            ~20 min
                       Phase 1: 6 steps × 5 min × 2 variants   60 min
                       Phase 2: 15 min × 2 variants            30 min
                       truncate/settle/switch between runs     ~20 min
                       measure + reconcile + report            ~20 min
                       ------------------------------------------------
                       ≈ 2 h 30 min
```

## Why not compare against the recorded 0.6.6 baseline as the headline

The stored runs are riptide **0.6.6**; the candidate is **0.6.7-SNAPSHOT** from the PR branch.
Using the stored number as variant A would put a version bump *and* a config change in the same
delta — unattributable, and the report's comparability gate would (correctly) refuse it. So both
variants run on the new build, and `batch.enabled=false` reproduces the pre-change path
(per-record inserts + async coalescing) on that build. The stored ~3,600 flows/s is used only as
a **sanity cross-check** on variant A: if A lands far from it, something else moved and the whole
experiment is suspect.

## Safety: rDNS storm (homelab)

A previous Mac-local flow benchmark flooded the homelab CoreDNS: synthetic flows carry random
10/8 addresses, riptide's hostname enricher reverse-resolves them, and a negative-caching bug
turns that into sustained query pressure on the resolver. At ladder rates up to 32k flows/s this
would be materially worse than the incident that was already observed.

Mitigation, applied identically to both variants (so it is a control, not a confound): the
hostname enricher is disabled for the whole run. This is also methodologically right — leaving it
on would measure the resolver, not the insert path.

## Known gap this run cannot close

riptide registers Dropwizard metrics but exports them nowhere (no reporter, no endpoint), so
`persister.batch.queueDepth`, `batchSize`, `flush` and the drop/fail counters are **not readable
during the run**. Buffer behaviour is therefore inferred from server-side evidence
(`system.query_log` rows-per-insert, `system.part_log` cadence) and from riptide's log lines,
not from the counters. Recorded in the manifest as a measurement limitation.
