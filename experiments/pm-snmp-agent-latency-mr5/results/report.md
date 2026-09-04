---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent response time · max-repetitions 5"
title: "One attribute moves the ceiling<br>from 5,000 to 11,750 devices"
lede: "Same Core, same Minion, same 200 threads, same 50 to 100 milliseconds on every SNMP packet. One attribute in snmp-config.xml, max-repetitions 2 to 5, cut a collection from 149 requests to 58 and moved the knee from 5,000 to 5,250 devices up to 11,750 to 12,250. At the new knee the pool still binds first: the same fleet passes with 300 threads at 72% CPU, and the processor and the heap are one to two rungs behind."
verdict:
  - { k: "Knee", v: "11,750 to 12,250", n: "devices at 50 to 100 ms per PDU, 200 threads, max-repetitions 5", hero: true }
  - { k: "Against the default", v: "2.3x", n: "the pool-200 knee of 5,000 to 5,250 at max-repetitions 2" }
  - { k: "Requests per collection", v: "58", n: "down from 149, measured on the wire" }
  - { k: "300 threads at 12,250", v: "pass", n: "pool 237 of 300, Core CPU 72.1%: it was the pool" }
  - { k: "Metric rate at 11,750", v: "245.0M/h", n: "68,050 samples a second, 1,738 per device per cycle" }
caveats: |
  This is a single search on one deployment, one 900 s window per rung, three cycles each, with no repetition.
  The step is 1,000 devices to 10,250 and 500 above it, so the knee is bracketed to within 500 and not located more finely.
  The 58 requests per collection were read for one device over one collection; nl6 truncates per response, so a device with a long interface name in the last row may take one more.
  The injected latency is uniform between 50 and 100 ms on every response packet, a clean approximation of a real SNMP agent that must consult line cards or the control-plane CPU, and not a measurement of any particular device.
  The rung at 300 threads is a single window on the failing fleet after a restart, not a search; how far 300 threads carry was not measured.
method: |
  The latency injection and the pool are unchanged from the pool-200 search: `tc qdisc netem delay 75ms 25ms` on the simulator's SNMP interface, uniform 50 to 100 ms per packet, and `threads="200"` in `collectd-configuration.xml`.

  The one change is `max-repetitions="5"` in a `definition` for the range 10.42.0.0 to 10.42.255.255.
  On this release the file `etc/snmp-config.xml` is ignored: neither the `reloadSnmpConfig` event, the `reloadDaemonConfig` event nor a restart applied it.
  The Config Manager holds the live copy and its REST endpoint, `rest/cm/snmp-config/default`, applied the change without a restart.
  It was then verified three ways before any rung opened: the effective configuration for a fleet address through `rest/snmpConfig`, the request PDUs on the Minion's simulator interface, and one full collection of one device captured end to end.

  The search grew the fleet from 5,250 in steps of 1,000 to 10,250 and then 500, and stopped at the first rung that failed.
  Before each window opened, the rung's nodes were reconciled against the database, every node holding exactly 144 SNMP interfaces and none unscanned, then provisiond was observed idle and a further 300 s settle elapsed.

  Each rung is one 900 s window, three collection cycles.
  The pass criterion is the one used for the pool-200 search: the pending queue must return to zero inside the window, and the window integral of Collectd's completed-task counter must reach 97% of the collections the fleet requires in 900 s.

  Every figure is a Prometheus `query_range` at the 15 s scrape interval, spanning all ten rungs on one axis.
  Collectd's own JMX gauges carry the finding; Node Exporter supplies CPU and network as the control.
  Rates are window integrals of the completion counter over an integer number of cycles.
---

## The knee {#the-knee}

**Between 11,750 and 12,250 devices.** Nine rungs pass; the tenth does not, and the way the columns move across the nine says what is coming.

| Fleet | Queue at zero | Queue, median | Pool, mean of 200 | Core CPU | Collections done / required | Verdict |
|---:|---:|---:|---:|---:|---:|---|
| 5,250 | 77% of samples | 0 | 92 | 29.0% | 100.4% | pass |
| 6,250 | 59% | 0 | 110 | 33.5% | 98.4% | pass |
| 7,250 | 53% | 0 | 120 | 39.9% | 98.8% | pass |
| 8,250 | 51% | 0 | 129 | 46.0% | 100.9% | pass |
| 9,250 | 34% | 302 | 149 | 52.7% | 100.5% | pass |
| 10,250 | 26% | 813 | 168 | 59.2% | 100.9% | pass |
| 10,750 | 18% | 906 | 179 | 64.4% | 99.7% | pass |
| 11,250 | 15% | 907 | 188 | 69.2% | 99.8% | pass |
| 11,750 | 4% | 949 | 196 | 73.8% | 99.9% | pass |
| **12,250** | **never** | **2,808** | **200.0** | **74.5%** | **97.6%** | **fail** |

The queue is the pass test and it tells the story in one column: empty three quarters of the time at 5,250, empty for one sample in twenty-five at 11,750, and never empty at 12,250, where it peaked at 4,327 tasks and the window closed with 2.4% of the required collections not done.

{{figure queue}}

At 5,250 devices this is the same fleet the pool-200 search failed on twenty hours earlier. Then, the pool sat at 200 in every sample and the queue never drained. Now, the pool averages 92 and the queue is empty three quarters of the time. Nothing about the Core, the Minion, the latency or the pool changed between those two measurements.

{{figure completion}}

## On the wire {#on-the-wire}

**149 requests became 58, and 11.5 seconds became 4.4.** At the compiled default the collector asks each device for two table rows per GETBULK, ten columns at a time, and a 144-row interface table takes 73 steps of two requests. At `max-repetitions=5` it takes 29 steps. One device's collection, captured end to end on the Minion's simulator interface:

| | max-repetitions 2 (pool-200 search) | max-repetitions 5 (this search) |
|---|---:|---:|
| Requests per collection | 149 | 58 |
| Of which table GETBULKs, `N=0` | 146 at `M=2` | 56 at `M=5` |
| Response size, median / largest | 509 B / 569 B | 630 B / 1,143 B |
| Collection wall time | 11.52 s | 4.38 s |
| Per round trip | 77.3 ms | 75.5 ms |
| `tooBig` responses | 0 | 0 |
| IP fragments | 0 | 1 in 30 s of all traffic |

The largest response, 1,143 bytes, sits inside one 1,472-byte datagram with room to spare, which is why 5 was the value chosen: nl6 measures the real encoded response and drops rows from the end when it would not fit, answering `noError`, so a larger value would not fail here, it would silently return fewer rows whenever a long value appeared. The per-round-trip time did not move, 77 ms against 75; the injected delay is the round trip, and fewer round trips is the whole gain.

The setting itself was the surprise of the day. This Core runs the shipped defaults with no `snmp-config.xml` on disk, and writing one, with the pristine root and the new definition, changed nothing: not on a reload event, not on a restart. On Horizon 36 the Config Manager owns `snmp-config`; the file was imported once at first start and the database copy is authoritative. One `PUT` to `rest/cm/snmp-config/default` applied the definition immediately, and the effective configuration for a fleet address read `maxRepetitions 5` while a non-fleet address still read 2.

## Metric rate {#metric-rate}

**245.0 million metrics an hour at 11,750 devices, the last rung that completes its cycle.** Collectd finished 35,242 collections in that rung's 900 s window against the 35,262 that 11,754 collectable services on a 300 s interval require, 99.9% of the required rate, and every fleet collection carries 1,738 numeric samples.

| Step | 11,750 devices, last pass | 12,250 devices, first fail |
|---|---:|---:|
| Collectable services | [11,754]{.fx title="opennms_collectd_collectableservicecount: 11,750 fleet devices + Core and Minion carrying 2 services each"} | [12,254]{.fx title="12,250 fleet devices + 4"} |
| Collection interval | 300 s | 300 s |
| Collections per second required | [39.180]{.fx title="11,754 / 300"} | [40.847]{.fx title="12,254 / 300"} |
| Collections completed in the window | [35,242 in 900 s]{.fx title="increase(opennms_collectd_taskscompleted[900s]) at the end of the rung window, 17:40:06Z"} | [35,877 in 900 s]{.fx title="increase(opennms_collectd_taskscompleted[900s]) at 18:27:17Z"} |
| Collections per second achieved | [39.158]{.fx title="35,242 / 900"} | [39.863]{.fx title="35,877 / 900"} |
| Samples per collection, decoded from the wire | [1,738]{.fx title="numeric attributes per CollectionSet record on the metrics topic; 27,163 of 27,183 records in the 5,250-device live capture carried exactly this; unchanged by max-repetitions, which changes the requests, not the data"} | 1,738 |
| **[Samples per second]{.fx title="achieved collections/s × samples per collection"}** | **[68,056]{.fx title="39.158 × 1,738"}** | **[69,282]{.fx title="39.863 × 1,738"}** |
| **[Metrics per hour]{.fx title="samples/s × 3,600"}** | **[245,002,384]{.fx title="35,242 / 900 × 1,738 × 3,600 = 245,002,384"}** | **[249,416,904]{.fx title="35,877 / 900 × 1,738 × 3,600 = 249,416,904"}** |
| [Metrics per five-minute cycle]{.fx title="samples/s × 300, what one cycle actually delivered"} | [20,416,865]{.fx title="35,242 / 900 × 1,738 × 300 = 11,747 collections per cycle × 1,738"} | [20,784,742]{.fx title="35,877 / 900 × 1,738 × 300 = 11,959 collections per cycle × 1,738"} |

{{figure metric-rate}}

The 12,250 column is the ceiling, not a rate the fleet can keep: it is what 200 pinned threads delivered in a window whose queue never drained. The cleanroom, with agents answering in 0.1 ms, delivered 292.1 million an hour at 14,004 devices on this Core. At 50 to 100 ms per packet the same Core now delivers 84% of that.

{{figure throughput}}

## What binds now {#what-binds}

**Three things arrive close together; the rung in the next section separates them.**

{{figure threads}}

**The pool.** It fills one rung at a time, 92, 110, 120, 129, 149, 168, 179, 188, 196, and is pinned at 200 in every sample only at 12,250. At the default `max-repetitions` a thread held a collection for 11.5 s and the pool bound at 5,247 services per cycle; at 4.4 s the same arithmetic gives about 13,600, and the search found the pool full at 12,250. The 10% gap is the part of a collection that is not the SNMP round trips: the RPC through Kafka, the persistence, the scheduling.

**The processor.** In both earlier searches the CPU was a bystander, 16% at the 100-thread knee and 29% at the 200-thread knee. Here it climbs from 29% to 74.5%, about 6.5 points per thousand devices, because the pool now does three times the collections per second for the same occupancy. Extrapolated, the cleanroom's 85% would arrive near 14,000 devices, one to two rungs beyond the knee.

{{figure cpu}}

**The heap.** The floor between collections rises from 4.1 GiB at 5,250 to 8.3 GiB at 11,750 under a 10 GiB ceiling, and at 12,250 the first old-generation collections of the whole agent-latency campaign appear, three in the window. The cleanroom report identified Full GC as this deployment's real ceiling at 14,000 devices; it is now visible from 12,250.

{{figure jvm}}

The Minion, which executes the walks, is at 31% of four vCPU and carries 28 Mbit/s of SNMP on the simulator bridge and 107 Mbit/s of collection results towards Kafka at the knee. It scales with the fleet and is nowhere near a limit.

{{figure minion}}

## One rung at 300 threads {#pool-300}

**The same 12,250 devices pass with 300 threads.** After the search stopped, the pool was raised to 300 in `collectd-configuration.xml`, OpenNMS restarted, and one 900 s window measured on the fleet that had just failed.

| 12,250 devices | 200 threads | 300 threads |
|---|---:|---:|
| Queue at zero | never | 30% of samples |
| Queue, peak | 4,327 | 788 |
| Pool, mean / ceiling | 200.0 / 200 | 236.8 / 300 |
| Collections done / required | 97.6% | 100.2% |
| Core CPU | 74.5% | 72.1% |
| Verdict | fail | pass |

{{figure pool300}}

So at 12,250 it was the pool. With 100 more threads the pool still touches its ceiling at the crest of every cycle's wave, but between waves it falls to about 50 and the queue drains there, which the 200-thread pool never managed; the mean occupancy is 237, and the processor is no busier than before; it is fractionally less busy, because a pool that is pinned keeps the scheduler and the queue working for nothing. The CPU column is the one to watch from here: 72% at 12,250 with either pool, rising about 6.5 points per thousand devices, meets the cleanroom's 85% near 14,500, and the 300-thread pool's own arithmetic runs out near 15,500. Whichever comes first, it is the cleanroom's limit of 14,004 to 15,004 on this Core, and the thread lever has at most two rungs left in it.

## What the attribute bought {#against-the-defaults}

**A factor of 2.3 in fleet size, for one line of configuration.** Three searches, one Core, one latency:

| | 100 threads, M=2 | 200 threads, M=2 | 200 threads, M=5 |
|---|---:|---:|---:|
| Last rung completing a cycle | 2,504 services | 5,004 | 11,754 |
| First rung failing | 3,004 | 5,254 | 12,254 |
| Requests per collection | 149 | 149 | 58 |
| Seconds a thread holds a collection | 11.5 | 11.5 | 4.4 |
| Throughput ceiling, collections/s | 8.78 | 17.50 | 39.9 |
| Core CPU at the failing rung | 15.9% | 28.6% | 74.5% |
| What bound | the pool | the pool | the pool, confirmed at 300 threads |

Doubling the pool doubled the fleet and left the processor idle. Cutting the requests per collection by 2.6 raised the fleet by 2.3 and used the processor. The two levers are not alike: threads convert waiting into memory, and there was memory to spare; fewer requests remove the waiting, and what remains is work. This deployment at 50 to 100 ms per packet is now within 16% of its cleanroom limit of 14,004 devices at 0.1 ms.

There is one lever left on the pool side, and the rung at 300 threads shows it is worth one to two rungs: 12,250 passes with room, and the Core's processor and its 10 GiB heap arrive near 14,500, the fleet size the cleanroom found them at with agents answering in 0.1 ms. That is the outcome the research predicted: at `max-repetitions` 5 to 6 the collector stops being thread-bound and becomes the CPU-bound collector the cleanroom measured.

## How it was done {#how-it-was-done}

The injection is unchanged: one `netem` qdisc on the simulator's `enp6s19`, `delay 75ms 25ms`, uniform between 50 and 100 ms on every packet leaving the simulator. The driver asserted its presence before opening a window.

OpenNMS was restarted at 11:50 UTC, twelve minutes before the first rung, in the failed attempt to apply the file-based configuration; the first rung therefore started from an empty queue rather than the eight-hour backlog the pool-200 search had left behind. The Config Manager change followed at 11:56 and was verified on the wire before the search began.

The fleet was grown from 5,250 in steps of 1,000 to 10,250 and then 500. Each growth step was provisioned through the existing requisition, and the driver refused to open a window until the database showed exactly nodes × 144 interfaces with no node unscanned. That reconciliation earned its keep once: at 6,250 one node of the thousand added had lost its initial scan to a provisiond race at import time (`nodeReq ... cannot be null`) and sat with zero interfaces. A `forceRescan` event did nothing; the node was deleted and the requisition re-imported with `rescanExisting=false`, which scanned only the node it re-created, in six seconds. The race did not recur in the remaining 6,000 nodes.

Per rung: 1,000 new nodes scanned in 25 to 40 minutes at the stock 10-thread provisiond pool, provisiond observed idle, 300 s settle, 900 s window. Ten rungs between 12:02 and 18:27 UTC on 4 September. The driver stopped itself at the failing rung. The 300-thread rung followed at 19:21 UTC: `threads="300"`, a restart (up in 69 s with NMT and `MALLOC_ARENA_MAX` intact), one full cycle, the queue observed at zero, 300 s settle, reconciliation, 300 s settle, one 900 s window from 19:37:53. The fleet was held at 12,250 with the latency, the attribute and the 300-thread pool still applied.
