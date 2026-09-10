# Full network outage: no SNMP agent reachable for three cycles

Does the deployment survive a complete loss of the fleet and come back on its own?
One variable, agent reachability; everything else the healthy 16 GiB deployment as left this morning: 11,000 devices, 250 Collectd threads, 10 GiB heap, G1, `max-repetitions=5`, `netem delay 75ms 25ms`, SNMP timeout 1,800 ms with one retry, Kafka RPC TTL at its 20 s default.

## Method

The outage is a silent drop, the shape a real network failure has for a Minion: the forwarding rule that carries SNMP into the simulator's namespace on netsim was removed at T0 = 10:28:02Z, so every request from the Minion was dropped with no ICMP and every PDU ran to its timeout.
It was restored at T1 = 10:43:12Z, 15 minutes and three collection cycles later, and the fleet was reachable again at once.
`bin/monitor.py` logged one line a minute throughout: collector gauges, CPU on Core, Minion and database, heap and old-generation GC, SNMP traffic on the Minion's link, and the event path read from the events and alarms tables, since eventd and alarmd expose no counters.
The REST API was probed from the monitoring host during the outage.
The windows before and after were judged with the knee search's rule by `trial.py`: the queue returns to zero inside 15 minutes and the completed count reaches 97% of the services due.

## What happened

| Phase | Minutes | Coll./s | Queue peak | Threads busy | Core CPU | DB CPU | Heap | SNMP Mbit/s | dataCollectionFailed | dataCollectionSucceeded | Open major alarms, peak |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| before the outage | 2 | 38.9 | 0 | 206 | 66.1% | 36.1% | 8.4 GiB | 21.8 | 0 | 0 | 0 |
| outage | 15 | 36.1 | 0 | 143 | 12.0% | 3.9% | 5.8 GiB | 2.1 | 11000 | 0 | 11000 |
| first 5 min after restore | 5 | 35.9 | 1 | 205 | 56.0% | 29.8% | 6.4 GiB | 18.3 | 0 | 10080 | 10286 |
| 5 to 15 min after restore | 10 | 35.9 | 7 | 209 | 62.9% | 29.0% | 8.5 GiB | 20.2 | 0 | 858 | 0 |
| 15 to 30 min after restore | 15 | 36.1 | 56 | 202 | 60.8% | 27.5% | 8.4 GiB | 20.3 | 0 | 0 | 0 |

T0 10:28:02Z, T1 10:43:12Z; one line per minute from bin/monitor.py.

| Window | Coll./s | Completion | Queue at zero | Queue peak | Threads busy | Core CPU | Old-gen GC | Verdict |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| Before, 10:00 to 10:15 | 36.65 | 99.9% | 93% | 33 | 191 | 61.1% | 0 | pass |
| After, 10:45 to 11:00 | 36.67 | 100.0% | 93% | 32 | 190 | 59.8% | 0 | pass |
| After, 11:00 to 11:15 | 36.66 | 99.9% | 92% | 56 | 190 | 61.9% | 0 | pass |

Table: `trials.jsonl` here for the two windows after; the window before is the record `class16g-11000-threads250-g1` in `experiments/pm-snmp-sizing-rule/results/trials.jsonl`.

REST during the outage: three requests for the node list answered in 0.29 to 0.45 s.

## Reading it

**Yes. The deployment survives, and it recovers within one collection cycle with nothing left behind.**

- **During the outage the collector keeps its rhythm.** Every collection now fails on its first PDU after the 1,800 ms timeout and one retry, 3.6 s, so the pool runs 143 threads instead of 206 and the completion counter keeps ticking at the fleet's rate. The Core's CPU falls to 12%, because a failed collection has no XML to decode and nothing to store; the database's to 4%; the heap drifts down to 5.8 GiB. Nothing queues: a failure is a completed task. The RPC TTL of 20 s never comes into play, since the Minion answers with the failure after 3.6 s.
- **The event path takes the whole fleet in one cycle and then goes quiet.** 11,000 `dataCollectionFailed` events in the first cycle, about 2,350 a minute, one per service, 11,000 major alarms; then no further events for the rest of the outage, because a service that is already failed does not raise again. The database took the burst without a visible cost.
- **Recovery is one cycle.** Within five minutes of the restore 10,080 services had logged `dataCollectionSucceeded` and the last 858 followed in the next cycle; the open major alarms went from 11,000 to 0 in the same five minutes and the alarm table was empty of the cleared ones within ten. The queue peaked at 1 and 2 tasks in the recovery cycle. SNMP traffic, CPU and heap were back at their pre-outage values inside the first cycle, and both 15-minute windows after the restore pass the rule with the same numbers as the window before.
- **What the outage cost in data.** Three cycles of samples for every device, 36.7 collections a second for 15 minutes, about 33,000 collections and 57 million samples that were never taken. Nothing is back-filled; that is the nature of polling.

## Where this stops applying

- The outage was total and silent. A partial outage, some agents timing out while the rest answer, is the expensive case for the pool: a timing-out collection holds a thread for 3.6 s per PDU it waits on, and a device that answers some tables and not others can hold one for 61 × 3.6 s. That case was not run here.
- At 11,000 devices the Core had 40% of CPU spare and the pool a quarter. The same outage on the 32 GiB Core at its 20,250 knee would recover more slowly: the recovery cycle's `dataCollectionSucceeded` burst and alarm clearing land on a processor at 96%.
- The events table already held 14.7 million rows from earlier syslog experiments; the 22,000 rows of this outage are not what a fresh database would feel differently, but alarm reduction over a large `alarms` table was not exercised, since the table was empty before.
- One outage, one fleet size, one duration. The one-cycle recovery is a property of the collector's scheduling, not of the duration, and is expected to hold for longer outages; that was not measured.

## Files

- `outage-timeline.log`: one line per minute with the T0 and T1 markers and the REST probes.
- `bin/monitor.py`, `bin/render_phases.py`: the logger and the phase table above.
- `trials.jsonl`: the two windows after the restore.
