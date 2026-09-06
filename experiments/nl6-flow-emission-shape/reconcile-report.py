#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
"""Reconcile a scenario report's ledger against a capture of the same run.

nl6#463 asked whether a scenario report's `achieved_per_device` undercounts what
leaves the devices. Answering that needs a comparison the earlier analysis could
not make: the report counts records inside `[T0,T1)`, so the wire has to be
counted over `[T0,T1)` too. Dividing a whole-capture record count by the capture
span compares two different quantities, and the sign of the disagreement is set
by how much capture sits outside the window -- not by anything the exporter did.

So this tool buckets wire records against the report's OWN `t0` / `t1` /
`drain_end` and compares bucket for bucket, fleet-wide and per device.

Two inputs, one run:

    sudo tcpdump -i <if> -w run.pcap 'udp port 2055' &
    curl -s localhost:8080/api/v1/loadtest/scenarios/<id>/report > run.report.json

The capture and the report must come from ONE run and ONE clock. If the capture
is taken on the collector host while the report comes from the emitter, skew
moves records across the bucket boundaries and this tool cannot tell that from
real out-of-window emission -- it warns when the edge buckets are non-empty, but
a warning is all it can offer. Capture on the emitting node.

Standard library only, matching the rest of this experiment.
"""

import importlib.util
import json
import os
import sys
from datetime import datetime

# The parser lives in analyse-pcap.py, whose hyphen makes it un-importable by
# name. It is imported anyway rather than re-implemented: template subtraction
# and fragment skipping are precisely what this experiment got wrong once
# already, and a second copy is a second chance to get it wrong differently.
_HERE = os.path.dirname(os.path.abspath(__file__))


def _load_datagrams():
    spec = importlib.util.spec_from_file_location(
        "analyse_pcap", os.path.join(_HERE, "analyse-pcap.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.datagrams


NETFLOW_V9 = 9


def parse_ts(text):
    """RFC3339 with milliseconds, as the report emits it."""
    # `fromisoformat` only learned to accept a `Z` suffix in 3.11.
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def bucket(rows, t0, t1, drain_end):
    """Split wire data records into the report's four regions.

    Returns {name: [records, template_datagrams]} plus a per-source-IP map of
    in-window records, which is what makes a disagreement attributable to a
    device instead of to the fleet.
    """
    regions = {
        "pre-T0": [0, 0],
        "in-window [T0,T1)": [0, 0],
        "drain [T1,drain_end)": [0, 0],
        "post-drain": [0, 0],
    }
    per_source = {}
    for timestamp, version, records, is_template, _, _, src in rows:
        if version != NETFLOW_V9:
            continue
        if timestamp < t0:
            name = "pre-T0"
        elif timestamp < t1:
            name = "in-window [T0,T1)"
            per_source[src] = per_source.get(src, 0) + records
        elif timestamp < drain_end:
            name = "drain [T1,drain_end)"
        else:
            name = "post-drain"
        regions[name][0] += records
        regions[name][1] += 1 if is_template else 0
    return regions, per_source


def main(pcap_path, report_path):
    datagrams = _load_datagrams()
    rows = list(datagrams(pcap_path))
    with open(report_path) as handle:
        report = json.load(handle)

    summary = report["summary"]
    meta = summary["metadata"]
    t0, t1 = parse_ts(meta["t0"]), parse_ts(meta["t1"])
    drain_end = parse_ts(meta["drain_end"])
    counters = report.get("counters", [])
    participants = len(counters) or 1
    window = t1 - t0

    regions, per_source = bucket(rows, t0, t1, drain_end)

    print(f"  window [T0,T1) = {window:.1f}s   drain barrier = {drain_end - t1:.3f}s   "
          f"participants = {participants}")
    print(f"  datagrams captured = {len(rows)}")
    print()
    print(f"  {'bucket':<24} {'WIRE':>8} {'LEDGER':>8} {'delta':>8} {'templates':>10}")

    ledger = {
        "in-window [T0,T1)": summary["in_window"],
        "drain [T1,drain_end)": summary["drain"],
    }
    for name, (records, templates) in regions.items():
        if name in ledger:
            delta = records - ledger[name]
            print(f"  {name:<24} {records:>8} {ledger[name]:>8} {delta:>+8} {templates:>10}")
        else:
            print(f"  {name:<24} {records:>8} {'-':>8} {'-':>8} {templates:>10}")

    in_window_wire = regions["in-window [T0,T1)"][0]
    in_window_delta = in_window_wire - summary["in_window"]
    drain_delta = regions["drain [T1,drain_end)"][0] - summary["drain"]

    # Per device. A fleet total can hide two devices disagreeing in opposite
    # directions; the report carries a per-source ledger, so use it.
    print()
    print("  per-device in-window:")
    mismatched = 0
    for entry in sorted(counters, key=lambda c: c.get("source_ip", "")):
        src = entry.get("source_ip", "?")
        wire = per_source.get(src, 0)
        delta = wire - entry["in_window"]
        mismatched += bool(delta)
        flag = "" if delta == 0 else "   <-- MISMATCH"
        print(f"    {src:<16} {wire:>7} {entry['in_window']:>7} {delta:>+7}{flag}")
    if not mismatched:
        print(f"    all {participants} device(s) agree")

    # The report's headline figure, recomputed from the wire.
    reported_rate = meta.get("rate", {}).get("achieved_per_device")
    if reported_rate is not None and window > 0:
        wire_rate = in_window_wire / window / participants
        print()
        print(f"  achieved_per_device:  wire {wire_rate:.4f}   report {reported_rate}   "
              f"delta {wire_rate - reported_rate:+.4f}")

    # The comparison this tool exists to replace, shown so a reader can see how
    # far off it lands on data where the ledger is provably exact.
    v9 = [r for r in rows if r[1] == NETFLOW_V9]
    if len(v9) > 1 and reported_rate is not None:
        span = v9[-1][0] - v9[0][0]
        raw = sum(n + (1 if t else 0) for _, _, n, t, _, _, _ in v9)  # header count
        span_rate = raw / span / participants if span > 0 else 0
        print()
        print("  span-wide comparison (the method nl6#463 was filed on):")
        print(f"    capture span {span:.1f}s vs window {window:.1f}s, "
              f"{raw} records incl. {raw - sum(r[0] for r in regions.values())} template phantoms")
        if span_rate:
            print(f"    wire rate/device {span_rate:.3f} vs report {reported_rate} "
                  f"-> {100.0 * (reported_rate - span_rate) / span_rate:+.1f}% apparent gap")

    edge = regions["pre-T0"][0] + regions["post-drain"][0]
    if edge:
        print()
        print(f"  NOTE: {edge} data record(s) fall outside [T0,drain_end). Either the fleet")
        print("        emitted outside the scenario window (expected without -fidelity, since")
        print("        the gate only suppresses while a scenario is installed), or the capture")
        print("        and the report came from different clocks. This tool cannot tell those")
        print("        apart -- capture on the emitting node and re-run if in doubt.")

    print()
    if in_window_delta == 0 and drain_delta == 0 and not mismatched:
        print("  VERDICT: ledger exact - every in-window record on the wire is accounted for.")
        return 0
    print(f"  VERDICT: ledger differs by {in_window_delta:+d} in-window record(s), "
          f"{drain_delta:+d} drain.")
    if in_window_delta > 0:
        print("           Wire exceeds ledger: records reached the collector that the report")
        print("           did not count. That is the undercount nl6#463 was filed to detect.")
    elif in_window_delta < 0:
        print("           Ledger exceeds wire: the report counted sends the capture did not")
        print("           see. Check capture loss first (analyse-pcap.py reports sequence")
        print("           continuity), then the send-failure accounting.")
    return 1


def retro(pcap_path, window, devices):
    """Reconcile a capture whose run kept no report, by inferring T1.

    The Part 2 cells predate the habit of saving the report, so their window
    boundary has to be recovered from the capture. A scenario stops emitting at
    T1 and the fleet resumes afterwards, which leaves a lull followed by a burst:
    the split is taken at the LARGEST inter-datagram gap occurring past 80 % of
    the window.

    That is a heuristic and is labelled as one. What makes it credible is that
    the rule was fixed before the comparison rather than fitted to it, and that
    all four Part 2 cells then land on their published `achieved_per_device` to
    the precision it was printed at.
    """
    datagrams = _load_datagrams()
    rows = [r for r in datagrams(pcap_path) if r[1] == NETFLOW_V9 and r[2] > 0]
    if len(rows) < 2:
        print(f"{pcap_path}: too few data-bearing datagrams", file=sys.stderr)
        return 2

    start = rows[0][0]
    total = sum(r[2] for r in rows)
    candidates = [
        (rows[i + 1][0] - rows[i][0], i)
        for i in range(len(rows) - 1)
        if rows[i][0] - start > window * 0.8
    ]
    if not candidates:
        print(f"{pcap_path}: no post-window lull found; capture may end at T1")
        tail, lull = 0, 0.0
    else:
        lull, index = max(candidates)
        tail = sum(r[2] for r in rows[index + 1:])

    in_window = total - tail
    print(f"  {os.path.basename(pcap_path)}")
    print(f"    data records {total}   after-window {tail}   in-window {in_window}")
    print(f"    lull before the post-window burst: {lull:.1f}s")
    print(f"    in-window / {window:.0f}s / {devices} = {in_window / window / devices:.4f} rec/s/device")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if len(args) == 2 and not args[1].startswith("-"):
        raise SystemExit(main(args[0], args[1]))
    if len(args) == 3 and args[1] == "--retro":
        # <pcap> --retro <window_seconds>:<devices>
        window, _, devices = args[2].partition(":")
        try:
            raise SystemExit(retro(args[0], float(window), int(devices or 1)))
        except ValueError:
            print(f"--retro takes <window_seconds>:<devices>, got {args[2]!r}", file=sys.stderr)
            raise SystemExit(2) from None
    print(
        f"usage: {sys.argv[0]} <capture.pcap> <report.json>\n"
        f"       {sys.argv[0]} <capture.pcap> --retro <window_seconds>:<devices>",
        file=sys.stderr,
    )
    raise SystemExit(2)
