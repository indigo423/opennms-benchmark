---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · agent outages · max-repetitions 5"
title: "An unreachable agent is the cheap outage:<br>the collector absorbs all of it, the alarm table needs the recovery left alone"
lede: "A quarter, a half, three quarters and all of an 11,000-device fleet were made unreachable in turn, silently, each for three collection cycles on a 16 GiB Core with a 250-thread pool. Every resource on the Core, the Minion and the database fell in proportion to the dead share, the pool ran lighter rather than fuller, the queue never held a task while agents were down, and the healthy remainder was collected on time at every level. One failure event and one major alarm per dead agent, once, then nothing until it returned. The one lasting harm came from outside the experiment: a restart during the fourth recovery left 4,404 alarms open with no collector state to clear them. All of it rests on `max-repetitions=5`, which caps a collection at 61 GETBULK requests instead of the default 149 and is what leaves this pool a quarter spare. The outage that costs a collector is not the agent that is gone. It is the agent that is slow, and that one was not run."
verdict:
  - { k: "Core CPU by dead share", v: "62 → 52 → 37 → 20 → 8%", n: "at 0, 25, 50, 75 and 100% of agents unreachable", hero: true }
  - { k: "Thread time per collection", v: "3.6 s dead, 5.2 s live", n: "a dead agent releases its thread first: 190 busy threads of 250 become 129" }
  - { k: "Queue at zero", v: "100%", n: "of every outage window; no live agent waits behind a dead one" }
  - { k: "Delivered by the remainder", v: "78 / 57 / 34 / 12%", n: "of the healthy metrics stream at 25 / 50 / 75 / 100% dead, against 75 / 50 / 25 / 0 expected" }
  - { k: "GETBULK requests per collection", v: "61", n: "configuration, not a result of this run: max-repetitions=5 against a shipped default of 2, which is 149" }
caveats: |
  Every dead agent fails on its first PDU after one timeout and one retry. The agent that answers late or answers only some tables is the outage that loads the pool, and it was not run. Whether Collectd abandons a collection at its first timeout or continues to the next table was not established here; the degraded-agent budgets below assume it continues, and if it abandons they do not apply at any setting.
  `max-repetitions` was held at 5 throughout. Its effect is quoted from earlier searches on this same Core class at a different fleet size and pool, and its consequences for a degraded agent are arithmetic, marked as estimates where they appear.
  The levels were applied to whole /24 blocks, in ascending order, once each. This Core had 40% of its CPU and a quarter of its pool spare, and every level made it lighter; what a Core at its knee would feel is the recovery burst, not the outage.
  Delivered work is the Core's transmit to Kafka against the healthy baseline. That link also carries the small, constant RPC requests, which is why the delivered share reads a few points above the expected share at every level.
method: |
  The deployment is the 16 GiB shape of `kfk-exclusive`, re-established the same morning and judged healthy: 8 vCPU, a 10 GiB heap on G1, Collectd `threads="250"`, 11,000 nl6 devices of 144 interfaces at `netem delay 75ms 25ms`, `max-repetitions=5` for `10.42.0.0/16`, SNMP timeout 1,800 ms with one retry, so a failing collection costs 3.6 s of thread time. The healthy baseline window is 11:00 to 11:15 UTC.

  Each level drops whole /24 blocks of 250 devices on netsim's FORWARD chain ahead of the rule that carries SNMP into the simulator's namespace, so the requests are dropped without ICMP: 11 blocks for 25%, 22 for 50%, 33 for 75%, all 44 for 100%. A probe from the Minion confirmed the boundary at each level. A level is held three collection cycles and judged over its second and third by `bin/judge.py`, then removed, with two cycles of recovery before the next. `bin/monitor.py` logs one line a minute, with events and alarms read from the database because eventd and alarmd publish no counters.

  The 50% level was run twice. The first attempt was switched off six minutes in by a timing mistake and its window discarded on duration. Its last two minutes at the full 5,500 dead read 37.1% and 36.8% Core CPU in `timeline.log` against the accepted window's 36.5%, so the discard cost nothing but time.
---

## What an outage costs {#the-cost}

**Every resource falls, linearly in the share of agents that are unreachable, on all three machines.** An SNMP agent that does not answer is the cheapest agent this deployment has.

| Unreachable | Coll./s | Threads | Queue empty | Core | Minion | DB | Core-s per coll. |
|---|---:|---:|---:|---:|---:|---:|---:|
| 0%, baseline | 36.66 | 190 | 92% | 62.1% | 28.6% | 27.4% | 0.1356 |
| 25% | 36.63 | 162 | 100% | 52.3% | 23.3% | 22.8% | 0.1141 |
| 50% | 36.92 | 147 | 100% | 36.5% | 17.1% | 15.5% | 0.0791 |
| 75% | 36.58 | 139 | 100% | 20.4% | 9.8% | 8.2% | 0.0445 |
| 100% | 36.61 | 129 | 100% | 8.4% | 4.0% | 2.8% | 0.0184 |
| 0%, after the pulse | 36.71 | 198 | 37% | 66.9% | 29.8% | 28.7% | 0.1459 |

Table: the collector side, `bin/render_levels.py` over `levels.jsonl`; each row is one ten-minute window over the level's second and third cycle. Dead agents are 110 per percentage point; Core-s per coll. is Core CPU times eight cores over collections per second.

| Unreachable | Metrics out | Delivered | Expected | Heap | Load |
|---|---:|---:|---:|---:|---:|
| 0%, baseline | 47.6 | baseline | 100% | 8.6 | 12.4 |
| 25% | 37.4 | 78% | 75% | 7.9 | 9.9 |
| 50% | 27.0 | 57% | 50% | 7.7 | 4.5 |
| 75% | 16.0 | 34% | 25% | 6.7 | 2.4 |
| 100% | 5.5 | 12% | 0% | 6.1 | 1.4 |
| 0%, after the pulse | 47.7 | 100% | 100% | 8.6 | 18.8 |

Table: the delivery side, same records. Metrics out is the Core's transmit to Kafka in Mbit/s, Delivered that transmit against the baseline, Heap in GiB, Load the Core's one-minute average.

{{figure cpu}}

A collection that gets no answer times out on its first PDU after 3.6 s and returns a failure: the Minion marshals nothing, the Core decodes nothing, stores nothing and looks up no node per resource, and the producer sends nothing to Kafka. Per collection the Core's cost reads 0.136 core-seconds with every agent alive and 0.018 with every agent dead, the second number being the scheduler, the RPC round trip and a log line.

Load average is the one column that does not follow CPU: 12.4 at the baseline against 18.8 after the pulse, at five more points of CPU and the same collection rate. The reading offered here is an interpretation. Load counts threads runnable or in uninterruptible sleep, and the post-pulse window runs its pool at the ceiling through each crest with a queue peak of 2,382, so more threads wait to run while the processor is no busier. Nothing captured separates run-queue depth from disk wait.

{{figure threads}}

The pool runs lighter, not fuller: 190 busy threads at 0%, 129 at 100%. By Little's law that is 5.2 s of thread time per live collection against 3.5 s for a dead one, and 3.6 s is what the configuration predicts for the dead case exactly, one 1,800 ms timeout and one retry. This is the property that makes the deployment safe against unreachable agents, and it is worth being precise about why it may not carry to a degraded one: a dead agent is cheap because the collection stops at the first unanswered PDU, and what happens when a *later* PDU goes unanswered was not established here.

{{figure heap-gc}}

{{figure oldgen}}

The heap follows the in-flight state, 8.6 GiB at 0% and 6.1 at 100%, and no old-generation collection ran at any level.

## Is the healthy remainder protected {#the-remainder}

**Yes on every collector-side resource, and within the resolution of a byte-rate proxy on delivery.** The completion counter never leaves the fleet's demand, because a failed collection counts as completed and is rescheduled like any other; the queue floor stays at zero for the whole window at every level, so no live agent waits behind a dead one.

{{figure throughput}}

{{figure queue}}

The Core's metrics stream to Kafka measures what the remainder delivers: 78% of the healthy baseline with a quarter of the agents dead, 57% with half, 34% with three quarters, 12% with all of them, against expected shares of 75, 50, 25 and 0. The constant few points above them are read as the RPC requests on the same link, which do not shrink, and that reading is an interpretation of the offset rather than a measurement of it. A byte rate cannot separate a remainder that delivered its full share from one that delivered slightly less while RPC made up the difference. Within that resolution, the delivered share is the live share at every level.

{{figure delivered}}

## The setting the whole behaviour rests on: `max-repetitions=5` {#the-tuning}

**`max-repetitions=5` caps a collection at 61 GETBULK requests instead of the shipped default's 149.** It does not change what a dead agent costs. It sets the headroom the pool has before an outage, and, under an assumption stated below, the ceiling on what a degraded agent can hold once one starts.

The attribute was held at 5 throughout, so nothing here measures it. One quantity this run does measure is the thread time it governs.

{{figure thread-time}}

Busy threads over collections per second is the mean time a collection holds a thread. It steps down once per level, 4.39 s at a quarter dead through 3.51 s with the whole fleet gone, and rises again in the recovery gaps. The floor is configuration, not tuning: an unreachable agent costs 3.6 s at any value of the attribute. The fleet reaches that floor by mixture, not by any agent getting cheaper. What the attribute sets is the other end of the range, the cost of a collection that is answered.

| | `max-repetitions=2`, the default | `max-repetitions=5`, here |
|---|---:|---:|
| GETBULK requests per collection | 149 | 61 |
| Thread time, agent healthy at 76 ms per PDU | 11.5 s | 5.4 s |
| Thread time, agent unreachable | 3.6 s | 3.6 s |
| Thread time, agent degraded, worst case, estimated | 536 s | 220 s |
| Threads to carry 11,004 services, estimated | 422 | 198 |
| Degraded agents that fill the spare pool, estimated | none spare | 71 to 82 |

Table: rows one and two are read from earlier searches on this same Core class, 8 vCPU with a 10 GiB heap and the same simulated device at the same `netem delay 75ms 25ms`, at a different fleet size and pool. The 5.4 s matches this run's post-pulse window, 198 busy threads at 36.71 collections a second; the healthy baseline reads 5.18 s by the same arithmetic, and the two bracket the imported figure. Rows three to six are arithmetic on this deployment's `snmp-config`, 1,800 ms timeout with one retry, and its 300 s interval; they are estimates, not measurements.

**The assumption rows three and six rest on.** A degraded agent costs a timeout per unanswered PDU only if Collectd continues to the next table after a timeout. If it abandons the collection at the first one, as it does for a dead agent, then a degraded agent costs the same 3.6 s and those rows do not apply at any setting. This series could not tell the two apart, because a dead agent behaves identically under both. It is the first thing the slow-agent experiment should settle.

**Before the outage, the attribute is what leaves the pool spare.** The fleet asks for 36.68 collections a second. At 5.4 s of thread time that is an estimated 198 threads of the 250 configured, against 190 measured at the baseline and 198 after the pulse. At the default the same fleet asks for an estimated 422, and the pool limit of threads times 300 over thread time puts 250 threads at about 6,500 services. This deployment could not carry 11,000 agents at `max-repetitions=2`, so the spare quarter of the pool that every level ate into is the attribute's doing.

**During the outage it changes nothing.** A dead agent returns after 3.6 s whatever the attribute says, because there is no second request to make. That is why the curves above are as clean as they are.

**After an agent degrades rather than dies, it is the ceiling.** Granting the assumption, the worst case at 5 is 61 timeouts, an estimated 220 s inside a 300 s interval, so one such agent occupies an estimated 0.73 threads continuously. At the default it is 149 timeouts and an estimated 536 s, longer than the interval, so one agent pins more than a thread and its collections overlap. With the remainder still asking for its 190 to 198 threads, the 52 to 60 spare are consumed by an estimated 71 to 82 degraded agents, under 1% of this fleet. The attribute more than doubles that budget. It does not make it large.

A full pool is not yet a failure. The post-pulse window ran at the ceiling through every crest, with a queue peak of 2,382, and still delivered the full baseline stream, because the queue drained inside each interval. The threshold that matters is this series' own pass rule, the queue returning to zero within the interval, and it lies somewhere beyond the pool filling. This series cannot locate it.

**One caution on direction.** `netem` makes every agent slow per packet, uniformly, and against that failure mode fewer requests is strictly fewer timeouts. A real agent is usually slow because its own processor is loaded, and such an agent may fail a five-repetition GETBULK it would have answered at two. The mechanism that makes the attribute protective here could invert it there, and nothing in this lab can produce that failure mode.

**Where to set it.** On this build the Config Manager owns `snmp-config`, not the file. On an earlier search on this same Core class, writing `etc/snmp-config.xml` on disk changed nothing, on a reload event or on a restart: the file is imported once at first start and the database copy is authoritative afterwards. One `PUT` to `rest/cm/snmp-config/default` with a `definition` carrying `max-repetitions="5"` for the fleet's range applied it immediately, and the effective configuration for a fleet address then read `maxRepetitions 5` while an address outside the range still read 2. That is how it was set here; the disk path was not re-tested after the 2026-09-07 rebuild. Size the value to the device's tables. It costs the Core nothing, and it is the only constant in the collector's arithmetic that a configuration file changes by a factor of two.

## The event path {#the-event-path}

**One failure event and one major alarm per dead agent in the level's first cycle, one success event and one clear per agent in the recovery's first cycle, and nothing in between.** The events table shows each level's burst completing inside five minutes, 2,750 to 11,000 events at about 2,300 a minute, and no further failure events for the rest of the level; a service already failed does not raise again. Recovery reversed it in the same span. The database's CPU shows the bursts as nothing above its per-level floor.

**Restarting OpenNMS during a recovery orphans one alarm per service that has not yet recovered, permanently.** This is the only lasting damage the series produced, and it did not come from the outage. The fleet came back at 15:30:25 and 6,595 services logged their success in the next three minutes. At 15:33:19 an Ansible session as the deployment user restarted OpenNMS, seventy seconds of JVM start and a full reload of the 11,004 services. The collector that came up had no memory of which services were failed, so it raised no success event for the 4,404 still down, and their major alarms stayed open with nothing left to clear them. Nothing closed them afterwards; they were still open forty minutes later and were cleared only by re-failing every service deliberately, which is what the pulse is.

Whether that is a defect is open. It turns on whether collectd or alarmd is expected to reconcile collector state against the open alarm table on startup, which was not investigated and for which no issue has been filed. The operational rule stands either way: do not restart the Core while a recovery is in flight.

The two windows after the restart carry its scheduling wave, 250 threads busy and a queue peak of 230, and are not a recovery measurement.

## A clean recovery: the pulse {#the-pulse}

**One cycle of total outage, and every service and every alarm back within the next.** To clear the orphaned alarms the 100% level was applied once more at 16:07:28 for a single cycle and removed at 16:13:14. It is also the clean recovery measurement the interrupted level could not give.

| Phase | Min | Coll./s | Queue peak | Threads | Core | DB | Heap | SNMP |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| before | 1 | 18.6 | 7,483 | 250 | 27.7% | 12.4% | 4.3 | 11.3 |
| outage | 5 | 36.5 | 6,071 | 179 | 17.6% | 6.2% | 5.0 | 1.8 |
| restore +0 to 5 min | 5 | 36.1 | 2,161 | 204 | 62.0% | 30.4% | 6.6 | 18.1 |
| restore +5 to 15 min | 2 | 29.6 | 649 | 215 | 60.8% | 26.6% | 9.1 | 17.4 |

Table: the collector side, `bin/render_phases.py` over `pulse.log`; Heap in GiB, SNMP in Mbit/s on the Minion's link, "before" the one minute before the pulse.

| Phase | Failed | Succeeded | Open alarms, peak |
|---|---:|---:|---:|
| before | 0 | 0 | 4,404 |
| outage | 10,881 | 0 | 10,975 |
| restore +0 to 5 min | 40 | 9,883 | 10,771 |
| restore +5 to 15 min | 0 | 1,170 | 0 |

Table: the event path, same log; failed and succeeded are `dataCollectionFailed` and `dataCollectionSucceeded` events summed over the phase, open alarms the peak of major alarms open.

Every one of the 11,000 services failed once inside the cycle, 10,975 within four minutes. Within five minutes of the restore 9,883 had logged their success and open alarms had fallen to 1,182; the last cleared in the next minutes, and at 16:18 the alarm table held none.

**What the recovery cycle costs, and what it would cost a loaded Core.** The crest of the restore, the minute ending 16:16:26, ran at 48.7 collections a second with the Core at 90.4%. Two things multiply there. The collector runs at an estimated 1.33 times the fleet's demand of 36.68, working off a wave of 11,000 services all due together. Each of those collections costs an estimated 0.1485 core-seconds against the healthy 0.1356, about 10% more, because a returning service raises an event and clears an alarm on top of being collected. Together that is an estimated 1.46 times the healthy CPU, and 62.1% times 1.46 is 90.5% against the 90.4% measured, so the two factors account for the crest.

A Core whose healthy steady state is 62% has that room. A Core at 96%, the utilisation at which this Core collapses, does not: 1.46 times 96% is not available at any fleet size. Such a Core cannot clear the wave in one cycle, so the queue carries the remainder into later ones, and how many cycles it then takes to drain is not something this series can answer.

The judged window two cycles after the pulse reads 36.71 collections a second against 36.68 required, 198 threads busy with the pool at its ceiling through each crest, a queue peak of 2,382 back at zero 37% of the time, Core CPU 66.9%, and the full baseline stream delivered. The pool absorbs the re-aligned wave and drains it every cycle; the rate above demand is the backlog being worked off.

## What to watch, and whether 250 threads is right {#what-to-watch}

**The signal that separates a degraded fleet from a dead one is the inverse of every curve in this report.** A dead agent makes the collector lighter: busy threads fall, CPU falls, the metrics stream shrinks in proportion. A slow agent makes it heavier while the collection rate holds, because a thread is held longer for the same work.

- **Busy threads rising while collections per second holds flat.** The degraded case, with no other cause on this deployment. Every failure mode measured here moves those two together, not apart.
- **The queue failing to return to zero within a 300 s interval.** This is the failure threshold, not the pool reaching its ceiling; the post-pulse window sat at the ceiling for a whole window and still delivered its full stream. `opennms_collectd_taskqueuependingcount` at its per-interval minimum shows it.
- **Metrics out falling without a matching fall in busy threads.** Agents going dead take both down together. A fall in delivery alone is a problem downstream of collection, not an outage.

**On the pool.** 250 threads is endorsed for this fleet, with little to spare. The fleet needs an estimated 198 and the sizing rule asks for a 20% margin, which is 238; the 250 configured meets it by 12. That margin is what absorbs the recovery wave and what the degraded-agent budget spends. A larger fleet on this Core should raise the pool before anything else, and should expect the processor, not the pool, to bind next.

## Which outages are not this one {#where-it-stops}

**This series measured agents that are gone. Agents that are slow are a different experiment, and the expensive one.**

- An agent that answers late or answers only some tables may hold a thread through a timeout per unanswered PDU, 61 × 3.6 s in the worst case here against the single 3.6 s measured. That worst case depends on Collectd continuing past a timeout rather than abandoning the collection, which this series did not establish. If it holds, a fleet with a quarter of its agents slow rather than gone could hold the whole pool with the remainder waiting behind it.
- `max-repetitions` was held at 5. The comparison against the default is quoted from earlier runs at a different fleet size and pool, and the degraded-agent budgets built on it are arithmetic. Against an agent slow through its own load the attribute may not help at all.
- The steps are whole /24 blocks. A real outage takes a site or a link, which is also a block; a random quarter of the fleet would spread through the schedule the same way.
- This Core had 40% of its CPU spare. Every level made it lighter, and the only burst a Core at its knee would feel is the recovery cycle, at an estimated 1.46 times healthy CPU, which a Core at 96% does not have.
- Alarm reduction ran against a table holding only this series' alarms. A deployment carrying tens of thousands of standing alarms reduces each burst against them.
