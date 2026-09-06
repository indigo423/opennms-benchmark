# nl6 flow emission shape — before/after nl6#446

Closes task 5.4 of the nl6 `honest-flow-cadence` change: the emission model was
derived by reading the code and simulating the loop, and every number shipped in
nl6's reference docs came from that model. This puts it on the wire.

## Question

Does nl6's flow emission on a real network interface match what the
synthetic-time probe predicted — in **rate**, in **shape**, and in whether `-flow-tick-interval` has
any effect at all?

## Design

**Independent variables, crossed 2x2.** The nl6 build (pre/post the change) and
the tick cadence (5s/30s). Nothing else varies.

**Builds are two exact commits**, cross-compiled from the same tree:

| build | commit | |
|---|---|---|
| `pre` | `95d52e7` | parent of the change |
| `post` | `9142a74` | the change |

Released images were rejected as the baseline: the newest tag (`v0.23.0`,
2026-08-19) predates five days of unrelated work including the fidelity toggle,
so comparing it against `rc` would confound the flow change with everything
else. Two adjacent commits isolate the one variable.

**Controls.** Same VM, same single device (`cisco_ios`, which maps to
`flowProfileEdgeRouter` — the profile the model used), same 30s/15s timeouts,
same netflow9 protocol, same 45s warm-up, same 300s window, same collector
address. One device rather than a fleet, because the model is a single-exporter
model and the claim under test is per-device.

**No system under test.** The question is what nl6 *emits*, so the collector is
a packet capture on the same node. Anything else between generator and
measurement is a component that could distort the answer. Nothing listens on
2055; the datagrams are still emitted and `tcpdump` observes exactly what left
the exporter.

**Scope validity.** Generator-side measurement, so co-locating the capture is
not a contention concern — nothing is being saturated (~4 records/second).

**What this is not.** A simulated fleet on a virtual machine. `cisco_ios` is an
nl6 device *type*, not a physical router, and the claim under test is that nl6
emits what its own model says — not that nl6 resembles Cisco hardware.

## Method

`run-cell.sh <build> <tick> <window>` starts nl6, creates one device over REST
with an explicit flow block, warms up, then captures. `run-matrix.sh` runs all
four cells. `analyse-pcap.py` parses the capture with the standard library
only — no tshark, so the analysis re-runs anywhere.

**Shape is recovered by clustering datagrams into tick groups, not by
fixed-width bucketing.** Datagrams from one tick are microseconds apart while
ticks are seconds apart, so the gap separates them unambiguously. A first pass
used fixed 5s buckets aligned to the first packet and reported a silent tick
that did not exist: one tick's records had straddled a bucket boundary.

## Results

Wire measurements, 300s window, one device:

| cell | records/s | silent ticks | shape (records per emitting tick) |
|---|---|---|---|
| pre @ 5s | **6.05** | **43 of 54** | `128, 128, 128, 128, …` |
| post @ 5s | **4.10** | **0 of 58** | `28, 40, 19, 21, 1, 24, 27, 6, 49, …` |
| pre @ 30s | **6.07** | **46 of 58** † | `128, 128, 128, 128, …` |
| post @ 30s | **3.02** | **0 of 8** | `128, 20, 110, 128, 14, 128, …` |

Figures corrected in opennms-benchmark#6: `analyse-pcap.py` was counting NetFlow v9 Template FlowSets as data records. The rate effect is under half a percent here, but the **shape** effect was categorical — see below.

† The `pre @ 30s` row is analysed at **5s**, not 30s, because that is the cadence
it actually ran at — the flag was inert, which is the defect being measured.
Bucketing it at the 30s it was *asked* for reports `0 of 12` silent and hides the
sawtooth, since a 30s window always contains one of the 5s bursts. Reporting a
cell at a cadence it never used is how the inert flag would have escaped notice
a second time.

### Three claims, all confirmed

**1. The flag was inert, and now is not.** Pre-change, 5s and 30s produce the
same rate (6.05 vs 6.07) — setting the flag changed nothing on the wire, which
is nl6#446 observed directly rather than inferred from a call graph.
Post-change the same comparison gives 4.10 vs 3.02: the cadence now reaches the
ticker.

**2. The cohort sawtooth was real and is gone.** Pre-change, **43 of 54 ticks
emitted nothing** — roughly 4 in 5 — and every emitting tick carried the entire
128-flow cache at once: `peak/mean` is exactly **1.00**, a dead-flat sawtooth.
Post-change, **zero** silent ticks at either cadence.

The corrected numbers make this claim sharper than the original measurement did.
Before opennms-benchmark#6, template-only datagrams were counted as ticks that
emitted one record, which both hid three silent ticks and dragged the mean from
128 down to 100.9 — manufacturing an apparent 1.28x burst ratio in a series that
is perfectly uniform. At 30s the same artifact produced a phantom `257` (two
datagrams, one carrying a template) and a 1.83x ratio.

**3. The announced volume change holds.** Measured ratio at the default cadence
is **0.678**, against the 0.66 published in nl6's `flow-export.md`.

### Model versus wire

| cell | model | wire | delta |
|---|---|---|---|
| pre @ 5s | 6.40 | 6.05 | −5.5 % |
| post @ 5s | 4.24 | 4.10 | −3.3 % |
| post @ 30s | 3.63 | 3.02 | **−16.8 %** |

The model runs slightly hot everywhere, which is expected: it advances time in
exact tick increments with no scheduling jitter, no socket latency and no
warm-up truncation, so it counts expiries the wire narrowly misses.

**Capture-side loss is excluded, by an instrument independent of the record count.** NetFlow v9 carries a per-exporter datagram sequence number. All four captures are sequence-continuous with zero gaps, so nothing was dropped between the exporter and `tcpdump`. This check was added after review pointed out that a shortfall attributed to the model could equally be burst loss — 128 records at a 30s cadence leave as roughly five back-to-back datagrams, which is exactly the shape a socket buffer drops. Without the sequence check the conclusion below would have been unsupported.

**The 30s cell is the one worth flagging.** A 16.5 % shortfall is larger than
jitter explains, and the shape hints at why: post-change at 30s the per-tick
counts alternate (`129, 20, 110, 129, 14, 128, …`) rather than settling at a
uniform 128. With a 30s cadence against a ~29s mean lifetime the cache turns
over wholesale each tick, so any flow whose lifetime lands just past a tick
boundary slips a whole period. The model quantises that boundary the same way
every time; real timing does not.

This is **not** reconciled. With capture loss excluded the quantisation account
above is the remaining candidate, but it is a hypothesis rather than a finding —
it was not tested. What can be said is that the model predicts coarse-cadence
rates less well than it predicts the default, which is also the regime the
documentation now advises against using.

## Part 2: does a scenario's `rate` reach the wire? (nl6#456)

The same lab, the same harness, after [nl6#461](https://github.com/labmonkeys-space/nl6/pull/461) made a flow scenario's `rate` set the record rate by sizing each participant's flow cache. Before it, `rate` set the tick cadence and the wire carried whatever the cache produced.

Five `cisco_ios` participants, caches warmed to their profile population for 90s first — the state a real run starts from — then a scenario armed and started.

| requested/device | window | wire/device (in-window) | report says | deviation | capture loss |
|---|---|---|---|---|---|
| 0.5 | 180s | 0.470 | 0.47 | **−6.0 %** | 0 |
| 2 | 120s | 1.803 | 1.80 | **−9.8 %** | 0 |
| 4 | 120s | 3.262 | 3.26 | **−18.5 %** | 0 |
| 8 | 120s | 6.678 | 6.68 | **−16.5 %** | 0 |

Both numeric columns moved from the original run of this table, in the same direction and for two separate reasons — see [Part 4](#part-4-is-the-report-undercounting-nl6463). The wire column was inflated by template FlowSets (this PR) *and* divided by the capture span instead of the window (nl6#463). Corrected, `wire` and `report says` agree to the published precision in every cell, which is the answer to the question Part 4 asks; the column worth reading here is the deviation from what was **requested**.

**Pacing works, and is worse than the unit tests say — worse, now, than this table first reported.** Every cell tracks its request, where before this change `rate` moved the wire not at all, and all four are sequence-continuous, so the shortfalls are real emission and not lost packets.

But `TestFlowPacing_TickAchievesRateFromWarmCache` enforces 8 % and passes; the wire misses that in **three of four cells**, by as much as **−18.5 %**, and the deviation is not monotonic in the rate. The unit test drives `Tick` against a real socket but with synthetic time and no MTU pagination, so something in the real path is not in the model. **Not diagnosed** — this is a finding, not a conclusion, and it is the third time on this code path that a probe agreed with a model while the wire disagreed with both.

### What this run cost, and the guard that came out of it

Four scenario runs measured **nl6 v0.22.1** — the released container — before anyone noticed. The lab's ansible role installs nl6 as a **systemd service**, so `docker rm -f` is not enough: systemd restarts it within seconds, it re-binds `:8080`, and a hand-started binary exits with `address already in use` into a log nobody reads. Every symptom pointed elsewhere (`network is unreachable` from a netns that looked misconfigured).

`run-cell.sh` now stops the unit and, more importantly, **asserts `/api/v1/version` is the build under test before measuring anything**. A measurement harness that cannot tell which binary answered is not measuring anything.

The multi-device capture also broke the loss check: NetFlow sequence numbers are per exporter, and pooling five of them reported **−93 missing** — a negative loss. Grouped by source IP now.

## Part 3: records claim a last-packet time the exporter has not reached

`check-timestamps.py`, template-aware (the field offsets are not fixed, so the
template flowset is read from the capture and data records decoded against it).

| capture | records | LAST_SWITCHED ahead of SysUptime | max ahead |
|---|---|---|---|
| `cap-post-5s` | 867 | **71.5 %** | 89.5 s |
| `s6-rate2-w120` | 782 | **71.7 %** | 89.2 s |
| `s6-rate8-w120` | 1296 | **69.0 %** | 89.8 s |

About seven records in ten state a last-packet time the exporter had not yet
reached when it sent them, by as much as 90 seconds.

**The mechanism is the active timeout, and the 90s is exactly what it predicts.**
A flow sampled with a 120 s duration is capped and exported at the 30 s active
timeout, but the record still carries the `EndMs` its full duration implies —
90 s beyond. The cap truncates the flow's residency without truncating its
claimed extent, and the byte and packet counts are not rescaled either.

A collector computing `flowEnd = exportTime − (sysUptime − lastSwitched)` gets a
timestamp in the future, and any bytes-per-second derived from the flow's own
duration is wrong by `duration / active-timeout`.

This was carried as a deferred finding from the nl6#457 review, which estimated
75.7 % from the emission model. Measured: 69–72 %. It is **pre-existing** — not
introduced by the pacing work — and unfixed; the numbers are here so a fix can be
scoped against a measurement rather than an estimate.

`cap-pre-5s` decoded only 4 records and is excluded: that run used a 10-minute
template interval and the capture began after warm-up, so almost no template
reached the file. A data record cannot be decoded without its template, which is
itself worth knowing before designing a capture.

## Part 4: is the report undercounting? (nl6#463)

Part 2 left a loose end: the report's `achieved_per_device` read 3–8 % below what
this experiment called "the wire", in every cell. The ledger counts at
write-return, so it should match the capture or exceed it — never undercount.
That was filed as [nl6#463](https://github.com/labmonkeys-space/nl6/issues/463).

**It was not undercounting. The comparison was.** `achieved_per_device` counts
records inside `[T0,T1)`, so the wire has to be counted over `[T0,T1)` too.
Dividing a whole-capture record count by the capture span compares two different
quantities, and the sign of the disagreement is set by how much capture lies
outside the window rather than by anything the exporter did.

`reconcile-report.py` makes the comparison the original could not: it buckets
wire records against the report's own `t0` / `t1` / `drain_end` and diffs them
bucket for bucket, fleet-wide and per device.

```
  bucket                       WIRE   LEDGER    delta  templates
  pre-T0                          0        -        -          5
  in-window [T0,T1)            2349     2349       +0          5
  drain [T1,drain_end)            0        0       +0          1
  post-drain                      0        -        -          0

  per-device in-window:  all 5 device(s) agree
  achieved_per_device:   wire 3.9150   report 3.915   delta +0.0000
```

Exact, and exact per device — a fleet total can hide two devices disagreeing in
opposite directions. `captures/s7-recon-rate4-w120.{pcap,report.json}` is that
run, and is the first **capture plus report** pair here; keeping the two together
is what made the question answerable at all.

The four Part 2 cells reconcile retroactively too, with no new capture. Subtract
template phantoms, subtract the records that land after the window, and divide by
the window rather than the capture span:

| requested | data recs | after window | in-window | ÷ window ÷ 5 | report says |
|---|---|---|---|---|---|
| 0.5 | 461 | 38 | 423 | 0.4700 | 0.47 |
| 2 | 1134 | 52 | 1082 | 1.8033 | 1.80 |
| 4 | 1988 | 31 | 1957 | 3.2617 | 3.26 |
| 8 | 4327 | 320 | 4007 | 6.6783 | 6.68 |

```bash
python3 reconcile-report.py captures/s6-rate8-w120.pcap --retro 120:5
```

Every cell lands on its published report value, all four deltas inside half a
unit of the last printed digit. Those runs kept no report JSON, so `T1` is
inferred from a lull — *records after the largest inter-datagram gap past 80 % of
the window* — rather than read. The rule was fixed before the comparison, not
fitted, and four cells landing on four different published values is what makes
it convincing. Every capture has such a lull (6.2 s, 11.2 s, 6.2 s, 6.2 s)
followed by a burst; at rate 8 the burst is 320 records in one second.

So the gap decomposes with nothing left over for the ledger:

| term | at rate 8 |
|---|---|
| template phantoms in the wire column | 10 records (0.23 %) |
| post-window burst counted as wire | 320 records (7.4 %) |
| capture span used as denominator instead of window | 1.2 s of 121.2 s |
| **ledger error** | **0** |

**Those post-window records are not "drain."** That was the first explanation
offered on nl6#463 and it is wrong: a scenario's configured `drain` duration is
never waited out — `gateState.drainEnd` is computed and never read, generation
stops dead at `T1`, and `drain_end` lands milliseconds after `t1` however long a
drain was requested ([nl6#500](https://github.com/labmonkeys-space/nl6/issues/500)).
The burst is emission after the scenario *stopped* and the gate came off,
belonging to no window and correctly counted in none. Anyone reconciling a run
should bound the capture to `[t0,t1)` — **not** follow nl6's schema doc and
divide `sent` by `window + drain`, which adds the very bias it claims to remove.

## Reproducing

```bash
make deploy PROVIDER=kvm DEPLOYMENT=flow-emission     # one loadgen VM, no SUT
# copy nl6 binaries + go/nl6/resources/ to the VM (see run-cell.sh header)
sudo /tmp/run-matrix.sh
python3 analyse-pcap.py captures/cap-post-5s.pcap 5
```

For a scenario run, capture the report alongside the pcap and reconcile them:

```bash
curl -s localhost:8080/api/v1/loadtest/scenarios/<id>/report > run.report.json
python3 reconcile-report.py run.pcap run.report.json
```

Capture on the **emitting** node. The two files must share one clock: skew moves
records across the window boundary, and the tool cannot tell that from genuine
out-of-window emission — it warns when the edge buckets are non-empty, but a
warning is all it can offer.

Two practical notes that cost time here: nl6 loads `resources/` relative to its
working directory, and a `tar` built on macOS carries `._*` AppleDouble files
that the resource loader tries to parse as JSON and fails on. Pack with
`COPYFILE_DISABLE=1 tar --exclude='._*'`.

## Artifacts

- `captures/*.pcap` — the raw captures
- `captures/s7-recon-rate4-w120.{pcap,report.json}` — the one capture/report pair, the input `reconcile-report.py` needs
- `results.txt` — full analyser output per cell
- `run-cell.sh`, `run-matrix.sh`, `analyse-pcap.py` — the harness
- `reconcile-report.py` — diffs a scenario report's ledger against a capture of the same run (Part 4)
- `check-timestamps.py` — decodes records against their template to check `LAST_SWITCHED` (Part 3)
