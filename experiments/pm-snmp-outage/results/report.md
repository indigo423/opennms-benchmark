---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · resilience · full agent outage"
title: "Fifteen minutes without a single agent,<br>one cycle to recover"
lede: "Every SNMP request from the Minion was dropped silently for three collection cycles on the 16 GiB deployment at 11,000 devices. The collector kept its rhythm, because a collection that times out is a completed task; the Core's processor fell to 12% with nothing to decode; the event path raised one failure event and one major alarm per service in the first cycle and then went quiet. When the fleet came back, 10,080 services had logged a success within five minutes, the last 858 in the next cycle, every alarm was cleared in the same five minutes, and both 15-minute windows after the restore pass the knee search's rule with the numbers of the window before it."
verdict:
  - { k: "Recovery", v: "1 cycle", n: "10,080 of 11,000 services succeeded within 5 min of the restore, the rest in the next cycle", hero: true }
  - { k: "Alarms", v: "11,000 → 0", n: "raised in the first outage cycle, cleared in the first recovery cycle" }
  - { k: "Core CPU in the outage", v: "12%", n: "against 61% before and 60% after: a failed collection decodes nothing" }
  - { k: "Completion after", v: "100.0%", n: "36.67 collections/s against 36.68 required, 10:45 to 11:00" }
  - { k: "Samples lost", v: "57M", n: "estimated: 33,000 collections at 1,738 samples, never taken" }
caveats: |
  One outage, 15 minutes, total and silent, on a fleet that leaves the Core 40% of its CPU. A partial outage holds threads longer and was not run; the same recovery burst on the 32 GiB Core at its knee would land on a processor at 96%.
  The event and alarm counts are read from the database once a minute, because eventd and alarmd expose no counters. The alarms table was empty before the outage and the events table already held 14.7 million rows from earlier syslog experiments.
  The window before the outage is the deployment's own health check of the same morning, taken 30 minutes earlier with the same rule.
method: |
  The deployment is the 16 GiB shape of `kfk-exclusive` as re-established the same morning: 11,000 nl6 devices at `netem delay 75ms 25ms`, `max-repetitions=5`, Collectd `threads="250"`, a 10 GiB heap on G1, SNMP timeout 1,800 ms with one retry, Kafka RPC TTL at its 20 s default.

  The outage is a silent drop. At T0, 10:28:02 UTC, the forwarding rule that carries SNMP into the simulator's namespace on netsim was removed, so every request from the Minion was dropped without ICMP and every PDU ran to its timeout and retry; a probe from the Minion confirmed the timeout. At T1, 10:43:12 UTC, the rule was restored and the probe answered at once. `bin/monitor.py` logged one line a minute: the collector's gauges and rates from Prometheus, CPU on the Core, Minion and database, heap and old-generation collections, SNMP traffic on the Minion's link, and from the database the events of the last minute by kind and the alarms open. The REST API was probed from the monitoring host during the outage.

  Rates are window integrals of the completion counter from its first and last raw sample inside a 15-minute window. The pass rule is the knee search's: the queue returns to zero inside the window and the completed count reaches 97% of the services due. The window before is 10:00 to 10:15, the windows after 10:45 to 11:00 and 11:00 to 11:15.
---

## The verdict {#the-verdict}

**It survives, and it comes back on its own within one collection cycle.** Three cycles without an agent cost the deployment three cycles of samples and nothing else: no queue, no backlog, no growth in heap, no lingering alarm, and the two windows after the restore read like the window before it.

| Window | Coll./s | Completion | Queue empty | Queue peak | Threads | Core | Old GC | Verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Before, 10:00 to 10:15 | 36.65 | 99.9% | 93% | 33 | 191 | 61.1% | 0 | pass |
| After, 10:45 to 11:00 | 36.67 | 100.0% | 93% | 32 | 190 | 59.8% | 0 | pass |
| After, 11:00 to 11:15 | 36.66 | 99.9% | 92% | 56 | 190 | 61.9% | 0 | pass |

Table: `trial.py` records; the window before is `class16g-11000-threads250-g1` in the sizing-rule experiment, the two after are `trials.jsonl` here.

{{figure throughput}}

The completion counter never leaves the fleet's demand, and that is the first thing to understand about the outage: Collectd counts a collection that failed as a task completed, reschedules the service for its next interval, and moves on. The queue is untouched.

{{figure queue}}

## During the outage {#during-the-outage}

**A failing collection is cheaper than a working one on every resource but one: the thread, and only for 3.6 s.**

| Phase | Min | Coll./s | Queue peak | Threads | Core | DB | Heap | SNMP |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| before | 2 | 38.9 | 0 | 206 | 66.1% | 36.1% | 8.4 | 21.8 |
| outage | 15 | 36.1 | 0 | 143 | 12.0% | 3.9% | 5.8 | 2.1 |
| restore +0 to 5 min | 5 | 35.9 | 1 | 205 | 56.0% | 29.8% | 6.4 | 18.3 |
| restore +5 to 15 min | 10 | 35.9 | 7 | 209 | 62.9% | 29.0% | 8.5 | 20.2 |
| restore +15 to 30 min | 15 | 36.1 | 56 | 202 | 60.8% | 27.5% | 8.4 | 20.3 |

Table: the collector side, `bin/render_phases.py` over `outage-timeline.log`; Heap in GiB, SNMP in Mbit/s on the Minion's link. The two minutes before the outage are the monitor's; the window before it in the table above is the fuller measurement.

| Phase | Failed | Succeeded | Open alarms, peak |
|---|---:|---:|---:|
| before | 0 | 0 | 0 |
| outage | 11,000 | 0 | 11,000 |
| restore +0 to 5 min | 0 | 10,080 | 10,286 |
| restore +5 to 15 min | 0 | 858 | 0 |
| restore +15 to 30 min | 0 | 0 | 0 |

Table: the event path, same log; failed and succeeded are `dataCollectionFailed` and `dataCollectionSucceeded` events summed over the phase, open alarms the peak of major alarms open.

{{figure threads}}

A collection that gets no answer waits for the 1,800 ms timeout, retries once, and fails on its first PDU: 3.6 s of thread time against the 5.4 s a successful collection of 61 PDUs at 76 ms takes. The pool ran 143 threads busy instead of 206. The RPC's 20 s TTL never came into play; the Minion answered with the failure after 3.6 s.

{{figure cpu}}

The Core's CPU fell from 66% to 12%. A failed collection has no XML response to decode, no attributes to store, no node to look up per resource and nothing to send to Kafka; what remains is the scheduler, the RPC round trip and the log line. The database fell from 36% to 4% for the same reason. The heap drifted from 8.4 to 5.8 GiB as in-flight state emptied, and no old-generation collection ran at any point.

{{figure heap-gc}}

{{figure net}}

REST answered three node-list requests in 0.29 to 0.45 s during the outage.

## The event path {#the-event-path}

**One event and one alarm per service in the first cycle, then silence.** In the five minutes after T0 the events table gained 11,000 `dataCollectionFailed` rows, about 2,350 a minute, and the alarms table 11,000 major alarms, one per service. From the second cycle on there were no further events: a service that is already failed does not raise again on the next failure. The database's CPU shows no sign of the burst.

## Recovery {#recovery}

**One cycle, and nothing left behind.** Within five minutes of T1, 10,080 of the 11,000 services had logged `dataCollectionSucceeded`; the last 858 followed in the next cycle, the services whose turn in the interval fell before the restore. The open major alarms went from 11,000 to 0 in the same five minutes and the cleared alarms were gone from the table within ten. SNMP traffic on the Minion's link, the Core's CPU and the heap were back at their pre-outage values inside the first cycle, and the queue's recovery peak was two tasks.

What the outage cost is the samples: three cycles for every device, about 33,000 collections at 1,738 samples each, an estimated 57 million samples that were never taken. Polling does not back-fill, and the gap is the whole record of the outage.

## Where it stops {#where-it-stops}

**Total and silent is the cheap case for the pool; partial is the expensive one.**

- A device that answers some tables and not others holds a thread for a timeout per PDU that fails, up to 61 × 3.6 s, where a dead device holds it for one. A fleet in which a third of the agents are slow rather than gone is the outage that fills the pool, and it was not run here.
- At 11,000 devices the Core had 40% of its CPU spare and the pool a quarter of its threads for the recovery burst. The same burst at the 32 GiB Core's knee of 20,250 lands on a processor at 96%, where the earlier reports found that an import or a capture tips the Core into a backlog it cannot drain.
- Alarm reduction was exercised on an empty table. A deployment carrying tens of thousands of alarms already would reduce 11,000 new ones against that table.
- The outage lasted 15 minutes. Recovery is a property of how Collectd reschedules a failed service, and should not lengthen with the outage; a longer one was not measured.
