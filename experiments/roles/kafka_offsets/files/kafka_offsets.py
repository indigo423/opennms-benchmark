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


def main(argv):
    if len(argv) != 2:
        print("usage: kafka_offsets.py <topic>", file=sys.stderr)
        return 2
    topic = argv[1]

    from confluent_kafka import Consumer, TopicPartition

    bootstrap = json.loads(MANIFEST.read_text())["measurement"]["kafka"]["bootstrap"]
    consumer = Consumer({"bootstrap.servers": bootstrap, "group.id": "kafka-offsets-probe"})
    try:
        meta = consumer.list_topics(topic, timeout=10)
        if topic not in meta.topics or meta.topics[topic].error:
            # An absent topic is zero, not an error: nothing has been produced
            # to it yet, which is exactly what a before-reading wants to say.
            print(0)
            return 0
        total = 0
        for part in meta.topics[topic].partitions:
            _, high = consumer.get_watermark_offsets(TopicPartition(topic, part), timeout=10, cached=False)
            total += high
        print(total)
    finally:
        consumer.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
