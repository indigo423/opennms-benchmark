---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent response time · at the ceiling"
title: "At the ceiling: 14,250 devices,<br>every service in the queue"
lede: "This is the rung the 300-thread search stopped at, held for seven cycles and captured end to end before the Core is resized. The collector completes 87% of what the fleet asks for, the queue holds every service that is not already running, and each device is collected every 344 seconds instead of 300. The processor is at 95% and one wall-clock second in six is an old-generation pause."
verdict:
  - { k: "Collections completed", v: "87.2%", n: "of required over seven cycles: 86,975 of 99,778", hero: true }
  - { k: "Effective interval", v: "344 s", n: "instead of 300: 14,254 services at 41.4 a second" }
  - { k: "Core CPU", v: "94.7%", n: "of 8 vCPU, load 60; 17.4% of wall time in GC" }
  - { k: "Old-generation pauses", v: "4.0 s", n: "each, 61 in 35 minutes, heap 9.1 GiB of 10" }
  - { k: "Metric rate", v: "259.1M/h", n: "71,982 samples a second, the most this Core delivers" }
caveats: |
  This is one 35-minute window on a fleet that had been at this size for five hours; it describes a failing steady state, not the transition into it.
  The window is seven cycles, not five: the stop was late by thirteen minutes, and the rings on the Kafka side of both hosts had wrapped, so the pcap there holds the last part of the window only.
  The injected latency is uniform between 50 and 100 ms on every response packet, a clean approximation of a real SNMP agent that must consult line cards or the control-plane CPU, and not a measurement of any particular device.
  The capture is not invisible: its per-minute `jcmd` snapshots begin with a class histogram, which forces a full collection, and the first five minutes of the window show the heap compacted to 5.9 GiB and the old-generation counter paused before the steady rate of two a minute resumes. The window's GC figures are therefore slightly kinder to the JVM than an unobserved half hour would be.
  Nothing else was changed during the window; the Core resize that follows is a separate run.
method: |
  The fleet is the failing rung of the 300-thread search at `max-repetitions=5`: 14,250 nl6 devices, 14,254 collectable services, `netem delay 75ms 25ms` on the simulator, Collectd `threads="300"`.
  It had run at this size since 02:43 UTC; the capture was armed at 07:42 and the window is 07:45 to 08:20 UTC, seven 300 s cycles.

  Every collector of the benchmark-capture skill ran on Core and the Minion: JFR profiles, GC logs enabled at runtime with `jcmd VM.log`, `perf` at 99 Hz, a 5 s procfs poller, sysstat, every interface as pcap, and the `metrics` topic itself streamed from the broker for 1,560 s.
  The artifact is sealed under `experiments/pm-snmp-agent-latency-mr5-live/results`.
  This report reads only the Prometheus side of it: Collectd's JMX gauges and counters, the JVM's G1 counters, Node Exporter on every VM.

  Rates are window integrals of the completion counter over the seven cycles.
  The effective interval is the service count divided by the achieved collection rate, which is what the fleet experiences when every service waits its turn.
---

## The state {#the-state}

**Every service is in the queue, and the queue is not growing.** The pending count sat between 13,894 and 13,954 for the whole window, with the per-cycle minimum never below 13,894. With 300 collections in flight that is 14,250, the whole fleet. A service is queued once and re-schedules itself only when its collection completes, so the queue cannot exceed the number of services; what looked like a runaway in the search is a collector cycling through every service as fast as it can.

{{figure queue}}

How fast it can is 41.42 collections a second: 86,975 completed against the 99,778 that 14,254 services on a 300 s interval need in 2,100 s, 87.2%. Turned around, 14,254 services at 41.42 a second is one full pass every 344 s. That is the effective collection interval of this deployment at this fleet: not 300 s, and not a collapse, but every counter sampled 15% less often than configured, with the shortfall spread evenly because the queue is a FIFO.

{{figure throughput}}

The pool is at 300 in every sample. It is not the constraint; it is full because each collection takes longer than the 4.4 s it took at 12,250, and it takes longer because the processor underneath it is starved.

{{figure threads}}

## The ceiling {#the-ceiling}

**The processor, with the heap driving a sixth of it.** Core CPU averaged 94.7% of 8 vCPU across the window, 79.4% user and 10.5% system, with a one-minute load of 60 on 8 cores. The JVM spent 17.4% of wall time in garbage collection: 61 old-generation collections at 3,998 ms each, 245 s in total, and 2,709 young collections for another 119 s. The heap cycled between 8.1 and 9.8 GiB against the 10 GiB ceiling with a median of 9.1 once the capture's own full collection at the start of the window had passed (that dip to 5.9 GiB is the observer, see the caveats).

{{figure heap-gc}}

A four-second old-generation pause every 34 seconds is the signature the cleanroom report described at 14,000 devices with agents answering in 0.1 ms, and named as the deployment's real ceiling. It is the same ceiling. The two searches that came between, at 100 and 200 threads with the default `max-repetitions`, never reached it because the pool bound first at 3,000 and 5,250 devices; one attribute and one pool size later, the collector is back where the cleanroom found it, and the 50 to 100 ms on every packet is no longer part of the picture.

{{figure cpu-core-minion-db}}

What the resize is expected to change is the heap term, not the CPU term. A 20 GiB heap on a 32 GiB Core should cut the old-generation rate and its pauses, returning most of the 17% of wall time to collection; whether the remaining 79% of user CPU then binds at a slightly larger fleet, or the heap was the larger part of the cost, is what the next search measures.

## Metric rate {#metric-rate}

**259.1 million metrics an hour: the most this Core delivers, at any latency.** It is 87% of what the fleet asks for, and 11% below the cleanroom's 292.1 million at 14,004 devices, where every cycle still completed.

| Step | Value |
|---|---:|
| Collectable services | [14,254]{.fx title="opennms_collectd_collectableservicecount: 14,250 fleet devices + Core and Minion carrying 2 services each"} |
| Collections required in 2,100 s | [99,778]{.fx title="14,254 / 300 × 2,100"} |
| Collections completed in the window | [86,975]{.fx title="increase(opennms_collectd_taskscompleted[2100s]) at 08:20:00Z"} |
| [Share completed]{.fx title="completed / required"} | [87.2%]{.fx title="86,975 / 99,778"} |
| Collections per second achieved | [41.42]{.fx title="86,975 / 2,100"} |
| [Effective interval]{.fx title="services / achieved rate: one full pass of the FIFO"} | [344 s]{.fx title="14,254 / 41.42"} |
| Samples per collection, decoded from the wire | [1,738]{.fx title="numeric attributes per CollectionSet record on the metrics topic; unchanged by max-repetitions, which changes the requests, not the data"} |
| **[Samples per second]{.fx title="achieved collections/s × 1,738"}** | **[71,982]{.fx title="41.42 × 1,738"}** |
| **[Metrics per hour]{.fx title="samples/s × 3,600"}** | **[259,135,800]{.fx title="86,975 / 2,100 × 1,738 × 3,600 = 259,135,800"}** |

The topic capture is the independent check: 60,081 records in 1,560 s is 38.5 a second on the wire, against 41.4 from the counter over a window that is not the same 26 minutes; the difference is the phase of the cycle the shorter capture landed in.

## Everything else {#everything-else}

**Nothing else in the lab is near a limit.**

| VM | vCPU | CPU busy | Load, 1 min | Note |
|---|---:|---:|---:|---|
| Core | 8 | 94.7% | 59.7 | the ceiling |
| Minion | 4 | 43.0% | 2.5 | 113 Mbit/s of results towards Kafka, 24 Mbit/s of SNMP on the bridge |
| Database | 8 | 34.5% | 3.7 | |
| Kafka broker | 2 | 18.3% | 0.3 | 115 Mbit/s in on the Core's interface |
| Simulator | 4 | 36.4% | 1.3 | 14,250 agents, every response delayed 50 to 100 ms |

{{figure load}}

The Minion, which the earlier reports watched as the second candidate to bind, is at 43% of four vCPU with 300 walks in flight, one UDP socket and one listen thread each. The Kafka segment carries 113 Mbit/s of collection results from the Minion and 115 Mbit/s into the Core; the broker itself is at 18% of two vCPU.

{{figure net-kafka}}

{{figure net-sim}}

{{figure cpu-kafka-netsim}}

{{figure db}}

## What the resize is expected to change {#what-next}

The Core is resized after this capture to the `xxlarge-mem` class added to the topology for it: 32 GiB, the same 8 vCPU, `JAVA_HEAP_SIZE=20480`. The 17.4% of wall time in GC and the four-second pauses are the part of this state a larger heap addresses directly; the 79% user CPU is not. If the knee moves past 15,000 the heap was the larger share of the ceiling; if it stays near 14,500 the processor was, and the next lever is `xxxlarge`'s 16 vCPU. Either way the search runs from 14,250 upward with the same latency, attribute and pool, so the two states compare rung for rung.
