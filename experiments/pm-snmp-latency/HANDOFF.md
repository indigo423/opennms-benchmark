---
title: SNMP latency and fleet-scaling campaign — handoff
description: Findings, open threads and traps as of 2026-09-02 16:10 CEST — edge search complete, lab torn down
date: 2026-09-02
---

# Handoff — SNMP latency injection and fleet-scaling campaign

Written to survive a context clear. Read "Right now" and "Lab drift" before touching anything.

## Right now

**Nothing is running. The edge search completed at 15:46 CEST on 2026-09-02 and found the edge.**

**13,000 devices complete a cycle under 8–12 ms/PDU. 14,000 do not.**

| fleet | drains | zero-frac | q_max | ratio med | threads | CPU | GC s/s | verdict |
|---|---|---|---|---|---|---|---|---|
| 10,000 | yes | 0.323 | 540 | 0.9999 | 77.8/100 | 56.9% | 0.027 | PASS |
| 11,000 | yes | 0.387 | 352 | 0.9999 | 80.4/100 | 63.7% | 0.031 | PASS |
| 12,000 | yes | 0.290 | 51 | 0.9975 | 83.8/100 | 67.6% | 0.035 | PASS |
| 13,000 | yes | 0.129 | 1502 | 0.9968 | 98.4/100 | 77.4% | 0.071 | PASS |
| **14,000** | **no** | **0.000** | **4576** | **0.9847** | **100.0/100** | 85.2% | 0.116 | **FAIL** |

**Pass criterion:** pending queue returns to zero within the interval **AND** median completion
ratio ≥ 0.99. Both required. At 14,000 both fail together.

**The prediction on record was 12,000–13,000 and thread-bound. Both held.** The edge landed at the
top of the predicted range, and the mechanism is unambiguous: at the failure the pool mean is
**100.0 of 100** — a mean, not a peak, so it is pinned for the entire window — while CPU is only
85.2%. Threads ran out before cores, exactly as Little's Law predicted from the 10,000 rung.

Worth noting for the next campaign: **GC roughly doubled at each of the last two steps**
(0.035 → 0.071 → 0.116 s/s) while heap barely moved. It was the one metric already bending before
the queue gave way, and it is the earliest warning in the table.

**Results are preserved** in `results/` — see `results/README.md`. The scratchpad they came from is
volatile and should not be relied on.

**Teardown is done** (2026-09-02 16:00 CEST): the `netem` qdisc is removed and `enp6s19` is back to
`fq_codel`, verified; the instrumentation `tail -F` on Core is stopped, verified. `capture.log`
(1.18 GiB) was deliberately left in place as raw evidence — deleting it is a separate decision.

**The fleet is still at 14,000, in the state that failed.** Shrinking costs a full delete-and-rebuild
(~35 min, see Traps), so it was left alone.

## Lab drift — the running lab no longer matches committed config

| what | committed | running | why |
|---|---|---|---|
| `netsim-benchmark-01` | 2 vCPU / 4 GiB | **4 vCPU / 8 GiB** | was the constraint at 10k devices: 71% CPU, **98% memory**, about to OOM |
| Core `JAVA_HEAP_SIZE` | 8192 | **10240** | 8 GiB was hit at ~10k nodes. 12288 does **not** fit in the 16 GiB VM (see below) |
| nl6 version | pinned v0.22.1 in the report | **v0.28.0** | upgraded before this campaign |
| fleet | 3,801 | **14,000** (final, the rung that failed) | left as-is; shrinking costs a full rebuild |
| `enp6s19` on netsim | `fq_codel` | `fq_codel` — **restored 2026-09-02 16:00** | teardown done, verified |

**The netsim resize, the heap change and the nl6 bump are still not in git.** If the campaign is
adopted, `deployments/kfk-exclusive/topology.yml` needs all three. Until then, anyone reproducing
these numbers from the committed topology will fall short of them without an obvious reason why.

**Teardown is complete.** The qdisc is back to `fq_codel` and the instrumentation `tail -F` on Core
is stopped, both verified. Nothing else needs undoing. `capture.log` was left in place on purpose.

## What is established

### Latency has almost no effect until it exhausts the thread pool
Ten-rung sweep at 3,801 devices, 0→60 ms/PDU. **Delivered throughput flat within 1% from 0 to
50 ms** while walk time grew 987 → 7,611 ms. Saturation observed at 60 ms: queue stopped
draining, walk 9,072 ms (115% of budget), throughput fell to 18,901/s from 20,990.

- Measured **191.4 PDUs per device collection** (sim-bridge packet rate ÷ collection rate; both
  directions reconcile exactly at 2,427.5 pkt/s).
- Effective serial depth converges to **135 of 191 PDUs (~70%)**, so per-device walk is
  `987 + 134.8 · d` ms for injected delay *d*.
- Real agents are 1–10 ms per the research, so the cleanroom baseline survives a **5–50×** margin.
  **This contradicts the report's caveat that a real estate would need "materially more".**

### Threads and vCPU are independent axes
Same fleet, same work: threads **11 → 98 (8.7×)** while CPU went **1.74 → 1.55 cores (unchanged)**.
A Collectd thread parked on an SNMP round trip costs ~16 mc; one doing work costs ~156 mc.

- **Threads** = λ × W (Little's Law), driven by *latency*.
- **CPU** = work rate × cost per sample, driven by *sample volume*.
- Floor: λW or the cycle cannot complete. Ceiling: contention — 100 threads on 8 vCPU
  (12.5/vCPU) is fine; the campaign notes record **200 on 4 vCPU (50/vCPU)** spiking load to 124
  and starving the RPC consumer. **The boundary between 12.5 and 50 per vCPU has never been mapped.**

### Cleanroom capacity of 8 vCPU / 16 GiB (zero latency)
| services | CPU | mc/device | old-gen GC | verdict |
|---|---|---|---|---|
| 10,055 | 4.46 c (56%) | 0.443 | 0.00/min | comfortable |
| 12,055 | 6.07 c (76%) | 0.504 | 0.62/min | working hard |
| 13,555 | 6.83 c (85%) | 0.504 | 1.47/min | **at the edge** |

CPU scaling is **linear** (0.4375 mc/device, +0.085 core intercept) except for a **step between
10k and 12k** that coincides exactly with old-generation GC first appearing. A 6-hour soak at
10,051 showed zero drift and zero full collections.

### The four collectable services that are not the fleet
`opennms/1/127.0.0.1/OpenNMS-DB`, `-DB-Stats`, `-JVM`, and `opennms/2/127.0.0.1/JMX-Minion`.
Node 1 is localhost, node 2 the Minion, in requisitions `selfmonitor` and `Minions`. This is the
constant `+4` between device count and collectable services. They cost ~40 ms/cycle against
~973 ms for the fleet.

### Per-device SNMP arithmetic, corrected
Two `systemDef`s match sysObjectID `.1.3.6.1.4.1.9.1.1404`: *Cisco Routers* (`.1.3.6.1.4.1.9.1.`)
and *Enterprise* (`.1.3.6.1.4.1.`), enabling 18 groups. Only **3** target a per-node resource, and
only `mib2-tcp` returns. **144 interfaces × 12 attributes + 10 = 1,738 samples/device/cycle**,
reproducing the measured figure exactly. `mib2-interfaces` is **not** used (it is in
`Legacy_MIB2-Interfaces`, absent from the `default` collection); the data comes from the HC groups.

## Open threads

1. **Thread-per-vCPU optimum.** Sweep 50/75/100/150/200/300 at fixed fleet. Little floor at the
   current fleet is ~34 threads. `send-event.pl` exists on Core — check whether
   `reloadDaemonConfig` for Collectd avoids a full restart per rung (halves the cost).
2. **JVM tuning at 13.5k nodes.** Ranked candidates: `-XX:+UseStringDeduplication` (huge OID/label
   repetition), `-XX:InitiatingHeapOccupancyPercent=35` (head off the full GCs), `-Xss512k`
   (**1,043 threads × 1 MiB default stacks**; java RSS is 11.93 GiB against a 10 GiB heap —
   ~2 GiB is off-heap and nobody has looked at it), `-XX:ConcGCThreads` (currently 2 on 8 vCPU).
3. **Heavy-tailed vs uniform latency at equal mean.** `netem delay 10ms 8ms distribution pareto`
   vs the current uniform. Little's Law says occupancy should match; if it does not, that is a
   finding. The research says real agents are heavy-tailed and nobody has published the shape.
4. **P3 of the RUNBOOK** (per-device heterogeneous latency classes) — never run.
5. **The report's own inconsistency:** intro claims "the Minion at 0.11 load per core" but the
   57-hour window measured 0.46. Untouched.
6. **JMX sample split.** Node arithmetic is settled; the *sample* share of the 4 JMX services
   still needs the run's sidecar (`/tmp/tg-*.json` on mon).

## Traps — all of these cost time today

- **`DELETE /api/v1/devices` on nl6 deletes the ENTIRE fleet.** There is no selective delete.
  I destroyed 13,551 devices probing this endpoint. It returns `000` on an 8s curl because it
  takes minutes, not because it failed. **Shrinking = delete-all + rebuild + re-provision (~35 min),
  so always search UPWARD.**
- **nl6 holds the fleet in memory only** (`docker inspect` shows no mounts). Any restart loses
  everything. Capture `/api/v1/devices` and rebuild from a batch manifest. OpenNMS needs no
  re-provision if the same addresses return.
- **Everything here is bursty; never trust a spot sample.** Cost me three false knees:
  heap % at 8 GiB, heap % at 10 GiB, and `min(completion ratio)`. Also produced a bogus
  "superlinear, ceiling 10,750" claim from one instantaneous CPU reading that landed on a rescan peak
  — the 15-minute mean said linear and ~14,400.
- **`taskcompletionratio` is a sawtooth** resetting to ~0 each cycle. Use the **median**.
  Measured at 12,055: min 0.0036, median 0.9972.
- **Heap % is not GC pressure.** G1 fills whatever ceiling it is given. 9.47/10 GiB with **zero**
  old-gen collections and 2.8% GC time is comfortable. Judge on GC seconds/second and old-gen
  collection rate.
- **Core host runs UTC**, the rest of this campaign is quoted CEST.
- **`WebFetch` silently drops `<pre>` blocks.** Cost a missed Juniper histogram; fetch raw HTML.
- **cisco.com returns 403 to all automated fetching.** Use `web.archive.org`.
- **Proxmox returns `cores` as int but `memory` as a string.** A naive `==` comparison aborted a
  resize script mid-flight with the VM stopped.
- **12288 MiB heap does not fit in the 16 GiB Core VM.** Non-JVM usage is 3.63 GiB, JVM non-heap
  0.40, so the ceiling is ~11.59 GiB with **zero swap**. 10240 leaves 1.59 GiB headroom.
- **Windows must be integer multiples of the 300 s interval**, and rate computed against
  wall-clock, never the message-timestamp span. Two rungs came in at 3.6 and 3.2 cycles and their
  throughput figures are unusable (their `collectData` figures are fine — per-collection timings
  are immune to window phase).
- **A restart makes the next hour optimistic.** A window 3–49 min after restart gave W=1.12 s;
  the same system settled gave 1.92 s. Wait ~60 min.
- **Rolling rescans are continuous above ~7,000 nodes** (1-day scan-interval spread across the
  fleet). A "scan == 0" settle gate will never pass. Require imports finished; treat scan as a
  covariate.

## Where things are

| what | where |
|---|---|
| Runbook (latency sweep) | `experiments/pm-snmp-latency/RUNBOOK.md` |
| Research artifact | `_bmad-output/planning-artifacts/research/technical-snmp-agent-response-latency-modelling-2026-09-01/research.md` |
| Published report | https://claude.ai/code/artifact/79e147e0-8f42-4632-8961-8f0abbafa07e |
| Benchmark report source | `experiments/pm-snmp-target/results/report-fragment.html` → `report.html` via `build-report.py` |
| Rung data, all three sweeps | `experiments/pm-snmp-latency/results/` — see its `README.md`. Recovered from the scratchpad; this is the only copy |
| Campaign drivers | `experiments/pm-snmp-latency/results/bin/` — preserved verbatim as provenance, excluded from ruff in `ruff.toml` |
| Instrumentation capture | Core `/var/tmp/pm-snmp-latency/capture.log` — 1.18 GB, **capture stopped 2026-09-02 16:00**; file left in place as raw evidence |
| Duration parser | Core `/var/tmp/pm-snmp-latency/durations.py` — `collectData` begin→end per device |
| Fleet manifest | mon `/tmp/nl6-manifest.json` — **stale above 10,051**; re-capture after every growth |

## Access

- Only `mon-benchmark-01` (192.168.10.40) is reachable directly; everything else via `-J`.
- Proxmox: `https://lechuck.labmonkeys.tech:8006`, token in `PROXMOX_TOKEN_ID` / `PROXMOX_API_TOKEN`.
- Prometheus: `https://192.168.10.40/prometheus`, Grafana on the same host. `-k` required.
- nl6 API: `http://192.0.2.216:8080` (from mon). Replies wrap `{"success": …}`; **a 200 is not success.**
