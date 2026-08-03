#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Count SNMP traps on the Minion's Kafka sink topic, and measure how far behind
# the Minion was when it published them.
#
# Why this exists: in a deployment with no Core there is no events table, so the
# topic is the only record of what the Minion accepted. An offset delta cannot
# stand in for a trap count — one Kafka message carries a TrapLogDTO wrapping a
# *list* of traps, and the batch factor is not a constant (#215).
#
# It tracks the PER-DEVICE rate, not the fleet-wide one, because the DTO
# envelope carries a single trap-address: traps batch per source, so the factor
# is roughly per_device_rate x batch-interval (500 ms by default). Measured
# here, all four points fitting that model:
#
#     5/device, 100 devices,    500/s fleet ->  3.6 traps/message
#    50/device, 100 devices,  5,000/s fleet -> 26.4
#    50/device,  10 devices,    500/s fleet -> 25.5
#    50/device,  10 devices,    500/s fleet -> 25.8
#
# Note rows two and three: the same fleet-wide rate gives 26.4 or 3.6 depending
# only on how the load is spread. Counting messages would under-report by 26x in
# one case and 3.6x in the other, so the error moves with the fleet shape as
# well as the rate.
#
# The payload is a protobuf envelope wrapping XML, not the protobuf body the
# public documentation describes, so no .proto and no generated stubs are
# needed: one <messages> element is one trap.
#
#   <trap-message-log system-id=".." location=".." trap-address="..">
#      <messages>
#         <agent-address>10.42.0.46</agent-address>
#         <creation-time>1785795382514</creation-time>
#         ...
#      </messages>
#   </trap-message-log>
#
# creation-time is stamped by the Minion when it built the DTO. Against the
# broker's record timestamp it gives Minion-to-Kafka latency, which is what
# replaces eventcreatetime once PostgreSQL is out of the picture: it separates
# "the topic eventually received everything" from "the Minion kept up".
import argparse
import json
import re
import sys
import time
from pathlib import Path

MANIFEST = Path("/etc/lab-endpoints.json")

# Counted as bytes against the raw payload rather than parsed as XML. The body
# is not always well-formed on its own: OpenNMS splits oversized payloads into
# chunks itself and reassembles them consumer-side, so a chunk can carry a
# fragment. Counting a tag that cannot straddle a split is robust to that;
# unterminated payloads are reported separately rather than silently tolerated.
TRAP_TAG = b"<messages>"
LOG_OPEN = b"<trap-message-log"
LOG_CLOSE = b"</trap-message-log>"
CREATION = re.compile(rb"<creation-time>(\d+)</creation-time>")


def bootstrap():
    return json.loads(MANIFEST.read_text())["measurement"]["kafka"]["bootstrap"]


def end_offsets(consumer, topic):
    from confluent_kafka import TopicPartition

    meta = consumer.list_topics(topic, timeout=10)
    if topic not in meta.topics or meta.topics[topic].error:
        return None
    out = {}
    for p in meta.topics[topic].partitions:
        _, hi = consumer.get_watermark_offsets(TopicPartition(topic, p), timeout=10, cached=False)
        out[str(p)] = hi
    return out


def percentile(values, q):
    if not values:
        return None
    s = sorted(values)
    i = min(int(round((len(s) - 1) * q)), len(s) - 1)
    return s[i]


def main(argv=None):
    ap = argparse.ArgumentParser(description="Count SNMP traps on the Kafka sink topic")
    ap.add_argument("--topic", default="OpenNMS.Sink.Trap")
    ap.add_argument("--group", default="kafka-trap-report")
    ap.add_argument("--snapshot", metavar="FILE",
                    help="write current end offsets and exit; the start of a measurement bracket")
    ap.add_argument("--start-offsets", metavar="FILE",
                    help="count from these offsets to the current end")
    ap.add_argument("--label", default="")
    ap.add_argument("--window-seconds", type=float,
                    help="the interval load was actually offered over; without it the rate is "
                         "computed across the record-timestamp span, which the fleet's background "
                         "traffic dilutes at both edges of the bracket")
    ap.add_argument("--json", metavar="FILE")
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="seconds to wait for a poll before deciding the range is drained")
    args = ap.parse_args(argv)

    from confluent_kafka import Consumer, TopicPartition

    consumer = Consumer({
        "bootstrap.servers": bootstrap(),
        "group.id": args.group,
        "enable.auto.commit": False,
        "auto.offset.reset": "earliest",
    })
    try:
        ends = end_offsets(consumer, args.topic)
        if ends is None:
            print(f"topic {args.topic!r} does not exist on the broker", file=sys.stderr)
            return 3

        if args.snapshot:
            Path(args.snapshot).write_text(json.dumps(ends))
            print(f"snapshot {sum(ends.values())} offsets across {len(ends)} partition(s) -> {args.snapshot}")
            return 0

        if not args.start_offsets:
            print("need --snapshot or --start-offsets; refusing to read a whole topic by accident",
                  file=sys.stderr)
            return 2

        starts = json.loads(Path(args.start_offsets).read_text())
        # A partition present now but absent from the snapshot is read from its
        # beginning: it was created after the bracket opened, so everything in
        # it belongs to the bracket.
        assign, pending = [], 0
        for p, hi in ends.items():
            lo = int(starts.get(p, 0))
            if hi > lo:
                assign.append(TopicPartition(args.topic, int(p), lo))
                pending += hi - lo
        if not assign:
            print("no new messages in the bracket", file=sys.stderr)

        consumer.assign(assign)
        traps = messages = truncated = 0
        lags, first_ts, last_ts = [], None, None
        seen = 0
        deadline = time.time() + args.timeout
        while seen < pending and time.time() < deadline:
            m = consumer.poll(1.0)
            if m is None:
                continue
            if m.error():
                continue
            seen += 1
            deadline = time.time() + args.timeout
            v = m.value() or b""
            messages += 1
            n = v.count(TRAP_TAG)
            traps += n
            # A payload that opens the log but never closes it is a chunk, and a
            # trap tag could straddle the split. Counted so a silent undercount
            # cannot masquerade as loss.
            if v.count(LOG_OPEN) and not v.count(LOG_CLOSE):
                truncated += 1
            _, ts = m.timestamp()
            if ts and ts > 0:
                first_ts = ts if first_ts is None else min(first_ts, ts)
                last_ts = ts if last_ts is None else max(last_ts, ts)
                for cm in CREATION.finditer(v):
                    lags.append((ts - int(cm.group(1))) / 1000.0)

        span = (last_ts - first_ts) / 1000.0 if first_ts and last_ts else 0.0
        # Rated against the interval load was offered over, not the span of
        # record timestamps. The bracket opens before the burst and closes after
        # it, and the fleet emits continuously, so background records at both
        # edges stretch the span and understate the rate — measured at 264/s for
        # a burst offered at 5,000/s. The same denominator mistake cost a full
        # re-run of the trap capacity sweep; see FINDINGS.md defect 12.
        rate_basis = args.window_seconds if args.window_seconds else span
        out = {
            "label": args.label,
            "topic": args.topic,
            "traps": traps,
            "messages": messages,
            "traps_per_message": round(traps / messages, 2) if messages else 0,
            "truncated_payloads": truncated,
            "expected_messages": pending,
            "span_seconds": round(span, 1),
            "rate_basis": "offered window" if args.window_seconds else "record-timestamp span",
            "rate_basis_seconds": round(rate_basis, 1) if rate_basis else None,
            "traps_per_second": round(traps / rate_basis) if rate_basis and rate_basis > 0 else None,
            "publish_lag_seconds": {
                "p50": percentile(lags, 0.50),
                "p99": percentile(lags, 0.99),
                "max": max(lags) if lags else None,
                "samples": len(lags),
            },
        }
        if args.json:
            Path(args.json).write_text(json.dumps(out, indent=2))
        lag = out["publish_lag_seconds"]
        print(f"{args.label + ': ' if args.label else ''}"
              f"traps={traps:,} messages={messages:,} "
              f"traps/msg={out['traps_per_message']} "
              f"span={out['span_seconds']}s "
              f"rate={out['traps_per_second']}/s ({out['rate_basis']}) "
              f"lag_p50={lag['p50']}s lag_p99={lag['p99']}s")
        if truncated:
            print(f"WARNING {truncated} payload(s) opened a trap-message-log without closing it; "
                  f"chunked messages may split a trap tag and undercount", file=sys.stderr)
        if seen < pending:
            print(f"WARNING read {seen} of {pending} expected messages before the "
                  f"{args.timeout}s poll timeout; the count is short", file=sys.stderr)
            return 1
        return 0
    finally:
        consumer.close()


if __name__ == "__main__":
    sys.exit(main())
