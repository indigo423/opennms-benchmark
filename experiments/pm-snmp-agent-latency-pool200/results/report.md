---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent response time · 200 threads"
title: "At 50 to 100 ms per PDU,<br>200 threads carry 5,000 devices"
lede: "Doubling the Collectd pool from 100 to 200 threads moved the knee from 2,500 to 3,000 devices up to 5,000 to 5,250, and doubled the collection rate the collector can sustain from 8.8 to 17.5 a second. The processor was still three-quarters idle at the failure. The failing rung does not collapse: it falls 85 collections an hour short and the backlog grows by exactly that."
verdict:
  - { k: "Knee", v: "5,000 to 5,250", n: "devices at 50 to 100 ms per PDU, 200 threads", hero: true }
  - { k: "Throughput ceiling", v: "17.50/s", n: "collections, 2.0x the 8.78/s at 100 threads" }
  - { k: "Core CPU at the knee", v: "28.6%", n: "of 8 vCPU: still thread-bound" }
  - { k: "Shortfall at 5,250", v: "85/h", n: "collections not done, 0.14%, compounding" }
  - { k: "Metric rate at 5,000", v: "103.7M/h", n: "28,822 samples a second, 1,738 per device per cycle" }
caveats: |
  This is a single search on one deployment, one 900 s window per rung, three cycles each, with no repetition.
  The step is 500 devices to 5,000 and 250 above it, so the knee is bracketed to within 250 and not located more finely.
  The 4,000 rung ran under an earlier pass criterion and was re-judged when that criterion was replaced; the change and its reason are in the method section.
  The overnight hold was not a designed experiment: the driver stopped at the failing rung and the fleet was left running for 7.75 h with nothing else in flight, which is what makes it clean.
  The injected latency is uniform between 50 and 100 ms on every response packet, a clean approximation of a real SNMP agent that must consult line cards or the control-plane CPU, and not a measurement of any particular device.
method: |
  The latency injection is the one used for the 100-thread search, `tc qdisc replace dev enp6s19 root netem delay 75ms 25ms` on the simulator, which netem renders as a uniform 50 to 100 ms per packet.
  It was verified then with 200 probes (minimum 50.6 ms, median 76.0, maximum 99.8) and was confirmed present before every rung here.

  The pool size comes from the sweep that preceded this search, at a fleet of 3,000: throughput plateaued from 200 threads and involuntary context switches rose monotonically above it, from 34 a second at 200 to over 2,000 at 350.
  200 was the largest pool with nothing to lose.

  The search grew the fleet from 4,000 in steps of 500 to 5,000 and then 250, and stopped at the first rung that failed.
  Before each window opened, the rung's nodes were reconciled against the database, every node holding exactly 144 SNMP interfaces and none unscanned, then provisiond was observed idle and a further 300 s settle elapsed.

  Each rung is one 900 s window, three collection cycles.
  The pass criterion is two-part and both parts are required: the pending queue must return to zero inside the window, and the window integral of Collectd's completed-task counter must reach 97% of the collections the fleet requires in 900 s.
  This differs from the 100-thread search, which judged the median of the completion-ratio gauge; the reason for the change is in the method section, and the earlier search's verdicts are unchanged under the new rule.

  Every figure is a Prometheus `query_range` at the 15 s scrape interval.
  The search figures span all four rungs on one axis; the overnight figure carries its own 7.75 h window.
  Collectd's own JMX gauges carry the finding; Node Exporter supplies CPU and network as the control.
  Rates are window integrals of the completion counter over an integer number of cycles.
---

## The knee {#the-knee}

**Between 5,000 and 5,250 devices.** 5,000 completes its cycle with the pass criterion met and a little to spare; 5,250 does not, and the way it fails is the interesting part.

| Fleet | Queue at zero | Queue, median | Pool, mean of 200 | Collections done / required | Verdict |
|---:|---:|---:|---:|---:|---|
| 4,000 | 33% of samples | 396 | 141 | 99.2% | pass |
| 4,500 | 25% of samples | 638 | 166 | 99.8% | pass |
| 5,000 | 25% of samples | 573 | 184.5 | 99.4% | pass |
| **5,250** | **never** | **952** | **200.0** | 99.9% | **fail** |

The queue is the clearest signal. At 4,000 through 5,000 it returned to zero every cycle, in a quarter to a third of the samples, and the pool still had slack between bursts. At 5,250 the pool sat at 200 in every one of the 61 samples and the queue never emptied.

{{figure queue}}

What is different from the 100-thread knee is the completion column. At 3,000 devices with 100 threads the failing rung completed 87.6% of its collections, a fleet plainly beyond the collector. At 5,250 with 200 threads the failing rung completed 99.9%. Every task that ran, finished; the pool simply cannot start quite enough of them. That is a collector running at exactly its capacity, and the difference between 99.9% and 100% is what the next section measures.

{{figure completion}}

The completion-ratio gauge in that figure is shown because it is what the dashboards show, not because it decides anything here. Its median at 5,250 (0.9913) is higher than at 4,000 (0.9854), a passing rung. It is a sawtooth whose median depends on where the window falls in the cycle, and it is the reason the pass criterion changed.

## Why 5,250 fails slowly {#the-slow-fail}

**The collector is 85 collections an hour short, and the backlog grows by exactly that.** After the search stopped, the fleet was left at 5,250 overnight with nothing else running. Over 7.75 hours the pool completed between 62,949 and 62,973 collections in every full hour against the 63,048 the fleet requires. The shortfall never varied by more than 25 tasks an hour, and the queue floor climbed with it.

{{figure overnight}}

| Hour, UTC+2 | [Collections done]{.fx title="increase(opennms_collectd_taskscompleted[1h]) at the end of the hour; the last row uses [2700s]"} | [Required]{.fx title="opennms_collectd_collectableservicecount / 300 × seconds in the row: 5,254 / 300 × 3,600 = 63,048"} | [Shortfall]{.fx title="required − done"} | [Queue floor at start]{.fx title="min of opennms_collectd_taskqueuependingcount over the hour"} |
|---|---:|---:|---:|---:|
| 01:30 to 02:30 | 62,962 | 63,048 | 86 | 41 |
| 02:30 to 03:30 | 62,972 | 63,048 | 76 | 116 |
| 03:30 to 04:30 | 62,968 | 63,048 | 80 | 185 |
| 04:30 to 05:30 | 62,965 | 63,048 | 83 | 286 |
| 05:30 to 06:30 | 62,973 | 63,048 | 75 | 352 |
| 06:30 to 07:30 | 62,951 | 63,048 | 97 | 427 |
| 07:30 to 08:30 | 62,949 | 63,048 | 99 | 514 |
| 08:30 to 09:15 | 47,234 | 47,286 | 52 | 598 |

The cumulative shortfall over the hold is 645 collections; the queue floor rose from 41 in the first hour to 656 at the end. The two numbers are the same number, which is the point: nothing was lost, nothing timed out, and no thread stalled. The pool delivers 62,960 collections an hour, which is 5,247 services per 300 s cycle, and the fleet asks for 5,254. That is the capacity of 200 threads at this latency, located to a handful of devices by seven hours of arithmetic rather than by a finer search.

It is a slow failure, and it would not stay slow. A backlog that grows 80 tasks an hour is a fleet whose collection times drift later each cycle, and at some depth the scheduler stops delaying collections and starts skipping them. Where that depth is was not measured. At 5,000, the last passing rung, the queue returned to zero every cycle and none of this happens.

## Metric rate {#metric-rate}

**103.7 million metrics an hour at 5,000 devices, the last rung that completes its cycle.** Collectd finished 14,925 collections in that rung's 900 s window against the 15,012 that 5,004 collectable services on a 300 s interval require, 99.4% of the required rate, and every fleet collection carries 1,738 numeric samples. At 5,250 the pool's ceiling of 62,960 collections an hour is 109.4 million metrics an hour, and that is the most this collector can deliver at this latency, whatever the fleet size.

| Step | 5,000 devices, last pass | 5,250 devices, 7.75 h hold |
|---|---:|---:|
| Collectable services | [5,004]{.fx title="opennms_collectd_collectableservicecount: 5,000 fleet devices + Core and Minion carrying 2 services each"} | [5,254]{.fx title="opennms_collectd_collectableservicecount: 5,250 fleet devices + Core and Minion carrying 2 services each"} |
| Collection interval | 300 s | 300 s |
| Collections per second required | [16.680]{.fx title="5,004 services / 300 s"} | [17.513]{.fx title="5,254 services / 300 s"} |
| Collections completed in the window | [14,925 in 900 s]{.fx title="increase(opennms_collectd_taskscompleted[900s]) at the end of the rung window, 23:01:58Z"} | [487,974 in 27,900 s]{.fx title="sum of increase(opennms_collectd_taskscompleted[1h]) over the eight hours of the hold, 23:30Z to 07:15Z = 93 cycles"} |
| Collections per second achieved | [16.583]{.fx title="14,925 / 900 s"} | [17.490]{.fx title="487,974 / 27,900 s"} |
| Samples per collection, decoded from the wire | [1,738]{.fx title="numeric attributes per CollectionSet record on the metrics topic; 27,163 of 27,183 records in the live capture carried exactly this"} | [1,738]{.fx title="same decode"} |
| **[Samples per second]{.fx title="achieved collections/s × samples per collection"}** | **[28,822]{.fx title="16.583 × 1,738"}** | **[30,398]{.fx title="17.490 × 1,738"}** |
| **[Metrics per hour]{.fx title="samples/s × 3,600"}** | **[103,758,600]{.fx title="14,925 / 900 × 1,738 × 3,600"}** | **[109,432,105]{.fx title="487,974 / 27,900 × 1,738 × 3,600"}** |
| [Metrics per five-minute cycle]{.fx title="samples/s × 300, i.e. what one cycle actually delivered, not what the fleet asks for"} | [8,646,550]{.fx title="14,925 / 900 × 1,738 × 300 = 4,975 collections per cycle × 1,738"} | [9,119,342]{.fx title="487,974 / 27,900 × 1,738 × 300 = 5,247 collections per cycle × 1,738"} |

The 1,738 is not carried over from the cleanroom report; it was read again from this fleet's wire. The live capture at 5,250 decoded 27,183 consecutive records from the `metrics` topic over 1,560 s: 27,163 carried exactly 1,738 numeric samples across 148 resources, and the remaining 20 were the Core's and the Minion's own JMX and JDBC collections, four services over five cycles. The composition is the one the cleanroom report set out, 1,728 interface counters on 144 interfaces plus ten node, BGP and temperature attributes, so the fleet figure is really a 720,000-interface figure at 5,000 devices and transfers to other devices only at the same interface density.

The topic count is also an independent check on the daemon's counter. 27,183 records in 1,560 s is 17.43 collections a second on the wire against 17.49 from the counter over the hold, 0.4% apart on a window that is not an integer number of cycles. What Collectd says it completed is what Kafka received.

{{figure metric-rate}}

The figure is the completion counter multiplied by 1,738, against the fleet's requirement multiplied by the same. The two lines separate at 5,250 by a margin the axis cannot show, 0.14%, which is the whole finding of the previous section: the metric rate at the knee is not a cliff but a ceiling, 30,400 samples a second, that the fleet's demand has just crossed. Against the cleanroom's 81,134 samples a second at 14,000 devices with the agents answering in 0.1 ms, this deployment delivers 37% of the metric rate with 100% of the same hardware, because 200 threads waiting 75 ms per PDU can start only so many collections.

## What runs out, and what does not {#what-runs-out}

**Threads run out, at twice the fleet size it took with 100 of them. Nothing else does.**

{{figure threads}}

The pool reaches 200 in bursts from 4,000 onward and holds it in every sample at 5,250. The rolling mean climbs 141, 166, 184.5, 200 across the rungs, which is the fleet filling the pool one step at a time, and the throughput counter is what shows the ceiling is real rather than a gauge artefact. Collections completed per second: 13.24 at 4,000, 14.98 at 4,500, 16.58 at 5,000, **17.50 at 5,250**. Each rung gained less than the last, and 17.50 is 2.0 times the 8.78 the 100-thread pool topped out at.

{{figure throughput}}

The arithmetic from the 100-thread report closes again. A collection of this device holds a thread for 987 + 135 × 75 ≈ 11.1 s at a 75 ms mean delay. Two hundred threads at 11.1 s each is 18.0 collections per second, and the measured ceiling is 17.50, 3% under. The model predicted the 200-thread knee at 5,400 before this search ran; the search found it at 5,250.

**The processor was still a bystander.** Core CPU was 22.9% at 4,000, 25.1% at 4,500, 27.5% at 5,000 and 28.6% at the failure. It rises with the fleet because there is genuinely twice the work of the 100-thread search, and it stops at 28.6% because a thread waiting on a socket costs nothing. Seventy percent of the Core is idle at the knee.

{{figure cpu}}

The JVM was checked and was not a factor. Heap cycled between 3.1 and 9.5 GiB under the 10 GiB ceiling, and there was not a single old-generation collection in any of the four rungs. The Full GC that was the ceiling at 14,000 devices in the cleanroom does not appear at a third of that fleet.

{{figure jvm}}

The Minion, which executes the walks the Core's threads wait on, ran at 12.6% to 16.9% of four vCPU and carried 11.6 to 15.3 Mbit/s on the SNMP bridge, twice the 100-thread search's load and still nowhere near a limit.

{{figure minion}}

## What doubling the pool bought {#against-100}

**The fleet doubled, the throughput doubled, and the constraint did not move.** The 100-thread search and this one were run on the same Core, the same latency, the same fleet profile and the same interval; only the pool changed.

| | 100 threads | 200 threads | Ratio |
|---|---:|---:|---:|
| Last rung completing a cycle | 2,504 services | 5,004 services | 2.00 |
| First rung failing | 3,004 | 5,254 | 1.75 |
| Throughput ceiling | 8.78/s | 17.50/s | 1.99 |
| Core CPU at the last pass | 16.6% | 27.5% | 1.66 |
| Core CPU at the failure | 15.9% | 28.6% | 1.80 |
| Collections done at the failing rung | 87.6% | 99.9% | |
| What was the constraint | the thread pool | the thread pool | |

The ratios are the finding. Throughput scaled at 1.99 for a pool ratio of 2.00, which is what a purely thread-bound collector does. CPU scaled at less than the work did, because the marginal thread costs nothing while it waits. And the failing rung landed at 5,254 rather than the 6,000 that 2 × 3,000 would suggest only because the 100-thread search stepped by 500 and overshot its knee; the 250 step here landed closer.

The lever is the same one as before and it is not exhausted by this result. Between 200 and 400 threads the pool sweep found throughput flat and involuntary context switches climbing, but that was at 3,000 devices, a fleet the 200-thread pool was not full for. At 5,250 the pool is full in every sample and 70% of the processor is idle, which is the same picture the 100-thread report drew at 2,500. Whether 300 threads carry 7,500 devices on this Core, or whether the context-switch cost the sweep saw at 3,000 becomes real when the pool is actually busy, is the next experiment and not a conclusion of this one.

## How it was done {#how-it-was-done}

The injection is unchanged from the 100-thread search: one `netem` qdisc on the simulator's `enp6s19`, `delay 75ms 25ms`, uniform between 50 and 100 ms on every packet leaving the simulator. The driver asserted its presence before opening a window.

The fleet was grown from the 3,000 the pool sweep had held, to 4,000, then in steps of 500 to 5,000 and 250 beyond. Each growth step was provisioned through the existing requisition, and the driver refused to open a window until the database showed exactly nodes × 144 interfaces with no node unscanned. Per rung: the new nodes scanned in 11 to 14 minutes at the stock 10-thread provisiond pool, provisiond observed idle, 300 s settle, 900 s window. Four rungs between 23:39 and 01:28 UTC+2 on the night of 3 to 4 September, with two interruptions: one between the first and second rung for the criterion change below, and one between the second and third when the driver crashed on a logging line after it had written the 4,500 record. Neither touched the fleet or the measurements; each rung's window opened after its own reconciliation and settle.

**The pass criterion changed after the 4,000 rung, and this is why.** The 100-thread search judged each rung on two conditions: the queue returns to zero inside the window, and the median of Collectd's completion-ratio gauge is at least 0.99. At 4,000 devices with 200 threads the queue drained, the completed-task counter integrated to 99.2% of the required collections, and the ratio median came out at 0.9854. The driver declared a knee. That was wrong, and the gauge was the reason: it is a sawtooth that climbs from about 0.96 to 1.00 across every cycle and resets, so its median inside a 900 s window is a statement about where the window sat in the cycle, not about how many collections completed. The criterion was replaced with the counter integral, which is a wall-clock rate and cannot be phased: the queue must drain, and the counter must reach 97% of required. The 4,000 rung was re-judged a pass on its existing data, the three later rungs ran under the new rule, and every rung of the 100-thread search keeps its verdict under it (the failing rung there completed 87.6%).

The overnight numbers are `increase(opennms_collectd_taskscompleted[1h])` evaluated at each hour boundary and the minimum of the pending-queue gauge in the same hour, from 01:30 to 09:15 UTC+2 on 4 September, ending before a live capture was armed on the same hosts. The driver stopped itself at the failing rung and the fleet was held at 5,250 with the latency still applied.
