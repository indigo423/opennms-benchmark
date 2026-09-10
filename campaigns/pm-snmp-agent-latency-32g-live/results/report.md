---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent response time · 32 GiB Core"
title: "17,250 devices,<br>with nothing to spare"
lede: "The 300-thread search on the resized Core stopped at 17,250 devices. Held there and left unobserved, the rung completes every cycle: 57.58 collections a second against the 57.51 the fleet requires, a margin of one part in a thousand, with the pool full, the processor at 83% and the heap no longer in the picture. The margin is so thin that arming a profiler on the Core tipped it into a collapse twice. One hundred more collection threads turn the margin into headroom; the JVM's garbage collector has nothing left to give."
verdict:
  - { k: "Collections completed", v: "100.1%", n: "of required over five cycles: 57.58 against 57.51 a second", hero: true }
  - { k: "Queue at zero", v: "5.9%", n: "of the window at 300 threads; 82% at 400" }
  - { k: "Core CPU", v: "82.9%", n: "of 8 vCPU, unobserved; 99% and collapse with a profiler attached" }
  - { k: "Garbage collection", v: "4.1%", n: "of wall time, all young; 0 old-generation collections" }
  - { k: "Metric rate", v: "360.3M/h", n: "100,074 samples a second, every cycle complete" }
caveats: |
  This is one 25-minute window, five cycles, 18 minutes after an OpenNMS restart that cleared the backlog a failed capture had left. The first two attempts to capture this rung are in the artifact as `results-attempt1` and `results-attempt2`; each collapsed the Core within three minutes of arming and neither is a steady-state measurement.
  The Core JVM was not observed in the sealed window: no JFR, no periodic `jcmd`. Its profile comes from attempt 1, recorded during the collapse. The Minion carried every collector and reads about ten CPU points higher than it does unobserved.
  The injected latency is uniform between 50 and 100 ms on every response, a clean approximation of a slow agent and not a measurement of any particular device. Each tuning trial is one 15-minute window after one restart.
method: |
  The fleet is the first rung the 300-thread search marked as failing on the 32 GiB Core: 17,250 nl6 devices, 17,254 collectable services, `netem delay 75ms 25ms` on the simulator, `max-repetitions=5`, Collectd `threads="300"`, a 20 GiB heap. The search's verdict came from a window opened 16 minutes after the Proxmox host had rebooted and 500 nodes had been imported; this report re-measures the rung in steady state.

  The sealed window is 01:10 to 01:35 UTC on 2026-09-06, five 300 s cycles. The Core ran procfs and sysstat collectors, a GC log enabled at runtime with `jcmd VM.log`, and one `Thread.print` taken by hand at 01:21. The Minion ran JFR, `jcmd` snapshots, `perf`, procfs, sysstat and a pcap ring on every interface. The artifact is sealed under `experiments/pm-snmp-agent-latency-32g-live/results`; this report reads its Prometheus side, the GC log, the thread dump, the Minion's pcap and the Core JFR from `results-attempt1`.

  Rates are window integrals of the completion counter over an integer number of cycles, read from the counter's first and last raw sample inside the window. The pass rule is the knee search's: the pending queue must return to zero inside the window and the completed count must reach 97% of the services due. Tuning trials are judged by the same rule over 15-minute windows with `results/bin/trial.py`.
---

## The verdict {#the-verdict}

**17,250 devices complete every cycle, by one part in a thousand.** Over the five cycles the collector completed 86,370 collections against the 86,270 that 17,254 services on a 300 s interval require: 57.58 a second against 57.51, 100.1%. The pending queue returned to zero once per cycle, for 5.9% of the samples, and peaked at 611. By the knee search's own rule this rung passes.

{{figure throughput}}

The search had marked it as failing at 23:44 the evening before, with a queue peak of 4,777 that never touched zero. That window opened 16 minutes after the Proxmox host had rebooted and 500 nodes had been imported; the queue it measured was the backlog of that import, which a collector with a 0.1% surplus works off at about one collection a second. The knee of the 300-thread pool on this Core is therefore not between 16,750 and 17,250 but at 17,250 itself, and the rung below is the last one with any surplus: at 16,750 the pool averaged 299.8 and the queue was at zero 1.6% of the time.

{{figure queue}}

The pool is the bound. It averaged 298.0 of 300 threads for the whole window. At 57.58 collections a second, 300 threads mean 5.2 s per collection, and the wire measurement below accounts for 4.74 s of that. Every thread is waiting on the Minion for most of its life, and there is no thread to give the next service.

{{figure threads}}

The 16 GiB Core's ceiling at 14,250 was the heap: 61 old-generation pauses of four seconds in 35 minutes, 17% of wall time in GC. On the 20 GiB heap the old generation was never collected in this window, in the search's six rungs above 14,250, or in any of the trials. The resize moved the knee by 3,000 devices, from 13,750 passing and 14,250 failing to 16,750 passing and 17,250 on the line, and left a different bound behind.

## The observer {#the-observer}

**The Core at this rung has no CPU to give an observer, and the collapse it causes is self-reinforcing.** Attempt 1 armed perf, JFR, a per-minute `jcmd` snapshot and a catch-all pcap on the Core at 00:12:35. Within two minutes the Core went from 85% to 99% CPU and the completion rate fell from 58 a second to 12. The queue climbed to 16,099, the whole fleet, and stayed there after the collectors were stopped: at 85% CPU the surplus is one collection a second, and a backlog of 13,000 does not drain at that rate. Only a restart cleared it.

{{figure observer-throughput}}

Attempt 2 armed JFR and the `jcmd` snapshots only, no perf and no pcap, at 00:45:53. The result was the same within three minutes: 99% CPU, 6.6 collections a second, the queue at 8,385. The JVM collectors alone are enough. That is why the sealed window leaves the Core JVM unobserved, and why the Core's profile in this report comes from the attempt that collapsed.

{{figure observer-cpu-queue}}

What makes the collapse nonlinear is the shape of the work. A few percent of extra CPU starves the single Kafka consumer thread that receives every RPC response and the response handlers that decode them; collections that would have taken 5.2 s take longer, the 300 threads stay occupied longer, the queue grows, and the scheduler thread that feeds the pool burns a core polling it. The state is stable in the wrong direction until the load is removed and the queue is reset.

## Where the CPU goes {#where-the-cpu-goes}

**Decoding the Minion's XML and storing the result, not collecting.** The JFR from attempt 1 holds 55,870 execution samples over 809 s. 51.9% of them are on the `rpc-client-response-handler` threads, an unbounded cached pool that grew to 122 threads during the collapse and held 35 in the steady-state dump. These threads do the work of a collection once the Minion has answered: unmarshal the RPC response from XML through EclipseLink MOXy (the `XMLStreamReaderReader.parse` path is in 20.9% of all stacks, `SAXUnmarshaller.unmarshal` in 17.3%), then walk the result into the collection set (`SnmpIfCollector.storeResult` in 16.7%). Inside `storeResult`, `findAttributeTypeForOid` is 9.5% of stacks: a linear scan over attribute types with `SnmpObjId.compareTo` as the single hottest frame at 9.4%.

The Collectd threads themselves barely register. In the steady-state thread dump 279 of 300 are parked on an RPC future, 21 are runnable, and 15 are in a PostgreSQL socket read.

{{figure heap-gc}}

The heap is no longer a term. Young collections cost 412 pauses at 174 ms in the sealed window, 71.8 s in 1,755 s, 4.1% of wall time, with the heap cycling between 12.4 and 18.4 GiB of 20 and averaging 15.5. There were no old-generation collections. The JMX counter agrees with the GC log at about 2.5 s of young pause per minute.

Three smaller terms are worth naming because they are configuration, not code.

| Term | Evidence | Share |
|---|---|---:|
| Per-resource node lookups in the Kafka producer | `CollectionSetMapper.buildNodeLevelResourceForProto` opens a read-only transaction and calls `nodeDao.get` for every resource in a collection set: the node and each of its 144 interfaces, 145 round trips per collection. PostgreSQL commits 8,600 transactions a second at 57 collections a second; the database runs at 42% of 8 vCPU; Hibernate's `TwoPhaseLoad` is in 4.7% of Core stacks. The JDBC connection is SSL. | [4.7% of stacks + 42% of the DB]{.fx title="org.hibernate.engine.internal.TwoPhaseLoad.initializeEntity in 2,601 of 55,870 stacks; xact_commit delta 275,474 in 32 s on pg_stat_database"} |
| Instrumentation logging | `DefaultCollectdInstrumentation` logs four lines per collection at INFO, 30 KB/s into `instrumentation.log`. `org.apache.logging` is the top frame in 4.8% of samples. `log4j2.xml` reloads every 60 s, so the level can change without a restart. | [4.8%]{.fx title="2,679 of 55,870 samples with an org.apache.logging top frame"} |
| The scheduler's polling loop | One `LegacyScheduler` thread accounts for 5.2% of samples, 4.1% of them in `LinkedBlockingQueue.peek`: it polls 17,254 queued services for readiness. | [5.2%]{.fx title="2,881 samples on the ThreadPoolExecutor scheduler thread"} |

{{figure db}}

## The wire {#the-wire}

**A collection is 61 GETBULK round trips at 75.6 ms each, 4.74 s on the wire, and the Minion adds almost nothing.** The last 50 seconds of the Minion's SNMP-side pcap hold 173,812 requests to 3,094 agents and 2,224 complete collections. Response time is the injected latency and nothing else: 55.7 ms at the 10th percentile, 75.6 ms at the median, 95.7 ms at the 90th, 100.3 ms at the 99th. A collection takes 61 requests (the search's earlier count of 58 was from the Core's side of the RPC, before the Minion's own table walks), 4.58 s at the 10th percentile, 4.74 s at the median, 4.90 s at the 90th.

The Core sees 5.2 s per collection. The 0.45 s difference is the RPC round trip through Kafka in both directions, the Minion marshalling the result and the Core unmarshalling it, and the wait for a response handler. With 300 threads and a 300 s interval that 0.45 s is worth 1,500 devices of capacity.

The Minion's JFR says what it spends its own CPU on: 94.3% of its 35,139 samples are on the SNMP4J transport threads, and 67.4% of all stacks are EclipseLink marshalling the SNMP results into formatted XML for the RPC reply (`NodeValue.marshal`), with `StringBuilder` growth alone the top frame in 28.2%. SNMP4J's own PDU processing is 12%. The Minion ran at 55% of four vCPU with the capture on it and 43% without, on a stock 2 GiB heap with 296 SNMP sessions and 11 RPC executor threads in flight; it is not near a limit, and the same XML costs the Core, which is, about as much again on the way in.

{{figure net-kafka}}

## The trials {#the-trials}

**One hundred more threads turn the margin into headroom; the garbage collector cannot.** Each trial changed one thing against the sealed baseline, restarted OpenNMS, waited for the 17,254 services to load and two cycles to settle, and was judged over 15 minutes by the knee search's rule.

| Run | Threads | Collector | Window (UTC) | Collections/s | Completion | Queue at zero | Queue peak | Pool busy, mean | Core CPU | GC pause share, mean pause | Verdict |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|---|---|
| Baseline | 300 | G1 | 01:10 to 01:35, 5 cycles | 57.58 | 100.1% | 6% | 611 | 298 of 300 | 82.9% | 4.1%, 174 ms | pass |
| Trial 1 | 400 | G1 | 02:00 to 02:15 | 57.30 | 99.6% | 82% | 217 | 306 of 400 | 77.9% | 4.0%, 148 ms | pass |
| Trial 2 | 300 | ParallelGC | 02:35 to 02:50 | 56.89 | 98.9% | 0% | 1,238 | 300 of 300 | 71.4% | 8.7%, 370 ms, 6 full | fail |
| Trial 3 | 400 | ParallelGC | 03:10 to 03:25 | 57.19 | 99.4% | 41% | 559 | 339 of 400 | 74.1% | 12.0%, 472 ms, 9 full | pass |

Table: every row is one window judged by `results/bin/trial.py` from the raw completion counter; required is 57.51 collections a second throughout. GC figures are from the runtime GC logs in the artifact, after a 20-minute warm-up.


{{figure trial-threads400}}

**Threads.** Trial 1 changed `threads="300"` to `"400"` and nothing else. The pool stopped being the bound: 306 threads busy on average with 94 spare, the queue at zero for 82% of the window instead of 5.9%, its peak 217 instead of 611. Completion is 99.6% rather than 100.1% because the collector now waits for work; the achieved rate is the fleet's demand. The Core's CPU fell five points to 77.9%, which the scheduler's polling loop explains: with the queue empty most of the time there is less to poll. The Minion at 43% is the unobserved figure.

**JVM.** Trial 2 kept 300 threads and replaced G1 with `-XX:+UseParallelGC`. The Core's CPU dropped twelve points to 71.4%: G1's concurrent refinement threads and write barriers are gone. The pool did not notice. 300 of 300 threads stayed busy, the queue never went below 365, completion was 98.9%, and the rung fails the rule. The GC log says why the lower CPU bought nothing: ParallelGC's pauses are stop-the-world and longer, 370 ms on average against 174 ms, 8.7% of wall time against 4.1%, with six full collections of up to 6.3 s in fourteen minutes. Every pause holds all 300 collection threads and every response handler at once; the processor is idle and the work waits.

{{figure trial-parallelgc}}

**Both.** Trial 3 combined them. It passes, with 339 threads busy against 306 in trial 1, the queue at zero 41% of the time against 82%, and Core CPU at 74.1%. The lower CPU is real and the pool relief is real, but the pauses cost the pool about 33 threads of occupancy that G1 does not.

{{figure trial-both}}

**What this says about the levers.** The bound at 300 threads is the pool, and the only setting that moves it is the pool. The bound at 400 threads is the fleet's own demand, with the processor at 78% and about 15 points to spare before the observer effect's cliff. The JVM has no heap problem left to solve on 20 GiB, and the throughput collector trades concurrent CPU for pauses that this workload cannot afford. `threads="400"` with G1 is the configuration this rung wants; the next rung up will meet the processor, not the pool.


## Everything else {#everything-else}

**Nothing else in the lab is near a limit, and the database is the one to watch.**

| VM | vCPU | CPU busy | Load, 1 min | Note |
|---|---:|---:|---:|---|
| Core | 8 | 82.9% | 19.9 | the bound: pool full, processor at the cliff; 230 Mbit/s on the Kafka side |
| Minion | 4 | 54.8% | 5.1 | 43% without its capture; 296 walks in flight; 162 Mbit/s of XML towards Kafka |
| Database | 8 | 41.8% | 4.1 | 8,600 transactions a second, one per resource |
| Kafka broker | 2 | 22.2% | 0.7 | 392 Mbit/s on its interface: RPC in both directions plus the metrics topic |
| Simulator | 4 | 45.9% | 1.5 | 17,250 agents, 40 Mbit/s of SNMP, every response delayed 50 to 100 ms |

{{figure cpu-core-minion-db}}

{{figure load}}

The Minion also absorbs about 2,300 syslog messages a second that nl6 still sends to a port nothing listens on, and answers each with an ICMP unreachable: 114,493 datagrams and 49,665 ICMP replies in the 50 s pcap. It is noise on the Minion's interface and CPU, not on the Core's.

## What is left {#what-next}

**The processor is the bound, the pool is the lever that is configuration, and the larger levers are code.**

- **Collectd threads.** `threads="400"` is the one setting that gave this rung headroom, and it costs nothing while the processor has 15 points to spare. The pool sweep at 3,000 devices found context switches rising above 200 threads; at 17,250 the collections are five seconds long and the switches are cheap against them. Above 400 the CPU, not the pool, decides.
- **JVM.** With a 20 GiB heap the collector is 4% of wall time and old-generation collections are gone. ParallelGC takes twelve CPU points off the Core and gives them back as pauses that stall every collection thread; it fails at 300 threads and underperforms G1 at 400. There is no heap or collector setting that moves a bound of this shape.
- **Instrumentation logging.** Four INFO lines per collection, 30 KB/s, about 5% of samples. Setting `instrumentation` to `WARN` in `log4j2.xml` is a configuration change that applies within a minute. It was not trialled here because the question was threads and JVM; it is the cheapest of the CPU points on the table.
- **Per-resource node lookups.** 145 read-only transactions per collection in the Kafka producer's mapper, 8,600 a second on the database over SSL, with no cache and no setting. Caching the node-level resource per node for the life of a collection set would remove all but one of them. This is a code change in `CollectionSetMapper`, and the largest single CPU term outside the XML itself.
- **The XML.** Both JVMs spend most of their CPU marshalling and unmarshalling SNMP results as formatted XML through the Kafka RPC. A binary encoding for the SNMP proxy module would return more CPU to the Core than any setting can. It is code, and it is the ceiling's true name.
