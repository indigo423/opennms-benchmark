---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · sizing rule · six days, eight knees"
title: "Two constants size a collector:<br>seconds per collection and core-seconds per collection"
lede: "Six knee searches, a latency sweep and a cleanroom edge search on the same lab reduce to a rule with two measured constants. A collection of this device takes P round trips at the agent's response time R plus about 0.75 s of the Core's own work, and it costs the Core about 0.115 core-seconds whatever R is. Threads follow from the first constant by Little's law, cores from the second, and the heap from the fleet and the pool. The rule reproduces every knee the campaign found to within one rung of 500 devices, and it names which term bound at each: the pool four times, the processor once, the heap once."
verdict:
  - { k: "Thread time per collection", v: "P × R + 0.75 s", n: "61 PDUs at 76 ms: 5.4 s; 149 at 76 ms: 12 s; 149 at 10 ms: 2.2 s", hero: true }
  - { k: "CPU per collection", v: "0.115 core-s", n: "on a heap with headroom, at 0.1 ms and at 76 ms alike; 0.13 to 0.16 when GC bites" }
  - { k: "Pool limit", v: "threads × 300 / T", n: "300 threads at 5.4 s: 16,800 devices; measured 16,750 pass, 17,250 fail" }
  - { k: "Processor limit", v: "cores × 0.96 × 300 / c", n: "8 cores: 20,000 devices; measured 19,750 pass, 20,250 fail" }
  - { k: "Heap", v: "2 GiB + 0.7 MiB × devices + 2 MiB × threads", n: "live set, estimated; size the heap at 1.4 times it" }
caveats: |
  Every constant is a property of this fleet: simulated Cisco CRS-X routers with 144 interfaces, one data collection package, 1,738 samples per collection, SNMP results carried as XML through the Kafka RPC. Another device or package changes P, the 0.75 s and the 0.115 core-seconds together; the form of the rule does not change, the constants must be read again the same way.
  The latency is injected by netem as a fixed or uniform delay on every response. A real fleet's R is the mean round trip a collection experiences, and its slow agents time out, which the simulator never does.
  No new measurement was made for this report. Every table is computed by `bin/model.py` from the searches' own records, and every figure is a search's own Prometheus series re-expressed in the rule's units. Each knee rests on one 15-minute window per rung; the agreement across eight of them is the evidence.
method: |
  The campaign ran from 1 to 6 September 2026 on `deployments/kfk-exclusive`: one Core (8 vCPU, 16 GiB with a 10 GiB heap until the morning of the 5th, 32 GiB with a 20 GiB heap after), one Minion (4 vCPU), Kafka, PostgreSQL and nl6 simulating the fleet. The latency sweep held 3,803 devices and stepped netem from 0 to 60 ms per response with 100 threads. The edge search held 8 to 12 ms and grew the fleet from 10,000 to 14,000. The cleanroom ran 14,004 devices at 0.1 ms for seven hours. The six knee searches held `netem delay 75ms 25ms`, a median 75.6 ms per response on the wire, and grew the fleet in rungs of 500 or 1,000 with 100, 200, 300 and 400 threads at `max-repetitions` 2 and 5.

  Thread time per collection T is Little's law read backwards: busy threads divided by collections per second. CPU per collection c is CPU busy times cores divided by collections per second. P is the number of sequential GETBULK requests in a collection, 149 at `max-repetitions=2` and 61 at 5, read from the Minion's pcap. R is the median response time from the same pcap. The Core-side constant 0.75 s is the intercept of collection time against delay in the latency sweep plus the persist step, and it is checked against every knee. The pool limit is threads × 300 / T; the processor limit is cores × U × 300 / c with U the utilisation at which this Core collapses, 0.96; the heap limit is where the live set meets the heap with less than 40% headroom. A pass is the knee search's own rule: the queue returns to zero inside a 15-minute window and the completed count reaches 97% of the services due.
---

## The rule {#the-rule}

**A deployment is sized by two per-collection constants and the interval.** For D devices on a 300 s interval, P sequential PDUs per collection at a mean agent response time R, the collection rate is D / 300 a second and:

| Term | Rule | This fleet |
|---|---|---:|
| Thread time per collection | T = P × R + c0 | [c0 = 0.75 s]{.fx title="intercept of the latency sweep's collection time plus persist; 0.5 s at low CPU, 1 s above 90%"} |
| Threads needed | D / 300 × T × 1.2 | [the 1.2 absorbs the scheduling wave]{.fx title="at 20,250 devices 351 threads were needed on average and 400 kept the queue draining"} |
| Fleet the pool carries | threads × 300 / T | |
| CPU per collection | c | [0.115 core-s]{.fx title="32 GiB Core, every rung 14,250 to 20,250; 0.13 to 0.16 on the 16 GiB Core with GC in it"} |
| Cores needed | D / 300 × c / U | [U = 0.85 to size, 0.96 the cliff]{.fx title="the Core collapses at 96%: an observer, an import or a wave tips it and the backlog never drains"} |
| Fleet the cores carry | cores × U × 300 / c | |
| Live heap, estimated | 2 GiB + 0.7 MiB × D + 2 MiB × threads | [fit to four points]{.fx title="16.3 GiB at 20,250 / 400; 12.4 at 17,250 / 300; 8.9 pinned of 10 at 13,500 / 100; 8.4 at 10,000 / 100"} |
| Heap and RAM | heap = 1.4 × live; VM RAM = 1.5 × heap | [20 GiB heap on 32 GiB]{.fx title="the 32 GiB Core used 22 to 23 GiB with a 20 GiB heap; a 12 GiB heap did not fit in 16 GiB"} |

The knee is the smallest of the three fleets. Latency enters only through T, so it sets the thread count and nothing else; the processor's term does not contain R at all; the heap's term contains the fleet and the threads and therefore, through T, the latency once removed.

## Latency and threads {#latency-and-threads}

**Thread time is a straight line in the agent's response time, with a slope of P and an intercept of the Core's own second.** The latency sweep held 3,803 devices and 100 threads and stepped netem from 0 to 60 ms:

| netem delay | Thread-seconds per collection | Collection time, median | Persist, median | Pool busy, mean |
|---:|---:|---:|---:|---:|
| none | 0.88 s | n/a | n/a | 11.2 |
| 0 ms (netem on) | 1.66 s | n/a | n/a | 21.1 |
| 2ms | 0.97 s | 1.04 s | 366 ms | 12.3 |
| 5ms | 1.34 s | 1.26 s | 313 ms | 17.0 |
| 10ms | 1.48 s | 1.82 s | 207 ms | 18.8 |
| 20ms | 3.45 s | 3.21 s | 150 ms | 43.8 |
| 30ms | 5.28 s | 4.65 s | 126 ms | 66.9 |
| 40ms | 7.11 s | 6.12 s | 125 ms | 90.2 |
| 50ms | 7.86 s | 7.60 s | 122 ms | 99.6 |
| 60ms | 7.88 s | 9.08 s | 114 ms | 100.0 |

Slope of the median collection time against the delay, 2 to 50 ms: 136 ms per ms, i.e. 136 sequential PDUs per collection; intercept 593 ms. Estimate.

Table: `latency-sweep.jsonl`, written on 2026-09-01 by the campaign's runbook; thread-seconds are busy threads divided by collections per second.

{{figure latency-staircase}}

Between 2 and 50 ms the median collection time rises 136 ms for every millisecond of delay, estimated by least squares, against 149 PDUs counted on the wire at 76 ms, and its intercept is 0.59 s. The persist step adds 0.1 to 0.4 s, which is where the rule's 0.75 s comes from. At 50 ms the line meets the pool's ceiling, 100 threads × 300 s / 3,803 services = 7.9 s, and at 60 ms the queue no longer returns to zero: the first knee of the campaign, found by raising latency instead of the fleet.

{{figure mr2-threads}}

The knee searches read the same line at a fixed 76 ms and a growing fleet. At `max-repetitions=2` a collection is 149 PDUs and T is 11 to 12 s at every pool size; the ceiling, pool × 300 / services, falls with the fleet and meets it at 2,500 to 3,000 devices with 100 threads and at 5,000 to 5,250 with 200. One attribute, `max-repetitions=5`, cuts P to 61 and T to 5.4 s, and the same 200 threads carry 11,750. That is the largest lever in the rule, and it is configuration.

{{figure edge-threads}}

At 8 to 12 ms the edge search's T is 2.1 to 2.3 s, 149 × 0.010 + 0.75 = 2.24 by the rule, and 100 threads meet it between 13,000 and 14,000 devices; the rule says 13,400.

| Fleet | Pool busy, mean | T measured | Core cores busy | c, core-s per collection | Heap used | GC share | Verdict |
|---:|---:|---:|---:|---:|---:|---:|---|
| 10,000 | 77.8 | 2.33 s | 4.55 | 0.136 | 8.3 GiB | 2.7% | pass |
| 11,000 | 80.4 | 2.19 s | 5.10 | 0.139 | 8.6 GiB | 3.1% | pass |
| 12,000 | 83.8 | 2.09 s | 5.41 | 0.135 | 8.8 GiB | 3.5% | pass |
| 13,000 | 98.4 | 2.27 s | 6.19 | 0.143 | 8.9 GiB | 7.1% | pass |
| 14,000 | 100.0 | 2.14 s | 6.81 | 0.146 | 9.2 GiB | 11.6% | fail |

Rule at 10 ms: T = 149 x 0.010 + 0.75 = 2.24 s, pool limit 100 x 300 / 2.24 = 13,393 devices; measured 13,000 pass, 14,000 fail.

Table: `edge-search.jsonl`, 2026-09-02; c includes the 16 GiB Core's garbage collection.

## CPU {#cpu}

**A collection costs the Core 0.115 core-seconds on a heap with headroom, and the agent's latency does not change it.** The cost is decoding the Minion's XML response, storing 144 interfaces of attributes with a linear OID lookup, one database transaction per resource in the Kafka producer, and the logging around it: the Core's work is the same whether the Minion took 0.5 s or 12 s to gather the answer.

{{figure cleanroom-cpu}}

{{figure mr5-cpu}}

In the cleanroom at 0.1 ms per PDU the 16 GiB Core spent about 0.15 core-seconds per collection, garbage collection included; the edge search at 10 ms read 0.135 to 0.146; the 32 GiB Core at 76 ms reads 0.114 to 0.115 on every rung from 14,250 to 20,250. The difference between the two Cores is the heap's term leaking into the processor's: on 10 GiB the old generation was collected up to twice a minute, and that time is CPU too.

{{figure mr5-fleet}}

{{figure mr5-corecpu}}

Eight cores at 0.115 core-seconds decode 69.6 collections a second at 100%, 20,900 devices; the Core collapses at 96%, which is 20,000, and the 400-thread search found 19,750 passing and 20,250 failing. The cliff is sharp because a run queue seven deep delays the single thread that receives every RPC response; the pool then fills with waiting threads and the queue grows with no way back but a restart.

## RAM {#ram}

**The heap holds the fleet's state plus one decoded response per busy thread, and it needs room for G1 to mark.**

| Core | Fleet | Threads | Heap used, window mean | Old-generation GC | Source |
|---|---:|---:|---:|---|---|
| 16 GiB / 10 GiB | 10,000 | 100 | 8.4 GiB | 0.00 per min, 2.8% of wall | fleet-sweep (cleanroom) |
| 16 GiB / 10 GiB | 12,000 | 100 | 8.1 GiB | 0.62 per min, 5.9% of wall | fleet-sweep (cleanroom) |
| 16 GiB / 10 GiB | 13,500 | 100 | 8.9 GiB | 1.47 per min, 14.6% of wall | fleet-sweep (cleanroom) |
| 16 GiB / 10 GiB | 14,250 | 300 | 9.1 GiB | 61 in 35 min, 17.4% of wall | pm-snmp-agent-latency-mr5-live |
| 32 GiB / 20 GiB | 17,250 | 300 | 15.5 GiB (12.4 after collection) | 0 | pm-snmp-agent-latency-32g-live |
| 32 GiB / 20 GiB | 20,250 | 400 | 16.8 GiB (16.3 after collection) | 5 full in 25 min, 7.9% of wall | pm-snmp-agent-latency-32g-pool400-live |

Table: the campaign's heap readings; `fleet-sweep.jsonl` and the three sealed captures' GC logs.

{{figure mr5-heap}}

{{figure mr5-oldgen}}

The 10 GiB heap was pinned at 8 to 10 GiB from 12,000 devices with 100 threads and collected its old generation 1.5 times a minute at 13,500; with 300 threads at 14,250 it collected 61 times in 35 minutes, 17% of wall time, and that was the 16 GiB Core's knee, with the pool at 17,000 and the processor at 15,000 by the rule. The 20 GiB heap grew from 12.4 GiB after collection at 17,250 with 300 threads to 16.3 at 20,250 with 400, and at that last rung, with 3.7 GiB of headroom, G1 fell back to full collections five times in 25 minutes. A fit through those points, estimated: live set 2 GiB + 0.7 MiB per device + 2 MiB per busy thread; heap at 1.4 times it; VM memory at 1.5 times the heap, since the 32 GiB Core used 22 to 23 GiB with a 20 GiB heap. By that rule a 20 GiB heap serves 17,000 devices with 300 threads comfortably and 20,000 with 400 at the edge, which is what was measured.

## The test {#the-test}

**Eight knees, one rule, each within a rung, and the binding term named right each time.**

| Search | Core | Last pass / first fail | T measured at last pass | T = P x R + c0 | Pool limit, threads x 300 / T | c measured, core-s | CPU limit at 96% of 8 cores | Binds |
|---|---|---|---:|---:|---:|---:|---:|---|
| mr2, pool 100 | 16 GiB / 10 GiB heap | 2,500 / 3,000 | 11.4 s | 12.0 s | 2,497 | 0.160 | 14,432 | pool |
| mr2, pool 200 | 16 GiB / 10 GiB heap | 5,000 / 5,250 | 11.1 s | 12.0 s | 4,994 | 0.133 | 17,367 | pool |
| mr5, pool 200 | 16 GiB / 10 GiB heap | 11,750 / 12,250 | 5.0 s | 5.4 s | 11,191 | 0.151 | 15,279 | pool |
| mr5, pool 300 | 16 GiB / 10 GiB heap | 13,750 / 14,250 | 6.3 s | 5.4 s | 16,786 | 0.149 | 15,443 | heap (old-gen GC) |
| mr5, pool 300 | 32 GiB / 20 GiB heap | 16,750 / 17,250 | 5.4 s | 5.4 s | 16,786 | 0.114 | 20,178 | pool |
| mr5, pool 400 | 32 GiB / 20 GiB heap | 19,750 / 20,250 | 5.6 s | 5.4 s | 22,381 | 0.115 | 20,045 | cores |

Table: `bin/model.py` over the six `knee-search*.jsonl` records; T measured is busy threads over collections per second at the last passing rung, c measured is CPU busy times 8 over the same rate. Binds is the smallest of pool, cores and heap.

{{figure mr5-threads}}

The rule's pool limit lands within 3% of the measured knee at 100, 200 and 300 threads and at both attribute settings; at 200 threads and `max-repetitions=5` it is 5% low, because T at that rung was 5.0 s against the rule's 5.4. The 16 GiB Core with 300 threads is the one knee neither the pool nor the processor explains, and the heap table does. With 400 threads the pool would carry 22,400 and the processor stops at 20,000; measured 19,750 and 20,250. The edge search at 10 ms and the latency sweep at 3,803 devices are the same rule at other points of R, and it holds there too.

## Sizing with it {#sizing}

**Read P and R first, then pull the levers in this order: the attribute, the threads, the cores, the heap.**

A worked example, this device at 100 ms per PDU, 10,000 devices, `max-repetitions=5`: 33.3 collections a second; T = 61 × 0.100 + 0.75 = 6.85 s; threads = 33.3 × 6.85 × 1.2 = 274, so `threads="300"`; cores = 33.3 × 0.115 / 0.85 = 4.5, so 8 vCPU at 48%; live heap 2 + 6.8 + 0.6 = 9.4 GiB, estimated, so a 13 GiB heap on a 20 GiB VM. At the default `max-repetitions=2` the same fleet needs T = 15.7 s and 627 threads: the attribute is worth 350 threads before anything else is touched.

A second, 30,000 devices at 20 ms: 100 collections a second; T = 61 × 0.020 + 0.75 = 1.97 s; threads = 236, so 250; cores = 100 × 0.115 / 0.85 = 13.5, so 16 vCPU; live heap 2 + 20.5 + 0.5 = 23 GiB, estimated, so a 32 GiB heap on a 48 GiB VM. The Minion at 0.03 core-seconds per collection needs 3 cores at that rate, so two Minions or eight vCPU; the Kafka segment carries about 23 Mbit/s per 1,000 devices uncompressed, 700 Mbit/s here, and lz4 on the Minions cuts it eight times for 5% more on the Core.

- **The attribute first.** P is the only constant a configuration file changes by a factor of two. `max-repetitions` sized to the device's tables cuts T and therefore threads, in-flight state and heap, and costs the Core nothing.
- **Then the threads.** D / 300 × T × 1.2, and no more: threads above what keeps the cores busy add in-flight heap and run-queue depth, not throughput. On eight cores at this c, 362 threads saturate the processor; 400 is the right number at 76 ms, 250 at 20 ms.
- **Then the cores.** c is the constant only code changes: the XML in the RPC, the per-resource database lookup, the OID lookup, the instrumentation log. Until they change, every 1,000 devices of this type cost 0.38 cores at 300 s.
- **Then the heap.** 0.7 MiB per device and 2 MiB per thread of live set, times 1.4, on a VM of 1.5 times that. The 16 GiB class stops near 13,000 devices whatever the pool; the 32 GiB class near 20,000; 40,000 devices on 16 vCPU need the 64 GiB class.
- **The interval.** Every term has 300 s in it. A 600 s interval halves the rate, the threads, the cores and the heap's per-thread term at once; it is the one lever that moves all three constants' consequences together.
