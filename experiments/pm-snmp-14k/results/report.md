---
eyebrow: "PoweredBy 2026 · SNMP performance management · cleanroom ceiling probe"
title: "The cleanroom limit is between<br>14,000 and 15,000 devices"
lede: "Two fleet sizes were measured with no injected latency. At 14,004 collectable services the deployment completes every collection cycle. At 15,004 it never completes another one. The limit is bracketed by measurement rather than extrapolated, and the resource that gives way is not the one a linear reading of the CPU curve predicts."
verdict:
  - { k: "Limit bracketed", v: "14,004 to 15,004", n: "collectable services, pass to fail", hero: true }
  - { k: "At 14,004", v: "0.9994", n: "completion ratio, queue drains every cycle" }
  - { k: "At 15,004", v: "+4,867", n: "queue backlog in 30 min, never drains" }
  - { k: "Core CPU", v: "83.9 to 98.0%", n: "for 7% more fleet" }
caveats: |
  This is a cleanroom measurement and the word carries weight.
  The nl6 simulated agents answer from an in-memory table in microseconds, never time out, never drop a packet and never rate-limit, and every virtual machine sits on one physical host behind in-kernel bridges.
  Collectd threads spend their working life blocked on the SNMP round trip, so response time is the single assumption this entire result rests on.
  The campaign that produced this fleet measured what that assumption is worth rather than guessing: at 8 to 12 ms per PDU, a 14,000 fleet stopped completing its cycle.
  Read the bracket as a ceiling on ideal hardware under ideal conditions, and treat any real estate of the same size as needing more.
  Each rung is one window and one trial, so neither carries a dispersion statistic, and OpenNMS was not restarted between them.
method: |
  Every figure is a Prometheus `query_range` over one window, with the exact expression printed beneath it.
  Each rung is measured over 1,800 seconds, exactly six 300-second collection cycles, because a window that is not an integer multiple of the interval lets its phase decide the result.

  Both window starts were chosen from the data, not in advance.
  For the 14,000 rung, removing the injected latency at 14:00:16Z left a backlog that took roughly four cycles to clear; the queue floor first returns to zero at 14:20Z and the window opens at 14:25Z.
  For the 15,000 rung, the fleet grew at 15:52 and the provisioning scans ran until 16:35:09Z; the window opens at 17:20Z, 45 minutes later, so that no scan load is inside it.

  Every figure is plotted at a 15 second step, which is the Prometheus scrape interval on all three pools, so no point is interpolated between scrapes.

  Queue depth and pool occupancy spike faster than a cycle, so they are drawn as rolling peaks and floors with `max_over_time` and `min_over_time` over a one minute range, sampled every 15 seconds.
  The range has to be wider than the step: at a 15 second range each point would contain exactly one scrape, and the peak and the floor would collapse into the same series.
  The two figures that span both rungs use a five minute rolling range instead, so one cycle's burst and drain stays legible across three and a half hours.

  The completion ratio is a sawtooth that resets toward zero at every cycle boundary, so it is judged on the median and never on the minimum.
  Heap is reported against its ceiling rather than as a percentage, because G1 fills whatever ceiling it is given.

  No counted metric rate appears in this report. An attempt to read one from the Kafka topic returned 596 seconds of data for an 1,811 second window, because the topic's `retention.bytes` of 512 MiB per partition holds only about eleven minutes at this fleet size. The sample figures below are therefore derived and labelled as estimates.
---

## The cleanroom limit {#the-limit}

**Between 14,004 and 15,004 collectable services.** The lower figure completes every collection cycle. The upper one completes none, and accumulates backlog without bound. Both were measured with no injected latency, on the same hardware, the same heap and the same 100 Collectd threads, 90 minutes apart.

That is a bracket, not a point. No rung was measured inside the 1,000-service gap between them, so the limit is located to within about 7% of itself and no better.

One figure carries the whole result. At 14,004 the queue floor returns to zero every cycle, which is what completing a cycle looks like. The fleet grew at 15:52 and the provisioning scans ran until 16:35, which is the inflated middle of this window and not steady state. After that the floor never returns to zero again.

{{figure bracket-queue}}

The resource that gives way is not the one a linear reading predicts, and this report previously got that wrong. Extrapolating the 14,004 cost of 0.4793 millicores per device to 15,004 predicts 89.8% CPU, comfortably short of saturation. The machine actually sits at 98.0%. Roughly 0.65 of a core appears that linear scaling does not account for, on a 7% larger fleet.

{{figure bracket-cpu}}

So per-device cost is not constant near the limit. It rose from 0.4793 to 0.5225 millicores, 9% worse, and old-generation collections nearly doubled over the same step. Memory pressure and CPU are not independent constraints here: the extra core of work is most plausibly the garbage collector, which means the earlier estimate of a ceiling "near 15,900 at 95% CPU" was wrong both in where it put the limit and in assuming the curve stays straight long enough to extrapolate along.

Narrowing the bracket is expensive rather than difficult. It needs a rung between the two, and rebuilding a fleet at an intermediate size costs about ten hours of provisioning scans at the 0.409 nodes per second measured here, before any measurement window can open.

## The floor: 14,004 services completes a cycle {#the-floor}

Over six consecutive collection cycles the pending queue returned to zero and the median task completion ratio was 0.9994, which is the pass criterion the fleet-scaling campaign used throughout. Both conditions are required and both held.

The queue is the test that matters, and the floor is the part to read. A queue that fills and empties within each cycle has completed its work. A queue whose floor rises from cycle to cycle is accumulating backlog, and no amount of peak-shaving hides it. Across the window the rolling one-minute floor sat at zero in 70% of the 121 sampled points and never rose above 391 tasks. The rolling peak reached 793, which is the normal burst as Collectd schedules a cycle, and it drained every time.

{{figure queue}}

The completion ratio corroborates it from the other side. Its median was 0.9994 and its minimum across the whole window was 0.9974, so even the worst sample stayed above the 0.99 threshold. That minimum is worth stating explicitly because the same gauge read 0.0036 at its worst during an earlier run at 12,055 services, which is the sawtooth resetting at a cycle boundary rather than a system in trouble.

{{figure completion}}

## What the far side of the limit looks like {#past-the-limit}

It does not crash. It goes permanently late, and it stays that way. Over the 1,800 second window measured at 15,004 collectable services, 45 minutes after the last provisioning scan finished, the pending queue never once fell below **8,475 tasks** and finished at **13,342**.

That is a rise of 4,867 tasks in 30 minutes, a steady 2.7 tasks per second of work arriving that never gets done. By the end of the window the backlog is approaching one full cycle's worth of the fleet, 13,342 against 15,004 collectable services. Nothing in that trajectory turns over.

The pass criterion fails on both halves at once, which is what makes it unambiguous. The queue must return to zero and it never approaches it. The floor is the test, and here the floor is the diagnosis.

The thread pool tells the same story from the other side, and more starkly than at any point in this report. Its rolling one-minute mean has a median of 100.00 against a ceiling of 100, and a **minimum of 99.75**. Not a peak that touches the ceiling, as at 14,004 where the mean occupancy was 71.5 and fell to zero between bursts. At 15,004 the pool is saturated in every sample of every minute of the window. There is no idle time left between cycles because the cycles no longer finish.

{{figure failing-state}}

Old-generation collections run at a median of 3.58 per minute, against 1.89 at 14,004. That is nearly double for 7% more fleet, and it is the clearest evidence that the extra CPU is garbage collection rather than collection work. The two constraints the earlier sections treated as separate candidates turn out to be the same constraint reached by different routes.

Two things this state is not. It is not the provisioning scan: that ended at 16:35:09, 45 minutes before this window opened, and the backlog has grown throughout rather than drained. It is also not a transient after the fleet grew. The fleet grew at 15:52, almost 90 minutes before the window closed, and there is no sign of recovery at any point in that time.

## What binds first {#what-binds-first}

Core CPU is the tightest resource at a mean of 83.9% of eight vCPU, peaking at 89.5%. Memory is the more dangerous one, because it is the only constraint here that cannot be relieved by configuration.

The other three virtual machines have room. The generator ran at 42.5%, the Minion at 33.4% and the database at 37.5%, all medians over the window. The database figure is unremarkable by design: under exclusive Kafka forwarding the metrics bypass PostgreSQL entirely, so its eight vCPU are sized for provisioning and node-scan bursts rather than for steady-state collection.

{{figure cpu}}

Setting this window against the campaign's earlier cleanroom rungs gives the shape of the approach:

| Collectable services | Core CPU | Millicores per device | Threads, mean | Heap used | Old-gen GC per minute |
|---:|---:|---:|---:|---:|---:|
| 10,055 | 55.7% | 0.4432 | 19.6 | 8.37 GiB | 0.00 |
| 12,055 | 75.9% | 0.5036 | 66.3 | 8.10 GiB | 0.62 |
| 13,555 | 85.4% | 0.5038 | 76.1 | 8.87 GiB | 1.47 |
| **14,004** | **83.9%** | **0.4791** | **71.5** | **9.09 GiB** | **1.89** |

**Do not fit a line to the CPU column.** Cost per device rises to 0.5038 millicores and then falls to 0.4791 at a larger fleet, which is not physically sensible. The earlier rungs were measured shortly after each growth step, when rolling rescans were still running, so they carry provisioning load this window does not. The direction of travel is usable. The slope is not, and any capacity number derived from it inherits that contamination.

The old-generation collection column has no such problem, and it is the one that should worry you. It goes from nothing, to 0.62, to 1.47, to a median of 1.89 per minute, with a peak of 2.74. Heap used sat at a median of 9.09 GiB against a 10.0 GiB ceiling and peaked at 9.75 GiB.

The heap is not a fixed size. `-Xms` is 8192m and `-Xmx` is 10240m, because `JAVA_HEAP_SIZE` in `opennms.conf` sets only the maximum. The JVM therefore starts at 8 GiB and may expand by a further 2 GiB. The lowest reading anywhere in this window is 8.27 GiB, already above that initial size, so the heap has grown into its expansion room and stayed there for the whole measurement.

Heap percentage on its own is not a pressure signal, because G1 fills whatever ceiling it is given, so the number to judge is the old-generation collection rate. On that measure this deployment is working harder at 14,004 services than it was at 13,555, and there is nowhere left to give it more room.

{{figure heap}}

{{figure gc}}

One caveat cuts both ways. This JVM has been running since before the fleet was grown from 10,000 and has never been restarted at this size, so part of that memory pressure may be residue from four growth steps rather than the steady cost of this fleet. Restarting Core and re-measuring would separate them, and until that is done the memory figures are an upper bound on the true steady-state cost.

## What the cleanroom assumption is worth {#what-cleanroom-buys}

This is the number that decides whether any of the above transfers to a real estate, and it was measured rather than assumed. The identical fleet failed its cycle under 8 to 12 ms per PDU and passes without it, on the same hardware, the same heap and the same 100 Collectd threads.

The clearest evidence is the queue floor either side of the change. Under injected latency the floor compounded from cycle to cycle, climbing past 3,400 tasks and never returning to zero. The `netem` qdisc was removed at 14:00:16Z and nothing else was touched. The floor then fell over roughly four cycles and reached zero at 14:20Z, where it stayed.

{{figure latency-removal}}

The mechanism is thread occupancy, and it is visible directly. Collectd threads block on the SNMP round trip that the Minion executes, so injected latency does not consume CPU, it consumes threads. Under latency the pool mean was 100.0 against a ceiling of 100, pinned for the entire measurement window. In this window the pool still touches 100 at its rolling peak, but its mean occupancy is 71.5 and it falls all the way to zero between bursts. The pool is busy and then idle, which is what a pool that is keeping up looks like.

Core CPU is the control that makes the point. It was 85.2% under latency and is 83.9% here. The processor was doing the same work in both regimes. Only one of them completed its cycle.

{{figure threads}}

The practical reading is that the cleanroom buys less headroom than its name suggests, and buys it in one specific currency. The campaign's earlier sweep at 3,801 devices found delivered throughput flat to within 1% from 0 to 50 ms of injected delay, because at that fleet size the thread pool had ample slack to absorb the extra occupancy. At 14,000 the slack is gone, and 8 to 12 ms is enough to tip the pool from 70.4 occupied to 100 pinned. Latency does not degrade this system gradually. It does nothing at all until the pool saturates, and then the cycle stops completing.

That also means thread count, not fleet size, is the first thing to revisit before trusting any of these figures against real agents.

## What is actually being collected {#what-is-counted}

Four counts in this deployment are close together and mean different things. Mixing them up is the easiest way to get the per-device arithmetic wrong, so they are set out here before any rate is quoted.

| Count | Value | What it is |
|---|---:|---|
| Simulated devices | 14,000 | What nl6 runs and answers SNMP for |
| Nodes in the inventory | 14,002 | The fleet plus two nodes the requisition does not create |
| IP interfaces | 14,002 | Exactly one per node |
| Monitored services, all daemons | 42,006 | Everything Pollerd, Collectd and telemetryd watch |
| **Collectable services** | **14,004** | What Collectd schedules, and the gauge every figure here uses |
| SNMP interfaces | 2,015,712 | The rows the collect policy enabled |

The inventory is 14,002 because two nodes exist that no requisition created. Node 1 is `localhost` in foreign source `selfmonitor`, which is the Core monitoring itself. Node 2 is `minion-benchmark-01` in foreign source `Minions`. The other 14,000 are the fleet, all in `nl6-pm-72m`.

Collectable is not the same as monitored, and the gap between 42,006 and 14,004 is where most of the confusion lives. Every fleet node carries three services: `ICMP`, `SNMP` and `gNMI-Telemetry`. Only `SNMP` is collected by Collectd. `ICMP` is polled by Pollerd and `gNMI-Telemetry` is handled by telemetryd, so neither appears in the gauge this report measures.

That gives 14,000 collectable SNMP services. The remaining four are the ones on the two non-fleet nodes: `OpenNMS-DB`, `OpenNMS-DB-Stats` and `OpenNMS-JVM` on node 1, and `JMX-Minion` on node 2. They are collected over JMX and JDBC rather than SNMP, and they return a different attribute count per service than an interface walk does. Four services in 14,004 is therefore not four samples in 14,004.

**Two of the 14,000 fleet nodes had never been scanned during this window.** Nodes 16254 and 16263, `cisco-crs-x-10.42.50.41` and `cisco-crs-x-10.42.48.13`, both had a null `lastcapsdpoll` and held zero SNMP interfaces. Every other fleet node holds exactly 144, which is why the interface total is 2,015,712 rather than the 2,016,000 that 14,000 nodes would give. The 288 missing rows are precisely those two nodes.

They were not inert. Both still carried an `SNMP` service, so Collectd counted them in the 14,004 and scheduled a collection against them every cycle, which can return node-level data at most. This is the failure mode that leaves no trace in any headline number: the fleet reports 14,000, the service gauge reports 14,004, the queue drains and the completion ratio is 0.9994, and two devices are silently yielding almost nothing. It is found by reconciling the interface count against the node count, and in no other way.

Both nodes were rescanned by hand after this window closed, at 15:20:51Z and 15:22:09Z. The inventory is now complete: no fleet node has a null `lastcapsdpoll`, every one holds 144 SNMP interfaces, and the interface total is 2,016,000, which is exactly 14,000 x 144. The figures in this report are deliberately left as measured, because they describe the window as it actually ran. A window opened after the remediation would multiply by 14,000 rather than 13,998, a difference of 0.014% and well inside the estimate's other assumptions.

## The metric rate {#metric-rate}

Collectd completed 83,870.92 collections across the 1,800 second window, which is 46.59 per second against the 46.68 per second the fleet requires. Required is not a typed-in constant. It is the daemon's own collectable service count of 14,004 divided by the 300 second interval, captured from the same gauge in the same window.

That is 99.8% of the required rate, or 5.99 of the six cycles the window contains. The 0.2% shortfall is where the cycle boundaries happened to fall relative to the window edges, not a growing backlog: the queue returned to zero throughout, which a system falling behind cannot do.

{{figure throughput}}

The sample rate that follows is an estimate, and is marked as such because it is derived rather than counted. Each fully scanned device yields 1,738 samples per cycle, an arithmetic that reproduced the measured figure exactly at 3,801 devices: 144 interfaces at 12 numeric attributes each, plus ten node-level attributes from `mib2-tcp`. The device count to multiply by is 13,998, not 14,000, because two fleet nodes held no SNMP interfaces during this window.

| Step | Value |
|---|---:|
| Collectable services | 14,004 |
| Collection interval | 300 s |
| Collections per second required | 46.68 |
| Collections per second achieved (window integral) | 46.59 |
| Devices with a completed scan | 13,998 |
| Estimated samples per device per cycle | 1,738 |
| Estimated samples per second | 81,095 |
| Estimated metrics per hour | 291,900,000 |

Treat the last three rows as estimates, and as a slight upper bound. They assume every collection returns a full 1,738, which the two unscanned nodes and the four JMX and JDBC services do not. Multiplying the measured throughput instead, 46.59 collections per second at 1,738 samples, gives 80,973 samples per second, and the two methods agree to within 0.2%.

No counted figure is offered because none could be obtained. Reading the Kafka metrics topic between two offset bounds is how the 3,801-device rate of 22,036 samples per second was established, but at this fleet size the topic's `retention.bytes` of 512 MiB per partition holds roughly eleven minutes of data. A read spanning 1,811 seconds silently returned 596 seconds of it, clamped to the oldest surviving offset. Any counted rate at this scale needs the retention raised first, or a window shorter than about 690 seconds.
