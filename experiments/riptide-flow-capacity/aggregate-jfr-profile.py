#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Aggregate `jfr print --events jdk.ExecutionSample` output into a CPU profile.

Reads the text form on stdin and reports three views:

  1. samples by thread          — which thread is burning the CPU
  2. hot leaf methods           — what the busiest thread is actually executing
  3. stack containment          — how much of that thread sits under a given
                                  subsystem, which is what separates "this thread
                                  is busy parsing" from "this thread is busy
                                  handing work off"

Written for the riptide flow-capacity experiments: view (2) is what identified
riptide#389, where 52% of the listener thread's samples were in
InetSocketAddress.equals and 17% in ConcurrentHashMap iteration — a linear scan,
not the queue handoff everyone assumed.

Usage:
    jfr print --events jdk.ExecutionSample probe.jfr | aggregate-jfr-profile.py
    gunzip -c profile.exec.txt.gz | aggregate-jfr-profile.py --thread udp-listener
"""
import argparse
import collections
import re
import sys

# Subsystems worth measuring containment for. Order matters: the first match on a
# frame wins, so put the specific ones before the generic ones.
CONTAINMENT = [
    "SynchronousQueue",
    "ThreadPoolExecutor",
    "UdpSessionManager",
    "lookupOptions",
    "Template",
    "Pipeline",
    "Enricher",
    "Repository",
    "parse",
    "InetSocketAddress",
    "ConcurrentHashMap",
]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--thread", default=None,
                    help="thread-name prefix to drill into (default: the busiest thread)")
    ap.add_argument("--top", type=int, default=15, help="rows per section (default 15)")
    args = ap.parse_args()

    text = sys.stdin.read()
    blocks = text.split("jdk.ExecutionSample {")[1:]
    if not blocks:
        print("no jdk.ExecutionSample events on stdin", file=sys.stderr)
        return 1

    by_thread = collections.Counter()
    parsed = []  # (thread, [frames]) with frames[0] == leaf
    for block in blocks:
        m = re.search(r'sampledThread\s*=\s*"([^"]+)"', block)
        thread = m.group(1) if m else "?"
        by_thread[thread] += 1

        frames = []
        parts = block.split("stackTrace = [", 1)
        if len(parts) > 1:
            for line in parts[1].splitlines():
                line = line.strip()
                if line.startswith("]"):
                    break
                if line and not line.startswith("..."):
                    frames.append(re.sub(r"\s+line:.*$", "", line))
        parsed.append((thread, frames))

    total = sum(by_thread.values())
    print(f"\n=== CPU samples by thread (total {total}) ===")
    for thread, count in by_thread.most_common(args.top):
        print(f"  {count:6d} ({100 * count / total:5.1f}%)  {thread}")

    target = args.thread or by_thread.most_common(1)[0][0]
    selected = [frames for thread, frames in parsed if thread.startswith(target)]
    n = len(selected)
    if not n:
        print(f"\nno samples for thread prefix {target!r}", file=sys.stderr)
        return 1

    print(f"\n=== hot leaf methods on {target!r} ({n} samples, "
          f"{100 * n / total:.1f}% of all CPU) ===")
    leaves = collections.Counter(f[0] for f in selected if f)
    for frame, count in leaves.most_common(args.top):
        print(f"  {count:6d} ({100 * count / n:5.1f}%)  {frame}")

    print(f"\n=== stack containment on {target!r} (first match per sample) ===")
    contained = collections.Counter()
    for frames in selected:
        for frame in frames:
            hit = next((k for k in CONTAINMENT if k in frame), None)
            if hit:
                contained[hit] += 1
                break
    if not contained:
        print("  (no configured subsystem matched — extend CONTAINMENT)")
    for key, count in contained.most_common():
        print(f"  {key:<22s} {count:6d} ({100 * count / n:5.1f}%)")

    print("\nReading guide: a single thread holding a large share of total samples with"
          "\nits leaves in collection/equality methods means O(n) work on that thread —"
          "\nadding downstream parallelism will not help. Compare against the per-thread"
          "\nCPU table: workers idle + one hot thread is the signature.\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
