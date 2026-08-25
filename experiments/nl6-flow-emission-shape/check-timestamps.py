#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
"""Do exported NetFlow v9 records claim a LAST_SWITCHED after the datagram's own SysUptime?

A record whose last-packet time is ahead of the exporter's uptime at export is
not merely odd: a collector computing `flowEnd = exportTime - (sysUptime -
lastSwitched)` gets a timestamp in the future, and any bytes-per-second derived
from the flow's own duration is wrong.

Template-aware, because the field offsets are not fixed: the template flowset is
read from the capture and the data records decoded against it.
"""

import struct
import sys

LINK_HEADER_LEN = {1: 14, 113: 16, 276: 20}
FIRST_SWITCHED, LAST_SWITCHED = 22, 21


def payloads(path):
    with open(path, "rb") as fh:
        gh = fh.read(24)
        (magic,) = struct.unpack("<I", gh[:4])
        endian = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
        (linktype,) = struct.unpack(endian + "I", gh[20:24])
        off = LINK_HEADER_LEN.get(linktype, 0)
        while True:
            ph = fh.read(16)
            if len(ph) < 16:
                return
            _, _, incl, _ = struct.unpack(endian + "IIII", ph)
            data = fh.read(incl)
            if len(data) < incl:
                return
            ip = data[off:]
            if len(ip) < 20 or (ip[0] >> 4) != 4 or ip[9] != 17:
                continue
            udp = ip[(ip[0] & 0xF) * 4:]
            if len(udp) < 8:
                continue
            yield udp[8:]


def scan(path):
    templates = {}
    ahead = total = 0
    worst = 0
    for pl in payloads(path):
        if len(pl) < 20 or struct.unpack(">H", pl[:2])[0] != 9:
            continue
        sysuptime = struct.unpack(">I", pl[4:8])[0]
        pos = 20
        while pos + 4 <= len(pl):
            fsid, fslen = struct.unpack(">HH", pl[pos:pos + 4])
            if fslen < 4 or pos + fslen > len(pl):
                break
            body = pl[pos + 4:pos + fslen]
            if fsid == 0:                                   # template flowset
                p = 0
                while p + 4 <= len(body):
                    tid, cnt = struct.unpack(">HH", body[p:p + 4])
                    p += 4
                    fields = []
                    for _ in range(cnt):
                        if p + 4 > len(body):
                            break
                        ft, fl = struct.unpack(">HH", body[p:p + 4])
                        fields.append((ft, fl))
                        p += 4
                    templates[tid] = fields
            elif fsid >= 256 and fsid in templates:         # data flowset
                fields = templates[fsid]
                rec_len = sum(fl for _, fl in fields)
                if rec_len:
                    for r in range(len(body) // rec_len):
                        rec = body[r * rec_len:(r + 1) * rec_len]
                        o = 0
                        for ft, fl in fields:
                            if ft == LAST_SWITCHED and fl == 4:
                                last = struct.unpack(">I", rec[o:o + 4])[0]
                                total += 1
                                if last > sysuptime:
                                    ahead += 1
                                    worst = max(worst, last - sysuptime)
                            o += fl
            pos += fslen
    return total, ahead, worst


if __name__ == "__main__":
    for path in sys.argv[1:]:
        total, ahead, worst = scan(path)
        if not total:
            print(f"{path}: no decodable data records")
            continue
        print(f"{path.split('/')[-1]:<24} records={total:<6} "
              f"LAST_SWITCHED ahead of SysUptime: {ahead:<6} ({100*ahead/total:5.1f}%)  "
              f"max ahead: {worst/1000:.1f}s")
