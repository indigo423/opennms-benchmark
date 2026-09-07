---
author: "Ronny Trommer <ronny@opennms.com>"
eyebrow: "PoweredBy 2026 · SNMP performance management · Kafka compression · 400 threads on a 32 GiB Core"
title: "Compression: eight times less traffic,<br>paid for by the Core"
lede: "Kafka producer compression was switched on one producer at a time on the 19,250-device fleet that the 400-thread Core carries with 11% of CPU to spare. lz4 on the Minion's RPC responses takes the Minion's link to Kafka from 181 to 23 Mbit/s and the broker's from 438 to 120, costs the Minion nothing it can measure, and costs the Core 5% more CPU per collection. zstd saves a little more traffic and costs the Core 9%, which is past the cliff. lz4 on the Core's own metrics producer costs the Core 6% for a 12% saving on the broker's link. On a Core that is the bound, no codec is free; on a link or a broker that is the bound, lz4 on the Minion is close to free."
verdict:
  - { k: "Minion lz4, traffic", v: "13%", n: "of baseline on the Minion's link to Kafka: 23 against 181 Mbit/s", hero: true }
  - { k: "Minion lz4, Core cost", v: "+5.2%", n: "CPU per collection: 0.117 against 0.111 core-seconds" }
  - { k: "Minion zstd, Core cost", v: "+8.5%", n: "0.121 core-seconds; Core at 97%, queue never empty: fail" }
  - { k: "Core metrics lz4", v: "+6.0%", n: "on the Core for the broker's link at 88% of baseline" }
  - { k: "Baseline repeat", v: "0.111", n: "core-seconds per collection both times: the comparison is stable" }
caveats: |
  Each codec is one 15-minute window, three cycles, opened five minutes after the Core reloaded its services following an OpenNMS restart; the uncompressed baseline was measured twice, before the first trial and after the last. The Core's CPU per collection agreed between the two baselines to three decimals and is the column the comparison rests on; the queue figures vary with the restart's scheduling wave and only say pass or fail.
  No collector ran on any host: every number is Prometheus and the trial script. A profiler would say how the Core's extra cost divides between decompression, the Kafka client's copies and the garbage they leave; it cannot be attached to this Core without collapsing it.
  The compression ratio is the ratio of this RPC encoding, SNMP results as formatted XML. The injected latency is uniform between 50 and 100 ms on every response.
method: |
  The fleet is the healthy rung the 400-thread search left behind: 19,250 nl6 devices, 19,254 collectable services, `netem delay 75ms 25ms`, `max-repetitions=5`, Collectd `threads="400"`, G1 on a 20 GiB heap. It runs at 89% Core CPU with the queue draining every cycle.

  Five windows on 2026-09-06 UTC, in the order run: no compression (20:10 to 20:25), `compression.type = lz4` in the Minion's `org.opennms.core.ipc.kafka.cfg` (20:55 to 21:10), `zstd` in the same file (21:26 to 21:41), the Minion back to none and `lz4` in the Core's `org.opennms.features.kafka.producer.client.cfg` (21:57 to 22:12), everything back to none (22:26 to 22:41). Every key in the Minion's file reaches its Kafka producers, so its codec applies to the RPC responses and the sink; the Core's client file applies to the metrics topic. The broker leaves `compression.type` at `producer`, so it stores what it receives and the consumer decompresses.

  A codec change on the Minion needs a Minion restart, which interrupts the RPC stream for about two minutes and leaves a backlog on the Core that a surplus of 2.5 collections a second takes an hour to drain. Every window was therefore preceded by an OpenNMS restart on the Core, the same procedure for all five, and opened five minutes after the Core had loaded its services. Judged with `bin/kafka_trial.py` by the knee search's rule: the pending queue must return to zero inside the window and the completed count must reach 97% of the services due. CPU per collection is CPU busy times cores divided by the collections the executor completed, from the counter's raw samples.
---

## The impact {#the-impact}

**Negative for the Core, positive for the broker and the network, neutral for the Minion.** The Core is the machine at its limit on this fleet, and every codec adds to what the Core does per collection: decompressing the Minion's responses when the Minion compresses, compressing its own metrics when it does. The broker and its link win in every trial. The Minion, at half of four vCPU, does not register the compression it performs.

| Trial | Minion codec | Core metrics codec | Coll./s | Completion | Queue at zero | Queue peak | Core CPU | Core core-s per coll. | Minion CPU | Broker CPU | Minion to Kafka | Core Kafka side | Broker link | Verdict |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| baseline-none | none | none | 64.25 | 100.1% | 44% | 191 | 89.3% | 0.1112 | 49.0% | 22.5% | 181 Mbit/s | 257 Mbit/s | 438 Mbit/s | pass |
| minion-lz4 | lz4 | none | 64.20 | 100.0% | 18% | 847 | 93.9% | 0.1170 | 48.9% | 17.1% | 23 Mbit/s | 97 Mbit/s | 120 Mbit/s | pass |
| minion-zstd | zstd | none | 64.31 | 100.2% | 0% | 2,229 | 97.0% | 0.1207 | 51.4% | 17.4% | 16 Mbit/s | 91 Mbit/s | 107 Mbit/s | fail |
| core-metrics-lz4 | none | lz4 | 64.86 | 101.0% | 10% | 1,513 | 95.6% | 0.1179 | 52.2% | 22.0% | 184 Mbit/s | 200 Mbit/s | 384 Mbit/s | pass |
| baseline-none-repeat | none | none | 64.10 | 99.9% | 34% | 897 | 88.9% | 0.1110 | 50.0% | 23.5% | 182 Mbit/s | 258 Mbit/s | 439 Mbit/s | pass |

Table: one window per row, `trials.jsonl` rendered by `bin/render_table.py`. Coll./s is the window integral of the completion counter; required is 64.18 throughout.

| Trial | Core core-s per coll. | Minion to Kafka | Broker link | Broker CPU |
|---|---:|---:|---:|---:|
| minion-lz4 | +5.2% | 13% of baseline | 27% of baseline | -5.4 points |
| minion-zstd | +8.5% | 9% of baseline | 25% of baseline | -5.1 points |
| core-metrics-lz4 | +6.0% | 102% of baseline | 88% of baseline | -0.5 points |
| baseline-none-repeat | -0.2% | 100% of baseline | 100% of baseline | +1.0 points |

Table: the same records against the first baseline.

{{figure cpu-per-collection}}

The two uncompressed windows, 65 minutes apart with three restarts between them, put the Core at 0.1112 and 0.1110 core-seconds per collection. The three codec windows sit at 0.117, 0.121 and 0.118. The effect is ten to twenty times the difference between the baselines.

## The network {#the-network}

**lz4 takes the Minion's link from 181 to 23 Mbit/s; zstd to 16; the Core's own producer takes 57 Mbit/s off its link.** The Minion's RPC responses are SNMP results marshalled as formatted XML, whitespace and repeated element names, and lz4 shrinks them about eight to one. The broker's interface, which carries the responses in and out again plus the metrics topic, goes from 438 to 120 Mbit/s with lz4 on the Minion and to 107 with zstd. The Core's metrics are protobuf collection sets, denser to begin with; lz4 shrinks them about three to one, roughly 90 to 25 Mbit/s out of the Core, and the broker's link falls 12%.

{{figure net-kafka}}

Traffic on the SNMP side of the Minion, 45 Mbit/s of GETBULK and responses, does not change: the codec sits between the Minion and Kafka, not between the Minion and the fleet.

## The Core {#the-core}

**5% per collection for lz4, 9% for zstd, 6% to compress its own output, and more than the codec's speed accounts for.** lz4 decompresses at hundreds of megabytes a second per core; 22 MB/s of responses should cost about a percent of one core, not 5% of eight. The rest is what surrounds the codec in the Kafka client: a compressed batch is decompressed into a fresh buffer on the single consumer thread, the record is copied out of it, and the XML parser reads it from there. Young-collection pause time on the Core rose from 2.9 to 3.6 s a minute with lz4 responses and 3.7 with zstd, which is where those buffers show first.

{{figure cpu}}

{{figure gc}}

At 19,250 devices the Core still passes with lz4, with the queue empty 18% of the window instead of 44%. With zstd it does not: 97% CPU, the queue floor above 300 for the whole window. Translated to the 400-thread knee at 20,250, where 0.115 core-seconds per collection meets eight cores, lz4 on the RPC path would move the knee down by about 1,000 devices and zstd by about 1,600, estimated from the per-collection cost.

{{figure throughput}}

{{figure queue}}

## The Minion and the broker {#minion-and-broker}

**The Minion pays nothing it can measure; the broker gains five CPU points and three quarters of its traffic.** The Minion compresses the same 22 MB/s the Core decompresses, on four cores that are half idle, and its CPU reads 49% with lz4, 51% with zstd and 49% and 50% without. The broker, two vCPU at 22.5% uncompressed, falls to 17% with either Minion codec: less to receive, less to write to its log, less to serve back to the Core. Compressing the Core's metrics does not change the broker's CPU, only its link.

## Where it helps {#where-it-helps}

**Where the link or the broker is the bound, lz4 on the Minion. Where the Core is the bound, nothing.**

- A Minion behind a WAN link, or a location whose responses share a link with other traffic, wants `compression.type = lz4` in its `org.opennms.core.ipc.kafka.cfg`: eight times less traffic for a cost the Minion does not feel, at a price on the Core of about 5% per collection served by that Minion.
- A broker approaching its interface or its CPU wants the same. At 438 Mbit/s on one interface for 19,250 devices, the uncompressed broker link reaches a gigabit near 44,000 devices; with lz4 it does not reach it at all.
- zstd buys 30% less traffic than lz4 for 60% more Core cost. On this workload it is the wrong trade.
- The Core's metrics producer is the wrong place to compress while the Core is the bound. If the consumer of the metrics topic needs less traffic, the broker can recompress a topic on its own CPU with a topic-level `compression.type`, which this experiment did not test.
- On this Core at this fleet the recommendation is no compression on the RPC path, and the report on the processor's knee names the levers that would give the Core the CPU to afford one.
