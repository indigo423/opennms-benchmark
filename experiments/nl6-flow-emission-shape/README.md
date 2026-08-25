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
| pre @ 5s | **6.07** | **40 of 54** | `128, 128, 129, 128, …` |
| post @ 5s | **4.12** | **0 of 58** | `28, 40, 20, 21, 1, 24, 27, 6, 49, …` |
| pre @ 30s | **6.09** | **42 of 58** † | `1, 128, 128, 128, 1, 128, …` |
| post @ 30s | **3.03** | **0 of 8** | `129, 20, 110, 129, 14, 128, …` |

† The `pre @ 30s` row is analysed at **5s**, not 30s, because that is the cadence
it actually ran at — the flag was inert, which is the defect being measured.
Bucketing it at the 30s it was *asked* for reports `0 of 11` silent and hides the
sawtooth, since a 30s window always contains one of the 5s bursts. Reporting a
cell at a cadence it never used is how the inert flag would have escaped notice
a second time.

### Three claims, all confirmed

**1. The flag was inert, and now is not.** Pre-change, 5s and 30s produce the
same rate (6.07 vs 6.09) — setting the flag changed nothing on the wire, which
is nl6#446 observed directly rather than inferred from a call graph.
Post-change the same comparison gives 4.12 vs 3.03: the cadence now reaches the
ticker.

**2. The cohort sawtooth was real and is gone.** Pre-change, **40 of 54 ticks
emitted nothing** — roughly 3 in 4, exactly the predicted period — and the
emitting ticks carried the entire 128-flow cache at once. Post-change, **zero**
silent ticks at either cadence.

**3. The announced volume change holds.** Measured ratio at the default cadence
is **0.679**, against the 0.66 published in nl6's `flow-export.md`.

### Model versus wire

| cell | model | wire | delta |
|---|---|---|---|
| pre @ 5s | 6.40 | 6.07 | −5.2 % |
| post @ 5s | 4.24 | 4.12 | −2.8 % |
| post @ 30s | 3.63 | 3.03 | **−16.5 %** |

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

| requested/device | window | wire/device | report says | deviation | capture loss |
|---|---|---|---|---|---|
| 0.5 | 180s | 0.51 | 0.47 | **+2.4 %** | 0 |
| 2 | 120s | 1.89 | 1.80 | **−5.6 %** | 0 |
| 4 | 120s | 3.30 | 3.26 | **−17.6 %** | 0 |
| 8 | 120s | 7.16 | 6.68 | **−10.5 %** | 0 |

**Pacing works, and is worse than the unit tests say.** Every cell tracks its request — before this change `rate` moved the wire not at all — and all four are sequence-continuous, so the shortfalls are real emission and not lost packets.

But `TestFlowPacing_TickAchievesRateFromWarmCache` enforces 8 % and passes; the wire misses that at **rate 4 (−17.6 %)** and **rate 8 (−10.5 %)**, and the deviation is not monotonic in the rate. The unit test drives `Tick` against a real socket but with synthetic time and no MTU pagination, so something in the real path is not in the model. **Not diagnosed** — this is a finding, not a conclusion, and it is the third time on this code path that a probe agreed with a model while the wire disagreed with both.

The report's own `achieved_per_device` reads 3–8 % below the wire in every cell, consistently. That is a smaller, separate discrepancy worth chasing on its own: the ledger counts at write-return, so it should if anything match or exceed the capture.

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

## Reproducing

```bash
make deploy PROVIDER=kvm DEPLOYMENT=flow-emission     # one loadgen VM, no SUT
# copy nl6 binaries + go/nl6/resources/ to the VM (see run-cell.sh header)
sudo /tmp/run-matrix.sh
python3 analyse-pcap.py captures/cap-post-5s.pcap 5
```

Two practical notes that cost time here: nl6 loads `resources/` relative to its
working directory, and a `tar` built on macOS carries `._*` AppleDouble files
that the resource loader tries to parse as JSON and fails on. Pack with
`COPYFILE_DISABLE=1 tar --exclude='._*'`.

## Artifacts

- `captures/*.pcap` — the four raw captures
- `results.txt` — full analyser output per cell
- `run-cell.sh`, `run-matrix.sh`, `analyse-pcap.py` — the harness
