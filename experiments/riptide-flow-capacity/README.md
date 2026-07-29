# riptide flow-capacity benchmark

Two experiments live here, both on the KVM lab (riptide-benchmark-01 192.168.11.33,
ch-benchmark-01 192.168.11.34, nl6 off-box on monkey-head → absolute claims valid).

## 1. UDP socket buffer (riptide 0.6.6, 2026-07-28)

Artifacts: `report.html`, `runs.json`, `nl6-reports/`.

Findings: first drop at 22–30 synchronized exporters on the stock 208KB socket
buffer (kernel-bound, not riptide); with rmem_max=128MB the socket absorbs 1000
exporters / 256k records at zero loss; sustained ingestion is a flat ~3,600 flows/s
(insert-cadence-bound, CPU headroom on both VMs) with ~116ms median persist latency.

## 2. Client-side insert batching — riptide#382 / PR#387 (2026-07-28)

Artifacts: `plan-batching.md` (Stage-0 plan), `batching-report.html`,
`batching-runs.json`, `batching-runs/` + `batching-confirm/` (per-step ledgers and
ClickHouse deltas), `ladder.sh` + `run_scenario.sh` + `build-batching-report.py`.

One build (0.6.7-SNAPSHOT @ 82b7a04), one variable: `riptide.clickhouse.batch.enabled`.
Batch-off derives `async-inserts=true`, reproducing the pre-change per-record path, so
the delta is attributable to batching alone rather than to a version bump. Each variant
wrote to its own database; the 0.6.6 corpus in `riptide` was left untouched. The rDNS
enricher was disabled in both variants (identical control) — synthetic flows carry random
10/8 addresses and would otherwise have pointed a 12k flows/s ladder at the homelab resolver.

| Metric (10-min confirmed window) | batch-off | batch-on | delta |
|---|---|---|---|
| Sustained persisted rate | 3,669 rows/s | **11,840 rows/s** | **3.2×** |
| Loss at that offered rate | 7.04% | **0%** | — |
| ClickHouse INSERTs | 3,668/s | **1.19/s** | 3,082× fewer |
| Rows per INSERT | 1 | **9,922** | — |
| NewPart cadence (flows) | 8.16/s | **1.19/s** | 6.9× fewer |
| Avg rows per part (all runs) | 444 | 9,817 | 22× |

Saturation: batch-off plateaus at ~3,990 rows/s regardless of offered load (49% loss at
7,467 flows/s offered); batch-on stayed clean to 12,000 flows/s and plateaued ~13,327 rows/s
(15% loss at 15,733 offered). The 8.16 parts/s and ~3,600 rows/s of the batch-off variant
independently reproduce both the 0.6.6 baseline above and the evidence quoted in issue #382.

Caveats worth reading before quoting these numbers:

- The 4-minute ladder step at 3,973 flows/s showed **zero** loss for batch-off, but the
  10-minute confirm at 3,947 flows/s lost 7% — the short window hid mid-run degradation.
  Only the 10-minute figures are headlined.
- riptide exports no metrics (no reporter, no endpoint), so queue depth, batch-size and the
  drop/fail counters were not readable during the run; buffer behaviour is inferred from
  `system.query_log` / `system.part_log` and riptide's logs.
- Under batch-off, `async_insert` acknowledges before the write, so `written_rows` in
  `query_log` is 0 for those INSERTs; rows-per-insert is 1 by construction.
- nl6's scenario `rate` sets export *cadence*, not flow volume — each simulated exporter
  emits ~7.9 flows/s from its `ConcurrentFlows` profile, so the ladder steps exporter count.
- The generator ran on a shared nl6 daemon (v0.20.1) that also hosts an unrelated idle
  5-device fleet; those devices were left untouched and the 2,000 created here were deleted
  afterwards.
