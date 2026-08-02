#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Sum the end offsets of a topic and print the total, or with --lag=<group>,
# the summed consumer lag for that group.
#
# Exists so an experiment can read the accepted side without SSH-ing to the
# broker. Delegating to the broker means a fresh connection through the jump
# host for every read, and a rate sweep does that often enough that a dropped
# ControlPersist session fails the run partway through, discarding the rungs
# already measured.
#
# Lag, not the offset delta, is what a capacity benchmark reads on a sink topic.
# The sink batches at a rate-dependent size, so the offset delta counts Kafka
# messages rather than the traps or syslog messages inside them and cannot be
# compared against a generator's ledger (#215). Lag is immune: it is a backlog
# measure whatever the batch size. It is also the only honest drain signal here
# — the simulated fleet emits continuously, so "wait until the count stops
# moving" never fires, and a fixed pause either overshoots or truncates.
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


def read_lag(consumer, topic):
    """Summed lag over every partition, or None if the topic does not exist.

    The consumer is constructed in the group being measured but never
    subscribes, so it queries the coordinator for committed offsets without
    joining and cannot trigger a rebalance of the daemon it is watching.
    """
    from confluent_kafka import TopicPartition

    meta = consumer.list_topics(topic, timeout=10)
    if topic not in meta.topics or meta.topics[topic].error:
        return None

    parts = [TopicPartition(topic, p) for p in meta.topics[topic].partitions]
    committed = consumer.committed(parts, timeout=10)

    total = 0
    for tp in committed:
        _, high = consumer.get_watermark_offsets(tp, timeout=10, cached=False)
        # A partition the group has never committed to reports OFFSET_INVALID
        # (-1001). Counting that as lag == high would report the entire topic
        # history as backlog on the first read of a fresh group, which reads as
        # a catastrophically behind consumer when nothing is wrong.
        if tp.offset < 0:
            continue
        total += max(high - tp.offset, 0)
    return total


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    flags = {a for a in argv[1:] if a.startswith("--")}
    if len(args) != 1:
        print("usage: kafka_offsets.py <topic> [--require-topic] [--lag=<group>]", file=sys.stderr)
        return 2
    topic = args[0]
    require = "--require-topic" in flags
    # --lag=<group> rather than a positional: the caller is always reading one
    # topic, and a bare second positional would make "kafka-offsets A B" ambiguous
    # between two topics and a topic plus a group.
    group = next((f.split("=", 1)[1] for f in flags if f.startswith("--lag=")), None)
    if group is not None and not group:
        print("--lag= requires a consumer group name", file=sys.stderr)
        return 2

    from confluent_kafka import Consumer

    bootstrap = json.loads(MANIFEST.read_text())["measurement"]["kafka"]["bootstrap"]
    consumer = Consumer({"bootstrap.servers": bootstrap, "group.id": group or "kafka-offsets-probe"})
    try:
        total = read_lag(consumer, topic) if group else read_total(consumer, topic)
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
