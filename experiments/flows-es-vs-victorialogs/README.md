<!--
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0
-->
# Flow backend A/B: Elasticsearch (painless) vs. VictoriaLogs

A/B benchmark of the two OpenNMS flow backends on identical hardware: Elasticsearch on its post-NMS-20027 path (inline Painless `proportional_sum`, no drift plugin) versus the `features/flows/victorialogs` module (`ronny-poc/victorialogs-flows`). Full Stage-0 design: [`plan.md`](plan.md).

Like `riptide-flow-capacity` this is a standalone harness on the KVM lab, not a `make experiment` playbook. Generator off-box (nl6 on monkey-head) → relative A/B **and** absolute capacity claims valid.

## One paragraph

One build — NMS-20027 (`03b6b6dd8cf`) cherry-picked onto `ronny-poc/victorialogs-flows`, merged SHA `bddd104c101`, assembly tarball installed once on the core VM (ssh-tarball provisioner). Two variants that differ only in which flow-persistence cfg exists in `etc/`: **A** = Elasticsearch 8.18.2 + `proportionalSumStrategy=painless`, **B** = VictoriaLogs 1.52.0 with `httpCompression=false` (kills the transport confound). The flow-store VM (`es-benchmark-01`, 4c/8G) carries both engines; the inactive one is stopped during measured windows. Per variant: 3 × 15-min reconciled IPFIX ingest windows (nl6 send-ledger vs store doc counts), then 6 timed trials of the fixed dense/sparse query set (trial 1 discarded). A dual-write phase feeds both stores the same stream for the mandatory correctness diff — no speed claim ships without it.

## Layout

| Path | Purpose |
|---|---|
| `plan.md` | Stage-0 plan (copied into every manifest's `experiment.plan`) |
| `../../deployments/es-victorialogs/` | The SUT topology (core, PostgreSQL, dual-engine flow store) |
| `variants/common/` | Config identical in both variants (telemetryd `Multi-UDP-9999`) |
| `variants/variant-a-es-painless/` | ES cfg — the IV, side A |
| `variants/variant-b-victorialogs/` | VL cfg — the IV, side B |
| `correctness/` | Dual-write correctness-diff procedure |
| `queries/queries.json` | Fixed dense/sparse query set (from nms-20027) |
| `bin/` | Harness: provision, apply-variant, ingest windows, query trials, manifest |
| `build/`, `results/` | Generated at run time — gitignored |

## Runbook

```sh
# 0. Lab up (once):
make deploy PROVIDER=kvm DEPLOYMENT=es-victorialogs

# 1. SUT on the core VM (once; identity → build/sut-identity.json)
./bin/provision-core.sh

# 2. Variant A
./bin/apply-variant.sh variant-a-es-painless
./bin/run-ingest-window.sh variant-a-es-painless 200 15m w1   # ramp: run a 5m
./bin/run-ingest-window.sh variant-a-es-painless 200 15m w2   # window first and
./bin/run-ingest-window.sh variant-a-es-painless 200 15m w3   # discard it
T0/T1 from results/variant-a-es-painless/window-w1/counts.json:
./bin/run-queries.sh variant-a-es-painless <T0> <T1>
./bin/emit-manifest.sh variant-a-es-painless A1

# 3. Variant B — same, with variant-b-victorialogs

# 4. Correctness (dual-write)
./bin/apply-variant.sh dual-write
./bin/run-ingest-window.sh dual-write 200 15m corr
./bin/run-queries.sh correctness-es <T0> <T1>     # ES answers
./bin/apply-variant.sh dual-write-flip
./bin/run-queries.sh correctness-vl <T0> <T1>     # VL answers
./bin/diff-quality.py results/correctness-es/queries/raw results/correctness-vl/queries/raw

# 5. Report: splice runs+manifests into the skill's report-template.html
```

## Verify-at-use gates

- nl6 fleet/scenario field names were verified against `riptide-flow-capacity/run_scenario.sh`, not docs — re-verify if the nl6 version on monkey-head moved past v0.20.x.
- ES shard request cache is disabled by `run-queries.sh` before trials (10.7 s cold vs 0.04 s cached measured in nms-20027).
- Reconciliation disqualifiers: non-zero `send_failures`/`dropped` in a ledger, or received > offered → rerun, don't report.
- VL `maxFlowDurationMs` default (120 s) silently under-attributes longer flows — part of the correctness diff, not a latency footnote.
