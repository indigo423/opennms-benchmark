---
eyebrow: "PoweredBy 2026 · SNMP performance management · sizing benchmark"
title: "72 million metrics<br>an hour"
lede: "What it took to sustain SNMP data collection at that rate on a single physical host, what the configuration actually needs to be, and why these figures are a floor rather than a target."
verdict:
  - { k: "Sustained", v: "79.3M", n: "metrics per hour", hero: true }
  - { k: "Sample rate", v: "22,036", n: "samples per second" }
  - { k: "Fleet", v: "3,801", n: "simulated SNMP devices" }
  - { k: "Host footprint", v: "26 vCPU", n: "56 GB RAM, 570 GB disk" }
caveats: |
  These are minimum requirements, not a sizing target.
  Every figure here was produced under conditions close to the best case an OpenNMS deployment can encounter: the simulated SNMP agents answer from an in-memory table in microseconds, never time out, never drop a packet and never rate-limit.
  All six virtual machines sit on one physical host connected by in-kernel Linux bridges, so round-trip latency is sub-millisecond with no jitter and no loss.
  Collectd threads spend their time blocked on SNMP round trips, so when an agent answers in 40 ms instead of 40 µs the same thread count sustains a small fraction of the devices.
  Treat this configuration as the floor below which the workload will not fit at all, and expect a real estate of the same size to need materially more.
method: |
  A consumer reads the Kafka metrics topic between two recorded offset bounds, decodes each CollectionSet and counts numeric attributes.
  A metric is one numeric attribute on one resource in one collection cycle.
  Message count is not a proxy for it: a single CollectionSet carries many resources with many attributes each, and the producer may split one set across several messages.

  Rate is computed against the wall-clock window, never against the span between the first and last message timestamp.
  Dividing by the span inflates the result whenever collection does not fill the window.
  One such reading suggested a 40% throughput gain that was really a backlog drain of exactly 1.5 cycles.

  The window must be an integer multiple of the collection interval.
  Collection arrives in bursts, with a measured peak-to-mean sample rate of 2.8 rising past 4.2 after a restart, so a window of 2.2 cycles captures two or three whole bursts depending on its phase.
  This is not a theoretical concern.
  The same fleet read 24,652 samples/s over a 660 s window and 22,036 over a 900 s window; the shorter window over-reported by 11.9%.
  Three earlier 660 s runs agreed with each other to within 4%, which looked like precision and was a shared phase bias.
  Repeatability at the wrong window size confirms nothing.

  Coverage, the timestamp span divided by the window, is bounded on both sides.
  Below the floor the window did not fill; above the ceiling it drained backlog.
  Either way the rate is not a sustained one.

  Gauges that spike faster than the sampling grid, such as pool occupancy and queue depth, are plotted as per-bucket peaks with `max_over_time`, because instantaneous samples alias the bursts to zero.
---

## Sustained rate {#sustained-rate}

Three thousand eight hundred and one simulated SNMP devices sustained 79.3 million metrics an hour, 22,036 samples per second, on one physical host.

The measurement window was 900 seconds, exactly three collection cycles, and produced 19,832,108 samples across 3,803 monitored nodes with no read warnings and complete node coverage. A second identical 900 s window returned 19,832,106 samples, two apart in nearly twenty million. That is a repeatability statement about one configuration, not a reproducibility statement about the benchmark.

The per-device arithmetic reproduces the measured figure exactly, which is why the fleet size can be read as a scaling reference. Each device presents 144 SNMP interfaces. Twelve numeric attributes are collected per interface: `ifHCInOctets` and `ifHCOutOctets` from `mib2-X-interfaces`, the six 64-bit unicast, multicast and broadcast packet counters from `mib2-X-interfaces-pkts`, and discards and errors in each direction from `mib2-interface-errors`. `ifName` and `ifHighSpeed` are declared as strings, so interface speed is stored as an attribute and never counted as a sample. One node-level group returns on this profile, `mib2-tcp` with ten attributes. That gives 144 x 12 + 10 = 1,738 samples per device per 300 s cycle, 20,856 per hour, and 79,273,000 across 3,801 devices.

| Step | Value |
|---|---:|
| SNMP interfaces per device | 144 |
| Numeric attributes per interface | x 12 |
| Interface samples per cycle | 1,728 |
| Node-level samples (`mib2-tcp`) | + 10 |
| Samples per device per 300 s cycle | 1,738 |
| Cycles per hour | x 12 |
| Metrics per device per hour | 20,856 |
| Devices | x 3,801 |
| Metrics per hour | 79,273,000 |

Three counts in this report are close but not the same number, and mixing them up is the easiest way to get the per-device figures wrong. 3,801 is the simulated devices nl6 was asked for. 3,803 is the monitored nodes in OpenNMS: those devices plus the Core's own localhost node and the Minion, which the requisition does not create. 3,805 is the collectable services Collectd reports, and the captured gauge sat flat on 3,805 for the entire window. The four extra services are collected over JMX rather than SNMP and return far more attributes per service than an interface walk does, so four services in 3,805 is not four samples in 3,805. Separating their share of the total needs the run's own sidecar, not the configuration.

Across the whole 57-hour window nothing drifted. Core averaged 23.7% busy across its eight vCPU and peaked at 29.3%. The load generator tracked it at 23.0%. The Minion averaged 12.0% and the database 11.5%. Every line is flat, and none approaches its ceiling, which is the claim the headline figures make in one picture.

{{figure cpu}}

## Headroom {#headroom}

Nothing in the stack was saturated at 79.3 million metrics an hour, and the components that had to be raised from stock were raised past their measured peaks rather than up to them.

**The Minion needs 4 vCPU, not 2.** The Minion executes every SNMP walk that Collectd's threads block on, so it is the RPC executor for the whole workload. It began the campaign at 2 vCPU and was raised to 4 on 27 August at 22:25 CEST, with the fleet held at 2,154 collectable services on both sides of the change, which makes the two halves of that evening directly comparable.

As a percentage the resize looks unnecessary, and that is the trap. CPU busy fell from 26.1% of two vCPU to 12.0% of four, which reads like a machine with twice the headroom. A percentage divides by exactly the quantity the resize changed, so identical work halves on the chart without anything having improved. Measured in cores, which does not move with the core count, the Minion drew 0.50 of a core before and 0.44 after. The same half core of work, and throughput did not move either. The absolute peaks went the other way: taking the highest value in each 10-minute bucket, median CPU demand rose from 0.85 cores to 0.96 and the worst case from 1.44 to 1.81. The work was always there. At 2 vCPU it could not all be dispatched at once, so it queued instead of running.

The run queue is the measure that does not move with the core count, which is why the figure below plots load average and the core count together. In the captured window the one-minute load stood above the two-core line in 17% of the 265 samples before the resize and reached 6.30, three runnable processes deep per core. After the resize it crossed the four-core line in 4 of 336 samples. The extra cores did not make the Minion do more; they gave the burst somewhere to land. At the final fleet size the Minion on 4 vCPU averages 0.49 of a core and peaks at 1.41 in a 10-minute bucket, a peak two cores would have to absorb with half the places to put it.

{{figure minion-load}}

**The Collectd pool needs 100 threads, and looks idle at every sample.** The thread count bounds how many collections can be in flight. With 2,154 collectable services on a 300 s interval, 50 threads leaves under 7 s per node, which a 144-interface walk does not meet: the cycle finished at 78% completion with 2,104 services queued. Because the threads block on Minion RPC round trips rather than on Core's CPU, a value well above the vCPU count is correct rather than a mistake. 100 is a safe value and not a measured optimum; at 200 the pool thrashed and starved Core's own RPC response consumer, taking the Minion's services down while the Minion itself sat idle.

Within nearly every 10-minute bucket the pool touches its 100-thread ceiling and briefly queues up to 113 tasks, then drains completely. How idle it looks is worth stating precisely. Sampled instantaneously across the whole window, the way the Thread Pool panel plots it, the active-thread gauge returned zero on all 343 captured readings, while the 10-minute peak of that same gauge sat pinned between 83 and 100. An operator watching the panel would conclude the pool was never used.

{{figure collectd}}

**The database pool needs 250 connections and used 87.** At the stock ceiling of 50 the pool sat pinned at 50 active with up to 127 threads queued on every collection cycle, which is Collectd blocking on connection acquisition rather than on the database. Raised to 250, collection bursts drove it to peaks of up to 87 concurrent connections. Waits still appeared occasionally, peaking at 24 threads awaiting a connection for one bucket. The configured ceiling was never approached, which is the margin the raise bought. The same sampling caveat applies: read instantaneously the active gauge has a median of 1 and a mean of 1.2, against a 10-minute peak whose median is 46. A pool that repeatedly touches 87 connections looks like a pool nobody is using.

{{figure db-pool}}

**Heap and memory were never the constraint.** The 8 GiB heap cycled between 2.92 and 7.55 GiB in a regular G1 sawtooth, mean 5.44 GiB. It filled and was reclaimed on every cycle for 57 hours without drift.

{{figure heap}}

Used memory on the Core VM held between 9.88 and 10.10 GiB of the VM's 15.62 GiB for the whole window. A flat line over 57 hours of sustained collection is the evidence that memory neither leaks nor needs to scale here.

{{figure mem}}

Garbage collection is a rounding error at this rate. Young-generation collections cost 0.649 to 0.830 seconds of pause work per minute of wall clock, about 1.2% of the time budget, and the concurrent collector between 0.013 and 0.028. The old-generation collector never ran in the entire window.

{{figure gc}}

**Thread accounting shows stability, not demand.** Roughly 1,010 JVM threads ran flat for 57 hours: about 460 waiting, 330 in timed waits, 230 runnable and at most one blocked. The RUNNABLE figure is the JVM's own accounting, which counts threads sitting in native I/O waits, and is not CPU demand, as the 23.7% CPU line above shows. The evidence here is the absence of drift: no thread leak, no lock contention, nothing moving across two and a half days.

{{figure threads}}

**The database is not the constraint under exclusive Kafka forwarding.** Metrics bypass PostgreSQL entirely, so the database VM stayed at 11.5% busy on average across the window, the least loaded component in the lab apart from the broker. Its 8 vCPU is sized for provisioning and node-scan bursts, not for steady-state collection, and the PostgreSQL tuning matters because the packaged defaults would throttle those bursts, not because collection is heavy on it.

## Three hours at one-minute resolution {#three-hours}

A one-minute view does not contradict the ten-minute buckets, but it does change the maxima, and only the maxima.

Every figure above is a 10-minute bucket across 57 hours, which is the right resolution for showing that nothing drifts and the wrong one for showing what a minute actually looks like. This section takes a steady-state slice from the middle of the window, 30 August 00:00 to 03:00 CEST, and samples it the way the dashboards do, with the panels' own expressions at one-minute steps.

| VM | vCPU | busy, mean | busy, max | user | system | irq + softirq | iowait |
|---|---:|---:|---:|---:|---:|---:|---:|
| core | 8 | 23.6% | 73.9% | 18.2% | 3.1% | 1.5% | 0.00% |
| loadgen | 2 | 23.2% | 69.8% | 16.7% | 2.0% | 3.3% | 0.00% |
| minion | 4 | 12.2% | 39.9% | 8.9% | 1.6% | 1.0% | 0.00% |
| database | 8 | 11.7% | 43.0% | 6.5% | 2.9% | 1.5% | 0.05% |
| kafka | 2 | 10.4% | 17.9% | 4.7% | 3.0% | 1.2% | 0.22% |

The means match the 57-hour figures. The maxima do not: Core averages 23.6% here against the 23.7% the full window reports, but at one-minute resolution it reaches 73.9% of its eight vCPU, a spike the 10-minute grid flattens to 29.3%. Every spike lands on a collection-cycle boundary and none is sustained. Nothing is I/O bound: iowait rounds to zero on three VMs and reaches 0.22% on the broker, the only VM doing sustained disk writes. The work is user-space on every machine, and the load generator spends more of its budget in irq and softirq than anything else does, because it is answering 22,000 UDP round trips a second from a single 2 vCPU box.

{{figure cpu-3h}}

The wire is the cheapest part of the system. The whole SNMP workload is 11.2 Mbit/s: collecting 79.3 million metrics an hour from 3,801 devices costs less on the wire than a single video stream. The largest flow in the lab is not the collection at all. The Minion returning RPC responses to Kafka averages 36.3 Mbit/s on its broker link, and Core's broker link 52.2, roughly three to five times what the SNMP itself weighs. The ratio is the part worth carrying away: the transport costs more than the telemetry. Nothing on any segment approaches a gigabit bridge's capacity, and none of the four links drifts across the sample, so it is the ordering rather than the magnitudes that transfers to a real deployment.

One measurement note. A one-minute rate range aliases the collection burst and turns four flat lines into spikes of three times their mean, so these series use a five-minute rate range at a one-minute step. Both ends of every bridge agree to two decimals, which is what makes the interface mapping a measurement rather than an assumption: the lab does not label its NICs by segment, so which `enp6s*` belongs to which bridge was established by matching throughput across the wire.

{{figure net-3h}}

## Network layout {#network}

Four isolated Linux bridges with no physical uplink, plus the host's own uplink for external access. Each role is attached only to the segments it needs.

| Bridge | Subnet | Attached, with host octet | Carries |
|---|---|---|---|
| mgmt | 192.0.2.192/26 | core .200, database .196, kafka .204, minion .208, monitoring .212, loadgen .216 | SSH and the Prometheus scrape |
| db | 192.0.2.0/26 | core .8, database .4 | JDBC queries and result sets |
| kafka | 192.0.2.64/26 | core .72, kafka .76, minion .80, monitoring .84 | the metrics topic and all RPC, both directions |
| sim | 192.0.2.128/26 | minion .144 (routes 10.42.0.0/16), loadgen .152 (nl6 owns the simulated range) | SNMP GetBulk out, agent responses back |
| external | host uplink | monitoring, DHCP | the only VM reachable from outside |

Read left to right, this is the path one sample takes. SNMP crosses exactly one virtual bridge, between the Minion and the simulated agent, which is why the round trips Collectd's threads block on are measured in microseconds here and would not be in a routed network. The simulated devices live in 10.42.0.0/16, routed from the Minion's sim interface to nl6, which owns that range inside its own network namespace. Everything between the Minion and Core is Kafka, so the broker is both the transport and the only place the benchmark can be read. The database sits off the sample path entirely.

Pinning the requisition to the Minion's location is not cosmetic for the same reason. The simulated network is reachable from the Minion and from nowhere else, so a node that landed in the default location would be polled from Core and would never answer. Every node in the `nl6-pm-72m` requisition carries `location="lab-location-01"`.

## Where the graphs come from {#graphs}

Every figure in this report is rendered from the lab's own monitoring, read through the same queries that drive the Grafana dashboards Node Exporter Full, Prometheus: Java Virtual Machine and Prometheus: OpenNMS Core Internals. The exact expression, absolute range and step sit under each figure, and each figure carries its data as an hourly table.

One figure is deliberately outside the observation window. The Minion sizing chart covers 27 August, because the resize it documents happened before the measured run began and cannot be seen from inside the window.

One simulator defect is worth knowing about, because it depresses the per-device count slightly. In the CRS-X profile the OID for `freeMem` returns the device name as a string where the MIB requires a gauge, so OpenNMS logs a conversion error on every poll of every device and never collects that attribute. At this fleet size that was roughly 14 errors per second. Reported upstream as nl6#515.

PoweredBy 2026 is the same codebase as OpenNMS Horizon 36.0.3 in a different distribution. Both names appear here by design: the product is named where the deployment is meant, and the upstream name where a file, property, daemon or dashboard title carries it verbatim. `opennms.conf`, `opennms-datasources.xml` and the `org.opennms.*` properties are what the running system reads, and the daemons keep their upstream names. Every figure transfers between the two distributions without adjustment.
