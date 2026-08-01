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
from pathlib import Path

MANIFEST = Path("/etc/lab-endpoints.json")


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
        print("usage: kafka_offsets.py <topic> [--require-topic]", file=sys.stderr)
        return 2
    topic = args[0]
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

        print(total)
    finally:
        consumer.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
