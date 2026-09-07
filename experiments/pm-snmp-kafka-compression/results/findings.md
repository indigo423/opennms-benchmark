# Kafka compression on the Core, the Minion and the network

One variable: the Kafka producer `compression.type`, first on the Minion (its RPC responses, the SNMP results as XML), then on the Core's metrics producer (protobuf collection sets).
Everything else held: 19,250 devices, 144 interfaces each, `netem delay 75ms 25ms`, `max-repetitions=5`, Collectd `threads="400"`, G1 on a 20 GiB heap, the 32 GiB Core of `deployments/kfk-exclusive`.
The broker leaves `compression.type` unset, so it stores whatever codec the producer used and the consumer decompresses.

## Method

Every trial is one 15-minute window, three collection cycles, opened five minutes after the Core finished loading its services following an OpenNMS restart.
The restart is part of the procedure on purpose: a Minion restart interrupts the RPC stream and leaves a backlog on the Core that a 2.5-per-second surplus would take an hour to drain, so each trial starts from the same aligned schedule.
The uncompressed baseline was measured twice, before the first trial and after the last, to size the noise of a single window.
Judged with `bin/kafka_trial.py` by the knee search's rule: the pending queue must return to zero inside the window and the completed count must reach 97% of the services due.
CPU per collection is CPU busy times cores divided by collections completed, read from the raw counter samples.

Where the codec lives:

- Minion: `compression.type = lz4` in `/opt/minion/etc/org.opennms.core.ipc.kafka.cfg`. Every key in that file reaches the Minion's Kafka producers (RPC responses and sink messages), see `KafkaRpcServerManager` and `OsgiKafkaConfigProvider`. Applied with a Minion restart.
- Core, metrics topic: `compression.type = lz4` in `/etc/opennms/org.opennms.features.kafka.producer.client.cfg`. Applied with a Core restart.

## Results

| Trial | Minion codec | Core metrics codec | Coll./s | Completion | Queue at zero | Queue peak | Core CPU | Core core-s per coll. | Minion CPU | Broker CPU | Minion to Kafka | Core Kafka side | Broker link | Verdict |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| baseline-none | none | none | 64.25 | 100.1% | 44% | 191 | 89.3% | 0.1112 | 49.0% | 22.5% | 181 Mbit/s | 257 Mbit/s | 438 Mbit/s | pass |
| minion-lz4 | lz4 | none | 64.20 | 100.0% | 18% | 847 | 93.9% | 0.1170 | 48.9% | 17.1% | 23 Mbit/s | 97 Mbit/s | 120 Mbit/s | pass |
| minion-zstd | zstd | none | 64.31 | 100.2% | 0% | 2,229 | 97.0% | 0.1207 | 51.4% | 17.4% | 16 Mbit/s | 91 Mbit/s | 107 Mbit/s | fail |
| core-metrics-lz4 | none | lz4 | 64.86 | 101.0% | 10% | 1,513 | 95.6% | 0.1179 | 52.2% | 22.0% | 184 Mbit/s | 200 Mbit/s | 384 Mbit/s | pass |
| baseline-none-repeat | none | none | 64.10 | 99.9% | 34% | 897 | 88.9% | 0.1110 | 50.0% | 23.5% | 182 Mbit/s | 258 Mbit/s | 439 Mbit/s | pass |

Relative to the first baseline row:

| Trial | Core core-s per coll. | Minion to Kafka | Broker link | Broker CPU |
|---|---:|---:|---:|---:|
| minion-lz4 | +5.2% | 13% of baseline | 27% of baseline | -5.4 points |
| minion-zstd | +8.5% | 9% of baseline | 25% of baseline | -5.1 points |
| core-metrics-lz4 | +6.0% | 102% of baseline | 88% of baseline | -0.5 points |
| baseline-none-repeat | -0.2% | 100% of baseline | 100% of baseline | +1.0 points |

The two uncompressed baselines agree on the Core's CPU cost per collection to three decimals (0.1112 and 0.1110 core-seconds) while their queue figures differ with the phase of the restart's scheduling wave (queue at zero 44% and 34%, peaks 191 and 897).
The queue columns therefore say pass or fail; the CPU per collection column carries the comparison.

## What it says

**Compression moves work from the network and the broker onto the Core, and the Core is the machine with nothing to spare.**

- **Minion lz4.** The Minion's link to Kafka drops from 181 to 23 Mbit/s and the broker's from 438 to 120: the XML responses compress about eight to one. The broker's CPU falls five points. The Minion's CPU does not move: lz4 compression of 22 MB/s is cheap on four cores that are half idle. The Core pays 5% more CPU per collection to decompress the same responses and its window passes with the queue empty 18% of the time instead of 44%. At 19,250 devices the rung still passes; at the 400-thread knee it would not.
- **Minion zstd.** Lowest traffic of all, 16 Mbit/s on the Minion's link, and 9% more CPU per collection on the Core. The Core runs at 97% and the queue never returns to zero. Fail.
- **Core metrics lz4.** The protobuf collection sets compress about three to one, roughly 90 to 25 Mbit/s out of the Core, and the broker's link falls 12%. The Core pays 6% more CPU per collection to compress its own output. Pass, marginal, with the queue empty 10% of the time.

The three trials cost the Core more than the decompression or compression arithmetic alone predicts: lz4 handles hundreds of megabytes a second per core, and 22 MB/s should be a percent of one core, not five percent of eight.
The rest is the Kafka client's buffer handling: compressed batches are decompressed into new byte arrays on the single consumer thread, and every response is copied once more before the XML parser sees it.
Young-collection time on the Core rose from 2.9 to 3.6 s per minute with lz4 responses, which is where those copies show.

## Where it helps and where it does not

- On this Core, at this fleet, the answer is no for the RPC path: the Core is the bound and every codec makes its bound worse. The knee with 400 threads moves down by roughly the CPU cost: about 1,000 devices for lz4 and 1,600 for zstd, estimated from the 0.115 core-seconds per collection that set the 20,250 knee.
- Where the network or the broker is the bound, lz4 on the Minion is the right codec: eight times less traffic for a Minion-side cost that does not register and a broker-side saving of five CPU points on two vCPU. A Minion behind a WAN link would want it; the broker at 438 Mbit/s on one interface with 20,000 devices would want it before 40,000.
- The Core's own metrics topic is the wrong place to compress on a Core at its limit; the consumer of that topic, not the Core, should decide.

## Files

- `trials.jsonl`: one record per window, written by `bin/kafka_trial.py`.
- `bin/render_table.py`: the tables above, from `trials.jsonl`.
- Both configurations were restored to no compression after the trials; the baseline repeat is the state the lab was left in.
