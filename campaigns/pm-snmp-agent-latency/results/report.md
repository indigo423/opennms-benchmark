---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent response time"
title: "At 50 to 100 ms per PDU,<br>the ceiling is 2,500 devices"
lede: "The same deployment that collects from 14,000 devices when agents answer in 0.1 ms stops completing its cycle between 2,500 and 3,000 devices when every SNMP packet is delayed by 50 to 100 milliseconds. Nothing about the collector changed. What ran out was the thread pool, and the processor never got above 17%."
verdict:
  - { k: "Knee", v: "2,500 to 3,000", n: "devices at 50 to 100 ms per PDU", hero: true }
  - { k: "Throughput ceiling", v: "8.78/s", n: "collections, identical at 2,500 and 3,000" }
  - { k: "Core CPU at the knee", v: "15.9%", n: "of 8 vCPU: the processor was idle" }
  - { k: "Against the cleanroom", v: "5.6x", n: "fewer devices for the same collector" }
caveats: |
  This is a single search on one deployment, one window per rung, three cycles each, with no repetition.
  The step between rungs is 500 devices, so the knee is bracketed to within that and not located more finely.
  The injected latency is uniform between 50 and 100 ms on every packet in both directions, which is a clean approximation of a real SNMP agent that must consult line cards or the control-plane CPU before it can answer, and not a measurement of any particular device.
  Everything else about the deployment, the fleet profile and the pass criterion is identical to the cleanroom run, so the two are directly comparable.
method: |
  Latency was injected on the simulator's SNMP interface with `tc qdisc replace dev enp6s19 root netem delay 75ms 25ms`, which netem renders as a uniform distribution between 50 and 100 ms per packet.
  That was verified before the search rather than assumed: 200 ICMP probes from the Minion through the qdisc gave a minimum of 50.6 ms, a median of 76.0 and a maximum of 99.8.

  The search grew the fleet in steps of 500 from 2,000 and stopped at the first rung that failed.
  Search-upward only, because nl6 has no selective delete and every shrink is a full rebuild.
  Before each window opened, the rung's nodes were reconciled against the database, every node holding exactly 144 SNMP interfaces and none with a null `lastcapsdpoll`, then provisiond was observed idle and a further 300 s settle elapsed.

  Each rung is one 900 s window, three collection cycles.
  The pass criterion is the one used throughout this campaign: the pending queue must return to zero inside the window, and the median task completion ratio must be at least 0.99.
  Both are required.

  Every figure is a Prometheus `query_range` at the 15 s scrape interval, spanning all three rungs on one axis so the steps are visible.
  Collectd's own JMX gauges carry the finding: thread pool occupancy, queue depth, completion ratio and the completed-task counter.
  Node Exporter supplies CPU and network as the control.
  Rates are window integrals of the completion counter over an integer number of cycles.
---

## The knee {#the-knee}

**Between 2,500 and 3,000 devices.** 2,500 completes its cycle with the pass criterion met; 3,000 does not, and the failure is not marginal.

| Fleet | Queue at zero | Queue floor, median | Completion ratio, median | Collections done / required | Verdict |
|---:|---:|---:|---:|---:|---|
| 2,000 | 67% of samples | 0 | 1.0000 | 101.7% | pass |
| 2,500 | 4.9% of samples | 284 | 0.9998 | 99.7% | pass |
| **3,000** | **never** | **2,084** | 0.9991 | **87.6%** | **fail** |

The queue is the clearest signal. At 2,000 it sat empty two-thirds of the time. At 2,500 it emptied in one sample in twenty, which is a fleet that still finishes every cycle but with nothing to spare. At 3,000 it never emptied at all, its floor sat above 2,000 tasks throughout, and the window closed with 12.4% of the required collections not done.

{{figure queue}}

The completion ratio tells the same story more gently, because it is a per-task measure and most tasks that ran did complete. The number that does not hide the failure is the counter: 3,004 services on a 300 s interval need 9,012 collections in 900 s, and 7,896 were completed.

{{figure completion}}

The rung at 2,500 is worth a second look, because it is the practical ceiling rather than 3,000. It passes both criteria, and it also carries a queue floor of 284 and a pool at 100 in every sample. That is a deployment with no headroom at all. A rescan, a burst of retries, or another 200 devices would tip it. The honest ceiling for this collector at this latency is a little under 2,500, and 2,500 is the last rung measured to hold.

## What runs out, and what does not {#what-runs-out}

**Threads run out. Nothing else does.**

{{figure threads}}

The pool reaches its 100-thread ceiling at 2,500 and stays there. At 2,000 the rolling mean was 89 with the pool falling as low as 76 between bursts; at 2,500 and 3,000 the mean is 100.0 in every sample. Once every thread is parked on a round trip, adding devices adds queue and nothing else.

The throughput counter is the proof that the ceiling is real rather than a gauge artefact. Collections completed per second: 6.66 at 2,000, 8.34 at 2,500, **8.78 at 3,000**. The last two are the same number. Between 2,500 and 3,000 the fleet grew by 20% and the collector's output did not move, because it had already reached the rate that 100 threads can sustain when each collection holds a thread for about 11 seconds.

{{figure throughput}}

That arithmetic closes. A collection of this device is about 191 PDUs, of which roughly 135 are serialised on the round trip. At a 75 ms mean delay that is 987 + 135 × 75 ≈ 11.1 s per device. One hundred threads at 11.1 s each is 9.0 collections per second, and the measured ceiling is 8.78. The model that predicted the knee before the search ran put it at 2,700 devices; the search bracketed it at 2,500 to 3,000.

**The processor was a bystander.** Core CPU was 13% at 2,000, 17% at 2,500 and 16% at the failure. It went down slightly at the rung that failed, because a thread waiting on a socket costs nothing.

{{figure cpu}}

The JVM was checked and was not a factor: heap sat at 4.4 to 4.9 GiB against a 10 GiB ceiling and there was not a single old-generation collection in the whole search.

{{figure jvm}}

The Minion, which executes the walks the Core's threads wait on, was at 5 to 8% of four vCPU and carried under 8 Mbit/s on the SNMP bridge. It, too, was waiting rather than working.

{{figure minion}}

## What 50 to 100 ms costs against the cleanroom {#the-cost}

**A factor of 5.6 in fleet size, on the same collector.** The cleanroom run on this deployment completed every cycle at 14,004 collectable services with the agents answering in 0.1 ms. At 50 to 100 ms the last passing rung is 2,504. Same Core, same 100 threads, same 300 s interval, same 144-interface profile.

| | Cleanroom, 0.1 ms | This run, 50 to 100 ms |
|---|---:|---:|
| Largest fleet completing a cycle | 14,004 services | 2,504 services |
| Collections per second at that fleet | 46.7 | 8.3 |
| Core CPU at that fleet | 85.6% | 16.6% |
| Collectd threads, mean | 81 | 100 |
| What was the constraint | CPU and heap | the thread pool |

Two different machines are being described, and they are the same machine. In the cleanroom the collector is CPU-bound with a thread pool that idles between bursts. Under 75 ms of latency it is thread-bound with a processor that idles all the time. The cleanroom figure measures what the hardware can do; this one measures what the configuration lets it do, and the configuration is the smaller number by far.

The lever is obvious and it is also the one setting that was deliberately not touched here. Collectd runs 100 threads. A thread under this latency is occupied for 11 seconds and costs the processor almost nothing, so the pool is the constraint and the CPU that would let it grow is 84% idle. Doubling the pool would, on the same arithmetic, roughly double the fleet this latency supports, at a cost of some hundreds of megabytes of thread stacks and the contention risk that an earlier campaign hit at 200 threads on a smaller Core. That is the next experiment, not a conclusion of this one.

## How it was done {#how-it-was-done}

The injection is one `netem` qdisc on the simulator's `enp6s19`, the interface that carries SNMP between the Minion and the 10.42.0.0/16 namespace. `delay 75ms 25ms` with no distribution keyword gives netem's default, uniform between 50 and 100 ms, applied to every packet leaving the simulator. Requests from the Minion are not delayed on the way in, so the whole cost lands on the response, which is where a real agent spends it: the request arrives at once, and the agent takes 50 to 100 ms to assemble an answer from the hardware.

The fleet was rebuilt from 14,000 down to 2,000 before the search, because nl6 has no selective delete. Addressing was kept identical, so the 2,000 surviving nodes retained their scans and no re-scan wait was needed. Each growth step of 500 was provisioned through the existing requisition, and the driver refused to open a window until the database showed exactly nodes × 144 interfaces with no node unscanned. That reconciliation exists because two silently unscanned nodes were found on this fleet once, counted in the service gauge and yielding nothing.

Per rung: 500 new nodes scanned in about 11 minutes at the stock 10-thread provisiond pool, provisiond observed idle, 300 s settle, 900 s window. Three rungs, 84 minutes end to end. The driver stopped itself on the first failure, and the fleet was held at 3,000 with the latency still applied.
