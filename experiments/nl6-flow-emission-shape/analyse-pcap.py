#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
"""Parse a pcap of NetFlow v9 datagrams: per-datagram record counts + timing.
Pure stdlib so the analysis can be re-run anywhere without a toolchain."""
import struct, sys, collections

def datagrams(path):
    with open(path, 'rb') as f:
        gh = f.read(24)
        magic, = struct.unpack('<I', gh[:4])
        endian = '<' if magic in (0xa1b2c3d4, 0xa1b23c4d) else '>'
        nano = magic in (0xa1b23c4d, 0x4d3cb2a1)
        linktype, = struct.unpack(endian+'I', gh[20:24])
        while True:
            ph = f.read(16)
            if len(ph) < 16: return
            ts_s, ts_f, incl, orig = struct.unpack(endian+'IIII', ph)
            data = f.read(incl)
            if len(data) < incl: return
            ts = ts_s + ts_f / (1e9 if nano else 1e6)
            # strip link layer
            if linktype == 113:      off = 16            # LINUX_SLL
            elif linktype == 276:    off = 20            # LINUX_SLL2
            elif linktype == 1:      off = 14            # Ethernet
            else:                    off = 0
            ip = data[off:]
            if len(ip) < 20 or (ip[0] >> 4) != 4: continue
            ihl = (ip[0] & 0xF) * 4
            if ip[9] != 17: continue                     # UDP
            udp = ip[ihl:]
            if len(udp) < 8: continue
            payload = udp[8:]
            if len(payload) < 4: continue
            ver, count = struct.unpack('>HH', payload[:4])
            # NetFlow v9 carries a per-exporter DATAGRAM sequence number at
            # offset 12. It is the instrument that separates "the generator
            # emitted less" from "the capture missed some" — without it a
            # shortfall cannot be attributed, and attributing it to the model
            # would bury a real loss signal.
            seq = struct.unpack('>I', payload[12:16])[0] if len(payload) >= 16 else None
            yield ts, ver, count, len(payload), seq

def report(path, tick):
    rows = list(datagrams(path))
    if not rows:
        print(f"{path}: NO DATAGRAMS"); return
    t0 = rows[0][0]; t1 = rows[-1][0]; span = max(t1 - t0, 1e-9)
    recs = sum(c for _, v, c, _, _ in rows if v == 9)
    # Recover the emission SHAPE by clustering datagrams into TICK GROUPS.
    # Fixed-width bucketing aligned to the first packet splits a single tick
    # across two buckets and invents a silent one; datagrams from one tick are
    # microseconds apart while ticks are seconds apart, so the gap separates
    # them unambiguously.
    series, skipped = [], 0
    cur = 0
    prev = None
    for ts, v, c, _, _ in rows:
        if v != 9: continue
        if prev is not None and (ts - prev) > tick * 0.5:
            series.append(cur); cur = 0
            # A gap spanning more than one tick period means ticks fired with
            # nothing to send. Count them as genuinely silent.
            skipped += max(0, int(round((ts - prev) / tick)) - 1)
        cur += c
        prev = ts
    series.append(cur)
    steady = series[1:-1] if len(series) > 2 else series
    silent = skipped
    mean = sum(steady)/len(steady) if steady else 0
    peak = max(steady) if steady else 0
    gaps = [rows[i+1][0]-rows[i][0] for i in range(len(rows)-1)]
    seqs = [s for _, v, _, _, s in rows if v == 9 and s is not None]
    lost = (seqs[-1] - seqs[0] + 1 - len(seqs)) if len(seqs) > 1 else 0
    print(f"  datagrams={len(rows)}  records={recs}  span={span:.1f}s")
    print(f"  rate={recs/span:.2f} rec/s   datagram rate={len(rows)/span:.2f}/s   "
          f"records/datagram={recs/len(rows):.1f}")
    print(f"  per-tick({tick}s): silent={silent}/{len(steady)+silent}  peak={peak}  mean={mean:.1f}  "
          f"peak/mean={(peak/mean if mean else 0):.2f}")
    print(f"  inter-datagram gap: max={max(gaps) if gaps else 0:.2f}s  "
          f"median={sorted(gaps)[len(gaps)//2] if gaps else 0:.3f}s")
    print(f"  shape: {series[1:15]}")
    verdict = "CAPTURE LOSS - rate is a floor, not a measurement" if lost else "sequence-continuous, no capture loss"
    print(f"  datagram sequence: {len(seqs)} seen, {lost} missing  -> {verdict}")

if __name__ == '__main__':
    report(sys.argv[1], float(sys.argv[2]))
