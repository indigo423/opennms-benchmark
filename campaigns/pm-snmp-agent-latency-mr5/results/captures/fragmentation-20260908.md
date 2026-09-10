# SNMP datagram size and IP fragmentation on the wire

Capture taken 2026-09-08 14:15 UTC on `minion-benchmark-01`, interface `enp6s20`
(the path to the simulator, `10.42.0.0/16 via 192.0.2.152`), MTU 1500.

Lab state at capture time: the 16 GiB Core at 11,000 nl6 devices, `max-repetitions=5`
for `10.42.0.0/16`, `netem delay 75ms 25ms`, the same `cisco_crs_x` device shape with
144 interfaces as this report's search. The fleet size differs from every rung here;
datagram size does not depend on it.

    sudo tcpdump -ni enp6s20 -s 64 -w snmp30.pcap 'net 10.42.0.0/16'      # 31.9 s
    sudo tcpdump -ni enp6s20 -s 0 -c 4000 'udp src port 161' -w full.pcap

## Volume

    31.9 s, 244,801 packets, 7,682 pkt/s
    83,027 requests   (Minion -> agent, udp/161)
    83,009 responses  (agent -> Minion)

## Fragmentation

    more-fragments bit set     0
    non-zero fragment offset   0
    don't-fragment bit set     83,009 / 83,009 responses (100%)
                               83,027 / 83,027 requests  (100%)

No IP fragmentation on the SNMP path. DF is set on every SNMP datagram in both
directions, so these datagrams cannot be fragmented in flight even if they were
large enough: an oversized one fails at the sender with EMSGSIZE, or is dropped by
a router which returns ICMP fragmentation-needed. The failure mode is loss, not
fragmentation.

## Response size, 83,009 responses

    min 147   p50 1,125   p90 1,163   p99 1,221   max 1,221 B   (IP total length)
    mean 1,032 B
    largest = 81.4% of the 1500 B MTU; 279 B of headroom
    responses over the 1,472 B UDP payload budget: 0
    responses over the 1500 B MTU:                 0

## Varbinds per response, 4,000 full-payload responses

    50 varbinds  3,100  77.5%   full GETBULK: 10 columns x max-repetitions 5
    25 varbinds    630  15.8%
    10 varbinds    180   4.5%
     5 varbinds     90   2.2%

The short responses are end-of-table, not size truncation: they are 500-700 B, far
under the budget. No response in this capture was truncated by the datagram limit.

Full 50-varbind responses: min 980, p50 1,066, max 1,174 B of SNMP message,
about 22.7 B per varbind.

## Where the ceiling is

Extrapolating the largest full response at ~22.7 B per varbind, 10 columns per PDU:

    max-repetitions  2 ->  20 varbinds ->   522 B datagram   fits
    max-repetitions  5 ->  50 varbinds -> 1,202 B datagram   fits (measured max 1,221)
    max-repetitions  6 ->  60 varbinds -> 1,429 B datagram   fits, ~70 B spare
    max-repetitions  7 ->  70 varbinds -> 1,656 B datagram   EXCEEDS the 1500 B MTU
    max-repetitions 10 -> 100 varbinds -> 2,336 B datagram   EXCEEDS

6 is the last value that fits for this device shape on a 1500 B MTU. Estimated from
one device shape's encoded size; a device with longer interface names or more columns
per PDU reaches the ceiling sooner.
