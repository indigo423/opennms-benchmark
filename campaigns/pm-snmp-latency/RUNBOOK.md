---
title: SNMP latency injection measurement
description: Measure how the sizing floor moves when SNMP responses carry realistic latency instead of the simulator's in-memory microsecond answers
date: 2026-09-01
---

# SNMP latency injection — measurement runbook

## The question

The 72M metrics/hour baseline was measured against nl6 agents that answer from memory in
microseconds, never time out and never vary. That is the report's own central caveat. This
measurement replaces the microsecond answer with a realistic per-PDU delay and finds where
the current configuration stops keeping up.

**Research backing:** `_bmad-output/planning-artifacts/research/technical-snmp-agent-response-latency-modelling-2026-09-01/research.md`.
Headline: no published distribution for SNMP agent response time exists — RFC 5345 (2008)
and the 2009 survey both record it as an open question. Three independent bodies of evidence
converge on the *shape* (tight mode, heavy right tail), and cross-device variance dominates
within-device jitter. Parameters below are therefore **stated assumptions to be swept**, not
measured facts.

## Why `tc` and not the simulator

nl6 has **no latency injection**. Verified 2026-09-01: no delay/latency/jitter field in the
per-device API schema, nothing in the upstream repository. The `"interface": "simNNNN"` field
in the device JSON is an nl6-internal label, **not** a Linux netdev — the container namespace
has a single `sim` interface, so per-device qdiscs are not available.

`tc netem` at the packet layer is the only mechanism that works without patching nl6.

## Verified environment facts

All checked on `netsim-benchmark-01` (192.0.2.216) and `core-benchmark-01` on 2026-09-01.

| Fact | Value |
|---|---|
| Route to fleet | `10.42.0.0/16 via 10.254.0.2 dev veth-sim-host` |
| NAT on `10.42.0.0/16` | **none** (only docker0's unrelated 172.17 MASQUERADE) |
| ⇒ responses egress | `enp6s19` with `src 10.42.x.y` — classifiable per device group |
| Baseline qdisc | `fq_codel` on `enp6s19`, `noqueue` on `veth-sim-host` |
| `sch_netem` | present, loads cleanly |
| Distribution tables | `/usr/lib/x86_64-linux-gnu/tc/` — `normal.dist`, `pareto.dist`, `paretonormal.dist` |
| Timer granularity | `CONFIG_HZ=1000`, `CONFIG_HIGH_RES_TIMERS=y` → 1 ms is real |
| SNMP timeout / retries | `timeout="1800"` `retry="1"` (packaged default; `snmp-config.xml` sets neither) |
| Fleet addressing | one `/24` per batch, third octets 0–17, **plus one stray at `10.42.220.x`** |

## Measured constants

From the sim bridge and Collectd JMX, 3,805 collectable services on a 300 s interval.

| Quantity | Value | How obtained |
|---|---|---|
| Arrival rate λ | 12.68 collections/s | 3805 ÷ 300 |
| PDUs per walk | **184–191** | sim-bridge packet rate ÷ λ; request and response rates reconcile exactly (no loss, no retransmits) |
| Baseline walk time W | **1.92 s** | Little's Law: 24.29 mean active threads ÷ λ, settled window 2026-09-01 16:10–16:20 CEST at 70 min uptime |
| Budget at 100 threads | 7.88 s | 100 ÷ λ |
| Headroom | **4.1×** | |
| **Predicted saturation** | **≈32 ms per PDU** | (7.88 − 1.92) ÷ 184.4 |
| Retry cliff | 1800 ms per PDU | ~55× beyond saturation — **not** the binding constraint |

**Read this before choosing rungs.** Thread exhaustion arrives roughly 55× before any SNMP
retry fires. Retries only matter if the injected tail crosses 1.8 s per PDU.

## Preconditions

Check every line. Any failure invalidates the run.

```bash
# 1. fleet at benchmark size and steady
curl -s http://192.0.2.216:8080/api/v1/status | python3 -m json.tool | grep total_devices   # expect 3801

# 2. OpenNMS settled — NOT within ~60 min of a restart. Measured 2026-09-01:
#    a window taken 3-49 min after the 15:09 restart gave W=1.12 s and 6.9x headroom;
#    the same system at 70 min uptime gave W=1.92 s and 4.1x. The early window was NOT
#    merely noisier - it was systematically optimistic, because the fleet was still being
#    scheduled and fewer collections were in flight. Do not baseline on it.
#    A restart schedules the whole fleet at once: a 3,705-deep queue was observed
#    6 min after the 15:09 restart on 2026-09-01, draining by +11 min.
#    Steady state also differs: peak/mean sample rate 2.8 settled vs 3.7 post-restart.

# 3. no shaping already in place
ssh netsim-benchmark-01 'tc qdisc show dev enp6s19; tc qdisc show dev veth-sim-host'
#    expect fq_codel and noqueue respectively

# 4. Collectd pool at the tuned value
#    opennms_collectd_maxpoolthreads == 100

# 5. queue draining to zero between cycles
#    opennms_collectd_taskqueuependingcount returns to 0 within each 300 s cycle
```

## Procedure

### P0 — control, no netem

Record one full 900 s window (three cycles) with the stack untouched. This is the reference
the report already documents; re-take it rather than reusing the published figure, because the
simulator has since moved to nl6 v0.28.0 (the report's baseline was v0.22.1).

### P1 — netem at 0 ms

**Do not skip this.** Attaching netem *replaces* `fq_codel`, which changes queueing behaviour
on its own. Without this rung you cannot separate "the delay did it" from "the qdisc did it".

```bash
ssh netsim-benchmark-01 'sudo tc qdisc replace dev enp6s19 root netem delay 0ms'
```

Record 900 s. **Gate: sample count must match P0 within 1%.** If it does not, the qdisc change
alone is perturbing the measurement and the sweep is not interpretable.

### P2 — uniform sweep

One rung at a time, 900 s each (an integer multiple of the 300 s interval — non-integer windows
give phase-dependent results, which is the error that manufactured a false 40% gain in
`pm-collectd-threads`).

```bash
for D in 2 5 10 20 30 40; do
  ssh netsim-benchmark-01 "sudo tc qdisc replace dev enp6s19 root netem delay ${D}ms"
  sleep 900    # settle, then measure the following 900 s
done
```

Predicted knee at 32 ms. Rungs bracket it at 30 and 40.

### P3 — heterogeneous fleet

This is the rung the research actually argues for: cross-device variance dominates, so a
uniform delay models the *less* important effect. Classify by third octet onto the existing
batch structure.

Assignment below has a fleet mean of **8.4 ms/PDU** — predicted ≈44 threads, comfortably inside
budget — with 2.7% of devices at 80 ms. Little's Law says occupancy should match a uniform
8.4 ms rung; any difference is the tail's doing, which is precisely the claim under test.

| Class | Delay | Third octets | Devices | Share |
|---|---|---|---|---|
| 1:11 | 2 ms | 2–9 | 1,900 | 50% |
| 1:12 | 5 ms | 11–14 | 1,000 | 26% |
| 1:13 | 12 ms | 15, 16 | 500 | 13% |
| 1:14 | 30 ms | 10, 17 | 300 | 8% |
| 1:15 | 80 ms | 0, 1, 220 | 101 | 2.7% |

```bash
# prio, NOT htb — htb shapes bandwidth as a side effect and we want delay only
tc qdisc replace dev enp6s19 root handle 1: prio bands 6

tc qdisc add dev enp6s19 parent 1:1 handle 11: netem delay  2ms  1ms distribution pareto
tc qdisc add dev enp6s19 parent 1:2 handle 12: netem delay  5ms  3ms distribution pareto
tc qdisc add dev enp6s19 parent 1:3 handle 13: netem delay 12ms  8ms distribution pareto
tc qdisc add dev enp6s19 parent 1:4 handle 14: netem delay 30ms 20ms distribution pareto
tc qdisc add dev enp6s19 parent 1:5 handle 15: netem delay 80ms 50ms distribution pareto

# classify on SOURCE ip — the responding simulated device
for O in 2 3 4 5 6 7 8 9;  do tc filter add dev enp6s19 protocol ip parent 1: prio 1 u32 \
    match ip src 10.42.$O.0/24 flowid 1:1; done
for O in 11 12 13 14;      do tc filter add dev enp6s19 protocol ip parent 1: prio 1 u32 \
    match ip src 10.42.$O.0/24 flowid 1:2; done
for O in 15 16;            do tc filter add dev enp6s19 protocol ip parent 1: prio 1 u32 \
    match ip src 10.42.$O.0/24 flowid 1:3; done
for O in 10 17;            do tc filter add dev enp6s19 protocol ip parent 1: prio 1 u32 \
    match ip src 10.42.$O.0/24 flowid 1:4; done
for O in 0 1 220;          do tc filter add dev enp6s19 protocol ip parent 1: prio 1 u32 \
    match ip src 10.42.$O.0/24 flowid 1:5; done
```

**Omit `correlation`.** netem's third delay argument makes each draw partly a copy of the
previous one; it distorts the realised marginal distribution, so "pareto with mean X" stops
being true. Model persistence by changing a class's delay over time instead.

### P4 — teardown

```bash
ssh netsim-benchmark-01 'sudo tc qdisc del dev enp6s19 root; tc qdisc show dev enp6s19'
# expect fq_codel to return
```

## Record per rung

| Metric | Source | Why |
|---|---|---|
| samples in window, rate | `kafka-metrics-report` | the headline; **the validity gate** |
| span/window coverage | same | must stay in 0.85–1.15 or the window did not fill |
| `opennms_collectd_activethreads` | JMX | mean → W via Little's Law |
| **`opennms_collectd_taskqueuependingcount`** | JMX | **the real stop signal** |
| `opennms_collectd_taskcompletionratio` | JMX | cycle completeness |
| minion CPU cores, `node_load1` | node exporter | the Minion executes the walks |
| sim-bridge pkt/s both directions | node exporter | confirms offered load unchanged |
| `%SNMP` retries / timeouts | OpenNMS logs | should be zero below 1800 ms/PDU |

## Stop conditions

**The pool hitting 100% is not the signal.** It already does that at zero delay — arrivals are
bursty, the pool pegs briefly and drains. Measured 2026-09-01: peak thread usage touches 100%
in most cycles while the queue returns to zero.

Declare saturation when **`taskqueuependingcount` fails to return to zero before the next
cycle begins**, i.e. backlog carries across cycles. Corroborate with `taskcompletionratio`
falling below 1.0 persistently.

## Validity gates

1. **Offered load unchanged.** Sim-bridge request packet rate must stay at ≈2427 pkt/s. If it
   falls, the injected delay is throttling the generator and you are measuring throughput, not
   latency. (The same hazard is documented for snmpsim, whose responder is single-threaded.)
2. **Window is an integer multiple of 300 s.** Non-integer windows capture a whole number of
   bursts plus an arbitrary fraction, and the phase decides the result.
3. **Rate computed against wall-clock window**, never the span between first and last message
   timestamp.
4. **P1 matches P0 within 1%**, or the qdisc swap is itself perturbing the run.

## Rollback

`tc qdisc del dev enp6s19 root` restores the default immediately; no service restart needed.
The change is confined to one interface on `netsim-benchmark-01` and touches neither OpenNMS
nor the Minion. If the box is rebooted the qdisc is gone anyway — nothing here persists.

## Expected result, stated in advance

Recorded before running, so the outcome can be scored honestly rather than rationalised.

- Rungs to 20 ms: no change in delivered rate; occupancy rises from the 24-thread floor roughly
  linearly (2 ms → ≈29, 10 ms → ≈48, 20 ms → ≈71).
- 30 ms: approaching the knee.
- 40 ms: sustained backlog, completion ratio below 1.
- P3 heterogeneous at mean 8.4 ms: occupancy ≈44 threads, matching a uniform 8.4 ms rung.
  **If it does not match, Little's Law is being violated somewhere and that is the finding.**
- Retries: none anywhere in the sweep, since no rung approaches 1800 ms/PDU.

**If the fleet does not break at any plausible latency, that is a publishable result** and the
honest correction to the report's "expect a real estate of the same size to need materially
more" caveat.
