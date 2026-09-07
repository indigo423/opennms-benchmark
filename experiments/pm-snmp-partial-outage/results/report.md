---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · resilience · partial outages"
title: "A dead device is the cheapest device:<br>25, 50, 75 and 100% of the fleet unreachable"
lede: "A quarter, a half, three quarters and all of an 11,000-device fleet were made unreachable in turn, silently, on the 16 GiB deployment, each for three collection cycles. Every resource on the Core, the Minion and the database fell in proportion to the dead share, the thread pool ran lighter rather than fuller, the queue never held a task, and the healthy remainder was collected on time at every level, delivering a share of the metrics stream within a few points of what it should. Recovery from the first three levels took one cycle; the fourth was interrupted by a restart from outside the experiment, which left 4,404 alarms with no collector state to clear them. The outage that costs a collector is not the device that is gone; it is the device that is slow, and that one was not in this series."
verdict:
  - { k: "Core CPU by dead share", v: "62 → 52 → 37 → 20 → 8%", n: "at 0, 25, 50, 75 and 100% unreachable", hero: true }
  - { k: "Threads busy", v: "190 → 129", n: "of 250: a dead device holds a thread 3.6 s, a live one 5.4 s" }
  - { k: "Queue at zero", v: "100%", n: "of every level's window; nothing queues behind a failure" }
  - { k: "Delivered by the remainder", v: "78 / 57 / 34 / 12%", n: "of the healthy metrics stream at 25 / 50 / 75 / 100% dead, against 75 / 50 / 25 / 0 expected" }
  - { k: "Recovery per level", v: "1 cycle", n: "at 25, 50 and 75%; the 100% recovery was cut by an external restart that orphaned 4,404 alarms" }
caveats: |
  Every dead device fails on its first PDU after one timeout and one retry. A slow or half-answering device holds a thread through up to 61 timeouts; that outage loads the pool and it was not run. The levels were applied to whole /24 blocks, in ascending order, once each, with two recovery cycles between.
  The deployment is the 16 GiB Core at its balanced fleet, with 40% of CPU and a quarter of the pool spare; every level here made it lighter. What a Core at its knee would feel is the recovery burst, not the outage.
  Delivered work is the Core's transmit to Kafka against the healthy baseline; that link also carries the small, constant RPC requests, which is why the delivered share reads a few points above the expected share at every level. The 50% level was run twice: the first attempt was cut short by a timing mistake after six minutes and its window discarded.
method: |
  The deployment is the 16 GiB shape of `kfk-exclusive` re-established the same morning and judged healthy: 11,000 nl6 devices at `netem delay 75ms 25ms`, `max-repetitions=5`, Collectd `threads="250"`, a 10 GiB heap on G1, SNMP timeout 1,800 ms with one retry. The healthy baseline window is 11:00 to 11:15 UTC.

  Each level drops whole /24 blocks of 250 devices on netsim's FORWARD chain ahead of the rule that carries SNMP into the simulator's namespace, so the requests of the dead blocks are dropped without ICMP: 11 blocks for 25%, 22 for 50%, 33 for 75%, all 44 for 100%. A probe from the Minion confirmed the boundary at each level. A level is held three collection cycles and judged over its second and third by `bin/judge.py`: collections per second from the completion counter's raw samples, busy threads, queue, CPU on the three machines, heap, and delivered work as the Core's transmit to Kafka against the baseline. The level is then removed and two cycles pass before the next. `bin/monitor.py` logs one line a minute throughout, with the events and alarms tables read from the database because eventd and alarmd publish no counters.
---

## The shape {#the-shape}

**Linear in the dead share, and downward on every machine.**

| Unreachable | Dead devices | Coll./s | Threads busy | Queue at zero | Core CPU | Minion CPU | DB CPU | Core core-s per coll. | Metrics out | Delivered share | Expected share | Heap | Core load |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0% | 0 | 36.66 | 190 | 92% | 62.1% | 28.6% | 27.4% | 0.1356 | 47.6 Mbit/s | baseline | 100% | 8.6 GiB | 12.4 |
| 25% | 2,750 | 36.63 | 162 | 100% | 52.3% | 23.3% | 22.8% | 0.1141 | 37.4 Mbit/s | 78% | 75% | 7.9 GiB | 9.9 |
| 50% | 5,500 | 36.92 | 147 | 100% | 36.5% | 17.1% | 15.5% | 0.0791 | 27.0 Mbit/s | 57% | 50% | 7.7 GiB | 4.5 |
| 75% | 8,250 | 36.58 | 139 | 100% | 20.4% | 9.8% | 8.2% | 0.0445 | 16.0 Mbit/s | 34% | 25% | 6.7 GiB | 2.4 |
| 100% | 11,000 | 36.61 | 129 | 100% | 8.4% | 4.0% | 2.8% | 0.0184 | 5.5 Mbit/s | 12% | 0% | 6.1 GiB | 1.4 |

Table: `bin/render_levels.py` over `levels.jsonl`; each row is one ten-minute window over the level's second and third cycle. Dead devices are 110 per percentage point.

{{figure cpu}}

The Core's CPU falls from 62% to 8% across the four levels, in four nearly equal steps, and the Minion's and the database's fall with it. A collection that gets no answer times out on its first PDU after 3.6 s and returns a failure: the Minion marshals nothing, the Core decodes nothing, stores nothing and looks up no node per resource, and the producer sends nothing to Kafka. Per collection the Core's cost reads 0.136 core-seconds with every device alive and 0.018 with every device dead, the second number being the scheduler, the RPC round trip and a log line.

{{figure threads}}

The pool runs lighter, not fuller: 190 busy threads at 0%, 129 at 100%. The thread time of a dead device, 3.6 s, is two thirds of a live one's 5.4 s at this latency, so each dead block returns threads to the pool. This is the property that makes the fleet safe against dead devices and would make it unsafe against slow ones, where the same thread waits 3.6 s per PDU for up to 61 PDUs.

{{figure heap-gc}}

The heap follows the in-flight state, 8.6 GiB at 0% and 6.1 at 100%, and no old-generation collection ran at any level.

## The remainder {#the-remainder}

**The healthy devices are collected on time at every level.** The completion counter never leaves the fleet's demand, because a failed collection counts as completed and is rescheduled for its interval like any other; the queue floor stays at zero for the whole window at every level, so no live device waits behind a dead one.

{{figure throughput}}

{{figure queue}}

The Core's metrics stream to Kafka is the measure of what the remainder delivers: 78% of the healthy baseline with a quarter of the fleet dead, 57% with half, 34% with three quarters, 12% with all of it. The expected shares are 75, 50, 25 and 0; the constant few points above them are the RPC requests on the same link, which do not shrink. Within that offset the delivered share is the live share, at every level.

{{figure delivered}}

## The event path {#the-event-path}

**One failure event and one major alarm per dead device in the level's first cycle, one success event and one clear per device in the recovery's first cycle, and nothing in between.** The monitor's per-minute reads of the events table show the burst of each level completing inside five minutes, 2,750 to 11,000 events at about 2,300 a minute, and no further failure events for the rest of the level; a service that is already failed does not raise again. Recovery after each level reversed it in the same span: at the 100% level the last of the 11,000 clears landed in the second recovery cycle, as in the earlier full-outage test. The database's CPU shows the bursts as nothing above its per-level floor.

**Recovery after the 100% level was interrupted by an Ansible run, not by the outage.** The fleet came back at 15:30:25 and 6,595 services logged their success in the next three minutes, on the same curve as the earlier full-outage test. At 15:33:19 an Ansible session as the deployment user connected to the Core and restarted OpenNMS, seventy seconds of JVM start and a full reload of the 11,004 services. The collector that came up had no memory of which services were failed, so it raised no success event for the 4,404 that had not yet recovered, and their major alarms stayed open with nothing left to clear them: an orphaned alarm per interrupted recovery is what a restart in the middle of an outage costs. The two windows after the restart carry its scheduling wave, 250 threads busy and a queue peak of 230, and are not a recovery measurement; the clean one-cycle recovery from a full outage on this deployment is the earlier report's, `pm-snmp-outage`.

## Where it stops {#where-it-stops}

**This series measured dead devices. Slow devices are a different experiment, and the expensive one.**

- A device that answers some tables and not others, or answers late, holds a collection thread through a timeout per unanswered PDU: 61 × 3.6 s in the worst case against the single 3.6 s here. A fleet in which a quarter of the agents are slow rather than gone could hold the whole 250-thread pool with the remainder waiting behind it. That is the outage that loads a collector, and the one to run next.
- The steps here are whole /24 blocks; a real outage takes a site or a link, which is also a block. A random quarter of the fleet would spread the failures through the schedule the same way.
- The Core had 40% of its CPU spare. Every level made it lighter, and the only burst a Core at its knee would feel is the recovery cycle: one success event and one alarm clear per returning device on a processor at 96%.
- Alarm reduction ran against an alarms table that held only this series' alarms. A deployment carrying tens of thousands of standing alarms reduces each burst against them.
