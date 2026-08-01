#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Sum the end offsets of a topic and print the total.
#
# Exists so an experiment can read the accepted side without SSH-ing to the
# broker. Delegating to the broker means a fresh connection through the jump
# host for every read, and a rate sweep does that often enough that a dropped
# ControlPersist session fails the run partway through, discarding the rungs
# already measured.
import json
import sys
import time
from pathlib import Path

MANIFEST = Path("/etc/lab-endpoints.json")

# Gap between drain polls. Short enough to locate the settle point, long
# enough not to hammer the broker for a whole sweep.
POLL_SECONDS = 5


def read_total(consumer, topic):
    """Summed end offsets, or None if the topic does not exist."""
    from confluent_kafka import TopicPartition

    meta = consumer.list_topics(topic, timeout=10)
    if topic not in meta.topics or meta.topics[topic].error:
        return None
    total = 0
    for part in meta.topics[topic].partitions:
        _, high = consumer.get_watermark_offsets(TopicPartition(topic, part), timeout=10, cached=False)
        total += high
    return total


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    if len(args) != 1:
        print("usage: kafka_offsets.py <topic> [--settle[=SECONDS]] [--require-topic]", file=sys.stderr)
        return 2
    topic = args[0]
    settle = next((f for f in flags if f.startswith("--settle")), None)
    cap = int(settle.split("=", 1)[1]) if settle and "=" in settle else 120
    require = "--require-topic" in flags

    from confluent_kafka import Consumer

    bootstrap = json.loads(MANIFEST.read_text())["measurement"]["kafka"]["bootstrap"]
    consumer = Consumer({"bootstrap.servers": bootstrap, "group.id": "kafka-offsets-probe"})
    try:
        total = read_total(consumer, topic)
        if total is None:
            # Absent is normally zero: nothing has been produced yet, which is
            # what a before-reading wants to say. But a caller measuring a topic
            # it believes exists needs to know the difference, because a wrong
            # topic name otherwise reads as an ingress that accepted nothing.
            if require:
                print(f"topic {topic!r} does not exist on the broker", file=sys.stderr)
                return 3
            print(0)
            return 0

        if settle:
            # Poll until two consecutive reads agree. Drain time grows exactly
            # at the rate where the system stops keeping up, so a fixed pause
            # under-reports the rung that matters and spills its backlog into
            # the next one. Capped, so a stuck pipeline cannot hang a sweep.
            #
            # KNOWN LIMIT: this settles only on a topic that goes quiet.
            # Simulated devices emit background syslog and traps on their own
            # interval, so on such a topic the offset always advances, the cap
            # is always reached, and this degrades to a fixed wait that says so.
            # That is no worse than pausing, and it is honest about it, but
            # separating backlog drain from steady background traffic needs a
            # rate threshold rather than an equality test.
            deadline = time.monotonic() + cap
            while time.monotonic() < deadline:
                time.sleep(POLL_SECONDS)
                current = read_total(consumer, topic)
                if current == total:
                    break
                total = current
            else:
                print(
                    f"still advancing after {cap}s; reporting the last read. On a topic with\n"
                    f"background traffic this is expected and the value is a fixed-window read.",
                    file=sys.stderr,
                )
        print(total)
    finally:
        consumer.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
