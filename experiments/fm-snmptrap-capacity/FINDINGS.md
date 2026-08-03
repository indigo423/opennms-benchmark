<!--
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0
-->
# SNMP trap capacity on kafka-exclusive — investigation record

**Question.** What is the maximum number of SNMP traps per second the `kafka-exclusive` deployment accepts on `kvm` without data loss?

**Status: answered.** Issue [#216](https://github.com/indigo423/opennms-benchmark/issues/216), branch `feat/216-snmptrap-capacity`. Phase A (60s windows) complete and calibrated 2026-08-03.

---

## The short answer

### R_max = 5,000 traps/s fleet-wide

100 provisioned sources at 50 traps/s each, sustained with no backlog. First failure at 6,000/s.

```
rate/dev  offer/s  sent     events   achiev/s lag    ratio  drops  verdict
ref       2000     119900   119721   1883     1s     0.999  0      PASS
20        2000     119900   119729   1884     1s     0.999  0      PASS
40        4000     239900   239714   3762     3s     0.999  0      PASS
50        5000     299900   299707   4701     5s     0.999  0      PASS
60        6000     359900   359746   4781    15s     1.000  0      FAIL
80        8000     479900   479763   4191    45s     1.000  0      FAIL
100      10000     599900   599763   4472    65s     1.000  0      FAIL
```

Throughput plateaus at **~4,700–4,800/s**; beyond it the pipeline accumulates backlog rather than losing anything. Three independent measurements agree:

| source | value |
|---|---|
| sweep, rows created inside the load window | plateau ~4,700–4,800/s |
| sweep, per-minute `eventcreatetime` profile | peaks 4,553 / 4,773 / 4,694 /s |
| Core's own trapd JMX metric, via Grafana | p99 4,687/s, max 5,075/s |

**Read `lag`, not `ratio`.** `ratio` is 0.999–1.000 on *every* rung including the failures: nothing is ever lost, because Kafka absorbs the excess and the Core drains it later. Capacity shows up as the p99 wait — 1, 1, 3, 5 seconds through 5,000/s, then 15, 45, 65.

Scoped to this fleet shape (100 sources) and to Phase A's 60-second windows. Sustained 15-minute windows and repeat trials were not run.

### Minion sizing makes no measurable difference

Halving the Minion — 2 vCPU / 4 GiB against 1 vCPU / 2 GiB — changes nothing. Both variants report **R_max = 5,000/s**, both take zero UDP drops at every rung, and both plateau in the same place.

| offer/s | A: 2 vCPU / 4 GiB | B: 1 vCPU / 2 GiB | delta | lag A | lag B |
|---:|---:|---:|---:|---:|---:|
| 2,000 | 1,883 | 1,882 | −0.1% | 1s | 1s |
| 4,000 | 3,762 | 3,767 | +0.1% | 3s | 1s |
| 5,000 | 4,701 | 4,579 | −2.6% | 5s | 7s |
| 6,000 | 4,781 | 4,899 | +2.5% | 15s | 14s |
| 8,000 | 4,191 | 4,735 | **+13.0%** | 45s | 38s |
| 10,000 | 4,472 | 4,208 | −5.9% | 65s | 69s |

The deltas change sign four times across six rungs and the largest favours the *smaller* Minion, which is the signature of noise rather than an effect. Run-to-run variation on variant A alone spans a comparable range.

The reason is structural: the Minion is a pass-through on this path. It reads a UDP datagram and forwards it to Kafka; it neither decodes the trap into an event nor writes anything. That work is Core-side, which is where the ~4,700/s ceiling lives, and no amount of Minion CPU moves it.

**Practical consequence: a 1 vCPU / 2 GiB Minion carries this trap workload as well as a 2 vCPU / 4 GiB one.** The receive-buffer setting matters far more than the vCPU count — untuned it cost 924,298 datagrams at 10,000/s, while halving the CPU cost nothing measurable.

Comparability: both runs used the same harness, the same ladder, the same 100-source fleet, the same pinned daemon set, and the same 8 MiB `rmem_max` (verified `rb16777216` on the trap socket in both). The deployments differ by one line — the Minion's size class — with playbook and variables symlinked so no other control could drift. Variant B was measured after a full `make deploy`, so its stack was freshly configured rather than mutated in place.

**Do not quote the larger numbers this investigation produced along the way** (10,000 / 25,000 traps/s). Each was an artefact; see below.

---

## What the deployment can absorb vs. what it can sustain

These are different questions and the distinction is the single most important result here.

```
offered 25,000/s for 60s
        │
        ▼
  Minion socket ──► Kafka sink ──► Core eventd ──► Postgres
   (16 MiB buf)     (unbounded)      ~4,600/s
        │                │               │
     0 drops        absorbs the      the real
                    excess           constraint

  completeness: 100% persisted, eventually  ← measures the buffer
  throughput:   ~4,600/s, traps waiting up to 415s  ← measures the system
```

With a Kafka sink in the path, **"nothing was eventually lost" is true at any rate the generator can reach**. It is not a capacity criterion. Capacity is the rate at which rows are actually created, and the honest test is whether the pipeline keeps up in real time.

Measured on one rung at 25,000/s offered:

| metric | value |
|---|---|
| persisted / sent | 1,497,815 / 1,498,100 = **1.000** |
| rate by `eventtime` (trap's own timestamp) | 24,783/s |
| rate by `eventcreatetime` (row creation) | **~4,600/s** |
| `eventcreatetime - eventtime` p50 / p99 / max | 127 s / 403 s / 416 s |

---

## Real defects found and fixed

### 1. The trap 50% was alarmd deleting rows — resolves [#212](https://github.com/indigo423/opennms-benchmark/issues/212)

`SNMP_Authen_Failure` ships with:

```xml
<alarm-data reduction-key="%uei%:%dpname%:%nodeid%" alarm-type="3" auto-clean="true"/>
```

Every authenticationFailure trap from a node reduces onto **one alarm per node**, and alarmd's auto-clean deletes the older events backing it. Evidence: **10 alarms carrying a summed counter of 61,672** against an events table holding a few hundred survivors.

Nothing was ever dropped. The traps were received, decoded and persisted — the rows were removed afterwards. This had been recorded as an ingress discard, which was wrong.

Worse than a fixed loss, the deletion is **asynchronous**, so the surviving count depends on when the measurement bracket closes (1,099 survivors immediately after a 2,990-trap run, settling toward ~50% later). A reference ratio cannot normalise that away, because the correction moves with load — the independent variable.

**Fix:** pin `CORE_SERVICE_ALARMD_ENABLED=false` (correctness) and `CORE_SERVICE_EVENTTRANSLATOR_ENABLED=false` (isolation). With alarmd off: **1,133,649 persisted / 1,133,400 sent = 1.0002**.

Not the Event Correlator — `kafka-exclusive` already ships that disabled, so the deletions happened with it off.

### 2. The Minion never sized its trap receive buffer

`opennms_minion_listeners` bound the listeners and left `net.core.rmem_max` at the stock 212992. That was the deployment's real trap ceiling.

| | stock (208 KB) | tuned (8 MiB → 16 MiB socket) |
|---|---|---|
| drops at 10,000/s | **924,298** | **0** |
| `Udp: InErrors` vs `RcvbufErrors` | identical — every one an overrun | — |

Two non-obvious details, both established by measurement:

- **`rmem_max` is the control, not `rmem_default`.** Trapd requests a large `SO_RCVBUF` and the kernel clamps it. Stock ships both values equal, which makes the two hypotheses indistinguishable until they differ; raising `rmem_max` to 128 MiB produced `rb268435456` (2× the ceiling), not 2× the default.
- **Size in bytes/sec, not datagrams.** The kernel charges `skb->truesize`. A trap here is **70 bytes** of UDP payload (tcpdump, 400 packets) but roughly **768 bytes** of buffer — sizing from the payload overestimates capacity more than tenfold.

Sized at 8 MiB (16 MiB socket ≈ 1 s at 20,000 traps/s): large enough to absorb GC pauses and scheduling jitter, deliberately too small to mask a sustained deficit. Not the 128 MiB used by the riptide flow work, which is ~17 s of masking and unsafe on a 2 GiB Minion.

### 3. `tasks_from` silently ignored — [#217](https://github.com/indigo423/opennms-benchmark/issues/217)

`fm-snmptrap` and `fm-syslog` both opened with:

```yaml
roles:
  - role: nl6_fleet
    tasks_from: reset      # silently becomes a role *variable*
  - nl6_fleet
```

`tasks_from` is a parameter of `include_role`/`import_role`, not a key the play-level `roles:` list understands. `main.yml` ran twice and `reset.yml` never ran, so **those experiments never reset the fleet** despite documenting that they do. Fixed in both.

---

## Measurement defects in the harness (all mine, all fixed)

Listed because each produced a plausible, wrong number, and the failure modes generalise.

| # | Defect | Symptom |
|---|---|---|
| 1 | `failed_when: rc != 0` on the generator | nl6 exits 1 on ~0.3% jitter, so every rung failed |
| 2 | `sudo -u postgres command psql` | `command` is a shell builtin; sudo cannot exec it |
| 3 | `ansible.builtin.pause` without a TTY | a 300 s settle took 20+ min; a 20-min sweep ran 2 h, silently |
| 4 | Generator-limited rung aborted the sweep | discarded every clean rung *and* stranded the in-flight drain |
| 5 | Trend compared halves of the whole bracket | idle drain minutes in the tail failed any healthy rung (head 599,848/min vs tail 218/min) |
| 6 | Drain gated on Kafka **message** lag | lag ≤100 messages hid ~150k queued traps, which landed in the *next* rung — seen as `ratio 1.999` |
| 7 | R_max = "highest rung that passed" | printed "R_max = 250/device (first failure at 25/device)", a sentence that cannot be true |
| 8 | **Counted throughput on `eventtime`** | reported the *offered* rate (24,783/s) as if it were the sustained rate (~4,600/s) |
| 9 | Delivery gated on a fraction | nl6 overcounts `expected` by exactly one tick per device; the constant artefact outweighs the fractional floor at low rate × window |
| 10 | `buckets` fact orphaned by the trend removal | every rung aborted with `'buckets' is undefined` |
| 11 | Jinja precedence, again, in the header | `format` bound to the second literal; a sweep that measured all seven rungs printed no table at all |
| 12 | `achieved` rated over the bracket | the fleet's background keeps creating rows to the bracket's end, so the span measured the bracket (80s for a 60s window) — a steady ~6% shortfall that failed the reference itself |

Defects 10–12 were all found by *running* the sweep rather than reading it, which is the argument for a cheap 20-minute bracket over a 4-hour sustained run as the first thing you execute after a change.

Defect 8 is the one that mattered most, and it was caught by comparing against Core's own trapd metric rather than by any internal consistency check. **Two independent instruments beat one careful one.**

The recurring pattern: *a buffer converts a rate problem into a latency problem, and a completeness test cannot see it.* That was reasoned about carefully for the Minion's socket buffer and then missed one layer up at Kafka, where the buffer is effectively unbounded.

---

## Harness capabilities now in place

- **Three-tier verdict** localising the constraint rather than just observing it:
  - tier 1 socket — Minion UDP `InErrors + RcvbufErrors`, reported as a count
  - tier 2 handoff — sink consumer-group lag returns to baseline
  - tier 3 end-to-end — fidelity vs. a measured reference **and** sustained rate ≥ 95% of offered
- **`INVALID` verdict** for generator-limited rungs, excluded from R_max and named in the report.
- **Non-monotonic curves flagged** as a broken measurement rather than reduced to a headline.
- **Event quiescence** closes the bracket, defined against the measured background (the fleet never stops emitting).
- **Single-protocol fleets** — `nl6_fleet` omits a collector when its value is empty, so a trap benchmark is not also measuring syslog.
- **`EXTRA_VARS`** on `make experiment`, so phases run without editing a vars file.
- **`micro` size class** (1 vCPU / 2 GiB, kvm) and `kafka-exclusive-minion-micro`, differing from `kafka-exclusive` by one line, with playbook and vars **symlinked** so controls cannot drift.

## Pinned controls

Any result from this experiment must carry these, since each changes the answer:

| control | value | why |
|---|---|---|
| `net.core.rmem_max` | 8 MiB | untuned it *is* the ceiling |
| `CORE_SERVICE_ALARMD_ENABLED` | false | otherwise rows are deleted under the measurement |
| `CORE_SERVICE_EVENTTRANSLATOR_ENABLED` | false | per-event hot-path work unrelated to trap ingestion |
| fleet syslog | silent | shares the entire downstream path |
| `ftc_device_count` | 100 | rate is per device; 10 could not drive the deployment |
| nodes | provisioned (`nl6-ft`, ICMP + SNMP) | trapd resolves against a cached node |
| `events` table | truncated before each phase | insert cost is a function of table size and its 13 indexes |

## Generator envelope (nl6, one instance)

| fleet shape | rate | delivery |
|---|---|---|
| 10 devices | 10,000/s | 93.9% — generator-limited |
| 100 devices | 20,000/s | **99.99%** |
| 100 devices | 30,000/s | 98.2% — below the 99% floor |

Spreading load across more devices is what bought headroom. A healthy run is short by exactly `device_count` (one ticker interval per device), which is arithmetic in nl6's `expected`, not loss.

---

## Open items

1. **Phase B / C** — sustained 15-minute windows and repeat trials. Phase A makes no claims by design.
3. **Minion 1 vCPU vs 2 vCPU A/B.** Scaffolding ready, but **the premise is now doubtful**: the Minion dropped nothing at 25,000/s, so the constraint is Core-side (eventd/Postgres). Sizing the Minion may show no difference. Worth confirming where the ~4,600/s limit actually sits before spending a redeploy.
4. **Where is the 4,600/s spent?** Not yet attributed between eventd, the Core's Kafka consumer, and Postgres insert cost with 13 indexes. This is the natural next investigation.
5. **Run manifest and HTML report** — the `opennms-benchmark` skill's contracts 1 and 3 are not yet satisfied; no manifest is emitted.
6. **`pm-snmp` collection still never reaches the fleet** ([#211](https://github.com/indigo423/opennms-benchmark/issues/211)) — untouched by this work.

## Lab state at pause

Reset and idle: `events` truncated, 100-device trap-only fleet at `10.42.0.1` provisioned as `nl6-ft`, alarmd and the event translator pinned off, Minion `rmem_max` at 8 MiB, OpenNMS running.

Note the daemon pins live in `/opt/opennms/etc/opennms.conf`, which a redeploy rewrites; the experiment reapplies them on its next run.
