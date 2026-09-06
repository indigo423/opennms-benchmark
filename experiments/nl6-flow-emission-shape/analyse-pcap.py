#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
"""Parse a pcap of NetFlow v9 datagrams: per-datagram record counts + timing.

Standard library only, so the captures can be re-analysed anywhere without a
toolchain -- no tshark, no scapy.
"""

import struct
import sys

# pcap global-header magics. The 3c4d variants carry nanosecond timestamps.
MAGIC_US_LE = 0xA1B2C3D4
MAGIC_NS_LE = 0xA1B23C4D
MAGIC_NS_BE = 0x4D3CB2A1

# Link-layer header sizes by pcap linktype.
LINK_HEADER_LEN = {
    1: 14,  # Ethernet
    113: 16,  # LINUX_SLL   (tcpdump -i any)
    276: 20,  # LINUX_SLL2
}

NETFLOW_V9 = 9
PROTO_UDP = 17

# A NetFlow v9 Template FlowSet has FlowSet ID 0 (RFC 3954 §5.2). The first
# FlowSet ID sits at a fixed offset in the datagram, immediately after the
# 20-byte header.
V9_FIRST_FLOWSET_ID_OFFSET = 20
V9_TEMPLATE_FLOWSET_ID = 0


def datagrams(path):
    """Yield one tuple per NetFlow datagram.

    (timestamp, version, data_records, is_template, payload_len, sequence, source_ip)

    Two things this deliberately does NOT report raw.

    `data_records` is the header count MINUS the template. RFC 3954 §5.1 defines
    the header `count` as the number of FlowSet records, and a Template FlowSet
    is one of them -- nl6's encoder does `count := len(records); if
    includeTemplate { count++ }`. Summing the raw field therefore counts one
    record per template that carries no flow data. The inflation is inversely
    proportional to rate, because the template cadence is fixed while the record
    count is not: measured across the captures here it runs 0.23% at rate 8 and
    3.15% at rate 0.5. That was the largest identified term in nl6#463, where a
    scenario report appeared to read 3-8% below "the wire" -- the wire figure was
    over-counted.

    Non-first IP fragments are skipped. Every fragment carries the IP protocol
    field, so the old filter admitted them, and each one arrived microseconds
    after its first fragment: they inflated the datagram count, deflated
    records/datagram, and injected spurious near-zero inter-datagram gaps. Their
    payload is not a v9 header, so the version check kept them out of the record
    sum -- which is exactly why this went unnoticed. Captures taken before
    nl6#485 are heavily affected; s6-rate8-w120.pcap is 41% fragmented.
    """
    with open(path, "rb") as handle:
        global_header = handle.read(24)
        (magic,) = struct.unpack("<I", global_header[:4])
        endian = "<" if magic in (MAGIC_US_LE, MAGIC_NS_LE) else ">"
        nanos = magic in (MAGIC_NS_LE, MAGIC_NS_BE)
        (linktype,) = struct.unpack(endian + "I", global_header[20:24])
        offset = LINK_HEADER_LEN.get(linktype, 0)

        while True:
            record_header = handle.read(16)
            if len(record_header) < 16:
                return
            ts_sec, ts_frac, incl_len, _ = struct.unpack(endian + "IIII", record_header)
            data = handle.read(incl_len)
            if len(data) < incl_len:
                return

            timestamp = ts_sec + ts_frac / (1e9 if nanos else 1e6)
            ip = data[offset:]
            if len(ip) < 20 or (ip[0] >> 4) != 4 or ip[9] != PROTO_UDP:
                continue
            # Non-first fragment: no UDP header, no v9 header, not a datagram.
            (flags_frag,) = struct.unpack(">H", ip[6:8])
            if flags_frag & 0x1FFF:
                continue
            udp = ip[(ip[0] & 0xF) * 4:]
            if len(udp) < 8:
                continue
            payload = udp[8:]
            if len(payload) < 4:
                continue

            version, count = struct.unpack(">HH", payload[:4])

            # Subtract the Template FlowSet from the record count when present.
            # Readable even in a fragmented capture: the first FlowSet ID is at
            # a fixed offset inside the FIRST fragment, so this needs none of
            # the FlowSet walking that fragmentation actually blocks.
            is_template = False
            if version == NETFLOW_V9 and len(payload) >= V9_FIRST_FLOWSET_ID_OFFSET + 2:
                (first_flowset,) = struct.unpack(
                    ">H", payload[V9_FIRST_FLOWSET_ID_OFFSET:V9_FIRST_FLOWSET_ID_OFFSET + 2]
                )
                is_template = first_flowset == V9_TEMPLATE_FLOWSET_ID
            data_records = count - 1 if is_template else count
            # NetFlow v9 carries a per-exporter DATAGRAM sequence number at
            # offset 12. It is the instrument that separates "the generator
            # emitted less" from "the capture missed some" -- without it a
            # shortfall cannot be attributed, and blaming the emission model
            # would bury a real loss signal.
            sequence = None
            if len(payload) >= 16:
                (sequence,) = struct.unpack(">I", payload[12:16])
            src = ".".join(str(b) for b in ip[12:16])
            yield timestamp, version, data_records, is_template, len(payload), sequence, src


def tick_groups(rows, tick):
    """Cluster datagrams into per-tick record counts, plus the count of silent ticks.

    Fixed-width bucketing aligned to the first packet splits one tick across two
    buckets and invents a silent tick that did not occur. Datagrams from a single
    tick are microseconds apart while ticks are seconds apart, so the gap
    separates them unambiguously.
    """
    series = []
    skipped = 0
    current = 0
    previous = None

    for timestamp, version, data_records, _is_template, _, _, _ in rows:
        if version != NETFLOW_V9:
            continue
        # A template-only datagram carries no flow data. Counting it here would
        # mark a tick that emitted NOTHING as occupied, so it would not register
        # as silent -- turning the headline output of a shape experiment into a
        # wrong answer rather than an imprecise one. Visible in this
        # experiment's own pre-fix series as the `1`s among ticks of 128.
        if data_records == 0:
            continue
        if previous is not None and (timestamp - previous) > tick * 0.5:
            series.append(current)
            current = 0
            # A gap spanning more than one tick period means ticks fired with
            # nothing to send. Those are genuinely silent.
            skipped += max(0, int(round((timestamp - previous) / tick)) - 1)
        current += data_records
        previous = timestamp

    series.append(current)
    return series, skipped


def report(path, tick):
    rows = list(datagrams(path))
    if not rows:
        print(f"{path}: NO DATAGRAMS")
        return

    span = max(rows[-1][0] - rows[0][0], 1e-9)
    records = sum(n for _, ver, n, _, _, _, _ in rows if ver == NETFLOW_V9)
    templates = sum(1 for _, ver, _, t, _, _, _ in rows if ver == NETFLOW_V9 and t)

    series, silent = tick_groups(rows, tick)
    steady = series[1:-1] if len(series) > 2 else series
    mean = sum(steady) / len(steady) if steady else 0
    peak = max(steady) if steady else 0
    peak_ratio = peak / mean if mean else 0

    gaps = [rows[i + 1][0] - rows[i][0] for i in range(len(rows) - 1)]
    max_gap = max(gaps) if gaps else 0
    median_gap = sorted(gaps)[len(gaps) // 2] if gaps else 0

    # Sequence numbers are PER EXPORTER. Pooling several devices' counters
    # produces a meaningless figure — a multi-device capture reported "-93
    # missing", a negative loss, which is how this was found. Group by source.
    per_source = {}
    for _, ver, _, _, _, seq, src in rows:
        if ver == NETFLOW_V9 and seq is not None:
            per_source.setdefault(src, []).append(seq)
    lost = 0
    for seqs in per_source.values():
        if len(seqs) > 1:
            lost += max(0, max(seqs) - min(seqs) + 1 - len(seqs))
    sequences = [s for seqs in per_source.values() for s in seqs]
    if lost:
        verdict = "CAPTURE LOSS - the rate is a floor, not a measurement"
    else:
        verdict = "sequence-continuous, no capture loss"

    print(f"  datagrams={len(rows)}  records={records}  templates={templates}  span={span:.1f}s")
    print(
        f"  rate={records / span:.2f} rec/s   datagram rate={len(rows) / span:.2f}/s   "
        f"records/datagram={records / len(rows):.1f}"
    )
    print(
        f"  per-tick({tick}s): silent={silent}/{len(steady) + silent}  peak={peak}  "
        f"mean={mean:.1f}  peak/mean={peak_ratio:.2f}"
    )
    print(f"  inter-datagram gap: max={max_gap:.2f}s  median={median_gap:.3f}s")
    print(f"  shape: {series[1:15]}")
    print(f"  datagram sequence: {len(sequences)} seen across {len(per_source)} exporter(s), "
          f"{lost} missing  -> {verdict}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <capture.pcap> <tick_seconds>", file=sys.stderr)
        raise SystemExit(2)
    report(sys.argv[1], float(sys.argv[2]))
