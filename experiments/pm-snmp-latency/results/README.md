# SNMP latency and fleet-scaling campaign — results

Raw results from the campaign run 2026-09-01 to 2026-09-02 against `kfk-exclusive` on Proxmox.
Recovered from a session scratchpad, which is volatile; these files are the only copy.

Read `../RUNBOOK.md` for the method and `../HANDOFF.md` for the narrative and the open threads.

## The headline

**Under 8–12 ms/PDU of injected latency, 13,000 devices complete a collection cycle and 14,000 do not, and the binding constraint is Collectd threads rather than CPU.**

At the 14,000 failure the thread pool mean is 100.0 against a 100 ceiling, so it is pinned for the whole window, while Core sits at 85.2%.
Cores were never the thing that ran out.

## Files

| file | rows | what it is |
|---|---|---|
| `latency-sweep.jsonl` | 10 | Latency sweep at a fixed 3,801 devices, 0 → 60 ms/PDU. Written by `bin/runbook_exec.py` as P0–P2 of the runbook. |
| `fleet-sweep.jsonl` | 3 | Cleanroom capacity at 10,055 / 12,055 / 13,555 services, **no injected latency**. Written by `bin/fleet_sweep.py`. |
| `edge-search.jsonl` | 5 | The edge search: 10,000 → 14,000 devices under a fixed 8–12 ms/PDU. Written by `bin/edge_search.py`. |
| `edge-search.log` | | Timestamped run log for the edge search, CEST. |
| `fleet-sweep.log` | | The three fleet-sweep run logs concatenated in order. |
| `bin/` | | The drivers, preserved verbatim. |

`latency-sweep.jsonl` was called `results.jsonl` in the scratchpad. Renamed here because a file called
`results.jsonl` inside a directory called `results` tells the next reader nothing.

## Reading these safely

The campaign's own traps apply to this data, and two of them will mislead you quickly:

- **`ratio_min` and `queue_max` are spot statistics on a bursty system.** `taskcompletionratio` is a sawtooth
  that resets to near zero every cycle, so `ratio_median` is the field to judge on. `queue_max` is a single
  peak and swings hard between adjacent rungs: it reads 51 at 12,000 devices and 1,502 at 13,000.
  `queue_zero_frac` is the cleaner signal, and it falls monotonically as the system approaches the edge.
- **Rate must be computed against the wall clock**, never against the span of message timestamps.
  `rate_wallclock` is the honest column in `latency-sweep.jsonl`; `rate_tool_span` is kept only so the two
  can be compared, and where they diverge the window did not fill.

Windows are integer multiples of the 300 s collection interval. Timestamps inside the `.jsonl` files are UTC;
the `.log` files are CEST.

## What is not here

The `collectData` instrumentation capture stays on `core-benchmark-01` at
`/var/tmp/pm-snmp-latency/capture.log`, 1.18 GiB, parsed by `bin/durations.py`. It was not copied in.

The lab configuration these numbers were produced on **is not in git**: `netsim-benchmark-01` at 4 vCPU / 8 GiB,
Core `JAVA_HEAP_SIZE=10240`, nl6 at v0.28.0. `deployments/kfk-exclusive/topology.yml` still describes the
smaller machine. Any attempt to reproduce these figures from the committed topology will fall short of them,
and it will not be obvious why.
