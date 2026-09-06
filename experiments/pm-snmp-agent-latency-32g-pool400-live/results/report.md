---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent response time · 400 threads on a 32 GiB Core"
title: "20,250 devices:<br>the processor's knee"
lede: "With the pool raised from 300 to 400 threads the 32 GiB Core climbs from 17,250 to 19,750 devices at 50 to 100 ms per SNMP PDU and stops at 20,250, where the eight vCPU are at 96% and the collector completes 98.8% of what the fleet asks for. Held there for five cycles and captured, the rung shows what the knee is made of: 61 GETBULK round trips of 76 ms per collection, 0.115 core-seconds of CPU to decode and store each one, 162 database transactions and 600 context switches per collection, and a heap whose live set has grown to 16 GiB of 20. This report is the arithmetic that ties the thread count, the cores and the heap together, and it predicts both knees to within one rung."
verdict:
  - { k: "Knee, 400 threads", v: "19,750 / 20,250", n: "pass / fail; 16,750 / 17,250 with 300 threads", hero: true }
  - { k: "Core CPU at the knee", v: "96.4%", n: "of 8 vCPU; 0.115 core-seconds per collection, seven rungs" }
  - { k: "Completion", v: "98.8%", n: "66.72 of 67.51 collections a second; queue climbing one task a second" }
  - { k: "GC", v: "7.9%", n: "of wall time, 5 full collections in 25 min; 4.8% and none at 19,250" }
  - { k: "Per collection", v: "61 PDUs, 4.74 s", n: "on the wire at 75.6 ms per response; 5.2 s per thread on the Core" }
caveats: |
  The window is five cycles at the failing rung, 35 minutes after the search left the fleet there; the queue had already been standing at 4,000 to 7,000 for half an hour. The Core JVM was not observed beyond a GC log, one thread dump and one 60-second read of its threads' context-switch counters, because JFR and periodic `jcmd` collapse this Core at any fleet above 17,000. The Minion carried every collector and reads about ten CPU points high.
  The knee at 20,250 is soft: the collector is 1.2% short of demand, not failing. The effective interval, once the queue saturates, is about 304 s against 300, and it stretches further with every 500 devices added.
  The Core was restarted at 10:12 UTC for the aligned-schedule test between the 19,250 and 19,750 rungs; the rungs above run with every service due in one wave per cycle. The injected latency is uniform between 50 and 100 ms on every response.
method: |
  The fleet grew from 17,250 in steps of 500 with `knee_search.py`, the same driver, latency, attribute (`max-repetitions=5`), heap (20 GiB) and pass rule as the 300-thread search, with Collectd `threads="400"` and G1. Each rung is a 15-minute window after the 500 new nodes reconciled and provisiond went idle; a rung passes if the pending queue returns to zero inside the window and the completed count reaches 97% of the services due. Rungs 17,250 to 19,750 passed; 20,250 failed and was held.

  The capture window is 12:48:30 to 13:13:30 UTC on 2026-09-06, five 300 s cycles. The Core ran procfs and sysstat collectors, the GC log that has run since the 10:12 restart, one `jcmd Thread.print` at 13:08, and one 60 s sample of every JVM thread's voluntary and involuntary context-switch counters at 13:06. The Minion ran JFR, `jcmd` snapshots, `perf`, procfs, sysstat and a pcap ring on every interface. The artifact is sealed under `experiments/pm-snmp-agent-latency-32g-pool400-live/results`.

  Rates are window integrals of the completion counter from its first and last raw sample inside the window. CPU cost per collection is CPU busy times eight cores divided by the achieved rate over the same window. Threads in flight follow Little's law: rate times time per collection. Context switches per collection are the JVM's 60 s counter deltas divided by the collections completed in that minute.
---

## The knee {#the-knee}

**19,750 passes, 20,250 fails, and what binds is the processor.** The 400-thread search climbed seven rungs. CPU rose 2.5 to 4 points per 500 devices, from 78.8% at 17,250 to 94.5% at 19,750, while the pool's mean occupancy rose from 321 to 371 of 400 and the share of the window with an empty queue fell from 88% to 23%. At 20,250 the pool is at 400 in every sample, the queue never reaches zero, and CPU is 96.5%.

| Fleet | Core CPU | Pool busy, mean | Queue at zero | Queue peak | Load, 1 min | Verdict |
|---:|---:|---:|---:|---:|---:|---|
| 17,250 | 78.8% | 321 | 88.5% | 228 | 30 | pass |
| 17,750 | 81.8% | 328 | 65.6% | 328 | 36 | pass |
| 18,250 | 84.0% | 338 | 67.2% | 447 | 39 | pass |
| 18,750 | 86.9% | 350 | 52.5% | 541 | 40 | pass |
| 19,250 | 90.0% | 368 | 37.7% | 523 | 40 | pass |
| 19,750 | 94.5% | 371 | 23.0% | 1,067 | 56 | pass |
| 20,250 | 96.5% | 400 | 0% | 6,120 | 53 | fail |

Table: the search's own records (`knee-search-pool400-mr5-32g.jsonl`) with the per-rung load from the time series database.

{{figure search-cpu-threads}}

{{figure search-queue}}

The 300-thread search on the same Core, heap and latency stopped at 17,250 with CPU at 83%: the pool was full and the processor was not. Raising the pool by a third moved the knee by 3,000 devices, 17%, and handed the bound to the cores. The next section says why those two numbers are what they are.

## Threads, eight vCPU and the heap {#threads-vcpu-heap}

**Two constants set both knees: 5.2 seconds of thread time and 0.115 core-seconds of CPU per collection. The heap decides whether a third one appears.**

A collection on this fleet is 61 GETBULK round trips at a median 75.6 ms, 4.74 s on the wire at the Minion, plus about 0.45 s for the Kafka RPC in both directions, the XML in between and the Core's own work: 5.2 s from the moment a Collectd thread takes the service until it hands it back. During those 5.2 s the thread is parked for all but the last fraction. Little's law then says how many threads a fleet needs:

| Step | Value |
|---|---:|
| Collections required per second at fleet N | [N / 300]{.fx title="services on a 300 s interval; the Core and Minion add 4"} |
| Thread-seconds per collection | [5.2 s]{.fx title="300 threads / 57.58 collections per second at the 300-thread knee; 4.74 s of it on the wire"} |
| **Threads in flight** | **[N / 57.7]{.fx title="N / 300 × 5.2"}** |
| 300 threads carry | [17,300 devices]{.fx title="300 × 57.7; measured 17,250 pass with a 0.1% margin"} |
| 400 threads carry | [23,100 devices]{.fx title="400 × 57.7, if nothing else binds first"} |

The cores have their own constant. On every rung of both searches the CPU consumed per collection is the same: CPU busy times eight cores divided by the achieved rate gives 0.110 to 0.116 core-seconds, 0.115 at the knee. That is the cost of decoding one XML response, storing 144 interfaces' worth of attributes, looking up the node once per resource in the database and pushing the collection set to Kafka. It does not depend on the latency; the latency only decides how long a thread waits around it.

| Step | Value |
|---|---:|
| CPU per collection | [0.115 core-s]{.fx title="96.4% × 8 / 66.72 at 20,250; 0.110 at 17,250 with 400 threads; 0.115 at 17,250 with 300"} |
| Cores | 8 |
| **Collections per second the cores can decode** | **[69.6]{.fx title="8 / 0.115 at 100% CPU"}** |
| Fleet at 100% CPU | [20,900 devices]{.fx title="69.6 × 300"} |
| Fleet at the 96% cliff | [20,000 devices]{.fx title="0.96 × 69.6 × 300; measured: 19,750 pass, 20,250 fail"} |
| Threads that keep 8 cores busy | [362]{.fx title="8 cores × 5.2 s / 0.115 s: a thread uses a core 2.2% of its life"} |

The two limits cross between 300 and 400 threads. With 300 the pool binds at 17,300 while the cores are at 83%: a thread spends 2.2% of its life on a core, and 300 such threads can occupy 6.6 of 8. With 400 the pool could carry 23,100 but the cores run out at 20,000, which is where the search stopped. A pool above 400 buys nothing on eight cores; the next 3,000 devices need either 0.115 to become smaller or eight cores to become more.

{{figure threads}}

**The heap is the third term, and it is back.** The 16 GiB Core with a 10 GiB heap hit its knee at 14,250 on old-generation collections: 61 four-second pauses in 35 minutes, 17% of wall time. On 20 GiB there was no old-generation collection at any rung to 19,750, and young collections cost 4.1% of wall at 17,250 and 5.1% at 19,750. In the capture window at 20,250 the GC log shows 804 young collections, 18 concurrent marking cycles and 5 full collections of up to 6.4 s: 7.9% of wall time, and the live set after collection averaging 16.3 GiB of 20 against 15.2 GiB at 19,250.

{{figure heap-gc}}

The live set grows with the fleet, because every service holds its collection state and its cached resources, and with the pool, because every in-flight collection holds a decoded response and a collection set being built. 400 threads at 20,250 devices leave G1 about 3.5 GiB of headroom, and when a marking cycle cannot finish before the old generation fills, the collector falls back to a full stop. Each full collection holds all 400 threads and every response handler for six seconds, which at 67 collections a second is 400 collections not started. The heap term is small at this rung, 3 points of wall time above 19,750, but it is the term that grows fastest with the next rung, and it is the one a 20 GiB heap on a 32 GiB VM cannot move much further. The relationship, in one line: threads set how much waiting the pool can hold, cores set how many collections a second the Core can decode, and the heap must hold the fleet's state plus one decoded response per thread with room for G1 to mark.

## Load, context switches, latency and PDUs {#load-switches-latency}

**Load measures the cores, not the threads. Context switches measure the database, not the SNMP. Latency and PDUs measure the pool.**

{{figure load}}

The one-minute load on the Core rose from 30 at 17,250 to 56 at 19,750 and sits at 54 in the window, on eight cores. Load counts threads that are runnable or in uninterruptible sleep; a thread parked on an RPC future, a socket read or a lock is neither and does not count. So 400 collection threads waiting on the Minion contribute nothing to it. What contributes is the run queue: the 50 response handlers decoding XML, the collection threads in their 2.2% of CPU time, the Kafka producer, the eight GC workers during a young pause. The `node_procs_running` gauge agrees: 34 runnable at 17,250, 65 at 19,750, 53 in the window. A load of 54 on eight cores is a run queue seven deep: every runnable thread waits for a core six times longer than it runs, and the JVM's own counters show it as 7,300 involuntary context switches a second, 4,200 of them on the response handlers. That is the cliff the earlier report saw when a profiler was attached: at 96% CPU a few percent more demand lengthens every queue on the machine at once.

{{figure ctxsw}}

The context switches are the surprising number. The Core does 47,000 a second system-wide, and a 60-second read of every JVM thread's counters puts 46,000 voluntary switches a second on the 400 Collectd threads: 116 per thread per second, about 600 per collection. A thread that waited once on the RPC and once on the pool would switch twice per collection. The other 598 are the database. Every resource in the collection set, the node and each of 144 interfaces, is one read-only transaction in the Kafka producer's mapper, three socket round trips to PostgreSQL each over SSL, and every socket read is a park and an unpark: about 145 lookups, 435 round trips, plus the collection's own queries. The database confirms the count from its side, 10,834 commits a second at 67 collections a second, 162 per collection, and its own 50,000 context switches a second are the other end of the same wires. The rate is flat across the search, 47,000 at 17,250 and 49,000 at 20,250, because it scales with collections per second, which barely moves, not with the fleet. The Minion's 12,000 a second are its SNMP: one wake-up per response, 61 per collection, plus the timers.

{{figure search-load-ctxsw}}

Latency and PDUs per collection are the pool's terms and nothing else's. At `max-repetitions=5` a collection of this device is 61 GETBULK requests, each answered after a uniform 50 to 100 ms, 4.74 s at the median with a spread from 4.58 to 4.90 s; the requests are sequential because each GETBULK continues where the last one stopped. At the default `max-repetitions=2` it was 149 requests and 11.5 s, and the 200-thread pool bound at 5,250 devices; one attribute change cut the wait by 60% and moved that knee to 12,250. A fleet whose agents answered in 1 ms would need about 0.5 s per collection and 300 threads would carry about 175,000 devices by the pool, while the cores would still stop at 20,900: the CPU cost per collection is the same whatever the agent's latency. The general form, for a device with P PDUs per collection at a round trip of R and a Core overhead of about 0.45 s:

| Term | Formula | Here |
|---|---|---:|
| Time per collection | P × R + 0.45 s | [5.06 s]{.fx title="61 × 0.0756 + 0.45; measured 5.2 s from the pool"} |
| Threads for fleet N | N / 300 × (P × R + 0.45) | [351 at 20,250]{.fx title="67.5 × 5.2"} |
| Fleet by the pool, T threads | T × 300 / (P × R + 0.45) | [23,100 at 400]{.fx title="400 × 300 / 5.2"} |
| Fleet by the cores, C cores at c core-s per collection | C × 300 / c × utilisation | [20,000 at 96%]{.fx title="8 × 300 / 0.115 × 0.96"} |

Whichever is smaller is the knee. On this Core with 300 threads the first term is smaller; with 400 the second is.

## The window {#the-window}

**A collector at capacity and 1.2% short, not a collapse.** Over five cycles it completed 66.72 collections a second against the 67.51 that 20,254 services on a 300 s interval require: 98.8%. The pending queue stood between 7,954 and 10,114 and climbed at about one task a second, the difference between demand and capacity. The pool was at 400 in every sample.

{{figure throughput}}

{{figure queue}}

Once the queue saturates, the collector cycles through every service as fast as it can, and the effective interval is the service count divided by the capacity: 20,254 at 66.72 a second is one full pass every 304 s. At this rung the fleet loses 1.2% of its samples' timeliness; at 20,750 the demand would be 69.2 a second against the same 67 and the interval about 310 s. The runaway's slope is demand minus capacity, and capacity is fixed by the cores.

{{figure cpu-core-minion-db}}

The hand-taken thread dump at 13:08 shows the pool from the inside: 298 of 400 Collectd threads parked on an RPC future, 102 runnable, 94 of those inside a PostgreSQL socket read. Fifty response handlers existed and 18 were runnable. Under CPU starvation the database waits lengthen, because the threads that would consume the responses are queued for a core: at 17,250 in steady state the same dump showed 15 threads in a database read.

## Everything else {#everything-else}

**The database is the only other machine that moved, and it moved with the transactions.**

| VM | vCPU | CPU busy | Load, 1 min | Context switches/s | Note |
|---|---:|---:|---:|---:|---|
| Core | 8 | 96.4% | 54.3 | 46,900 | the knee: 74% user, 11% system, 5% softirq |
| Minion | 4 | 63.8% | 6.2 | 11,900 | 53% without its capture; 177 Mbit/s of XML towards Kafka |
| Database | 8 | 52.8% | 9.3 | 50,500 | 10,834 commits a second, 162 per collection, over SSL |
| Kafka broker | 2 | 29.0% | 0.8 | 5,200 | 429 Mbit/s on its interface |
| Simulator | 4 | 57.3% | 2.1 | 11,900 | 20,250 agents, 43 Mbit/s of SNMP, every response delayed 50 to 100 ms |

{{figure db}}

{{figure net-kafka}}

The database went from 42% at 17,250 to 53% at 20,250 and its connection pool on the Core peaked at 121 of 250 active. Neither is a limit yet, but the database is the second machine on the same curve, and it is on it for the same reason as the Core's context switches: one transaction per resource.

## What moves the knee {#what-next}

**Smaller CPU per collection, or more cores. Threads are spent.**

- **Threads.** 400 is the right size for eight cores at this latency: 362 keep the cores busy and the rest absorb the scheduling wave. More threads add in-flight collections, live heap and run-queue depth, and no throughput.
- **Cores.** The `xxxlarge` class with 16 vCPU roughly doubles the second limit to about 40,000 devices by the cores; the pool would then need 700 threads by the first, and the heap would need to hold twice the in-flight state. The heap is the one to watch on that path: 16 GiB live of 20 at 20,250 with 400 threads.
- **CPU per collection.** 0.115 core-seconds is XML decoding, attribute storing with a linear OID lookup, 145 database transactions and logging. The per-resource node lookup in the Kafka producer's mapper is the largest single term outside the XML and is also most of the 600 context switches per collection and most of the database's 53%; a per-collection-set cache removes 144 of the 145. The instrumentation log at INFO writes four lines per collection. Both are code or configuration on the Core, and both lower the constant that sets the knee.
- **Heap.** A 20 GiB heap on a 32 GiB VM is close to what the VM can give a JVM with 400 threads and a 1 GiB metaspace and native footprint. The next fleet on this class will meet full collections before it meets the pool; on 16 vCPU it needs the 64 GiB class.
