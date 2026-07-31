# nl6_loadtest

Runs one bounded nl6 load-test scenario end to end and reports its sent-ledger.

This is the **delivered** half of a delivered-vs-accepted reconciliation.
nl6 keeps an immutable ledger of what it put on the wire, so the generator's output is a measured number rather than an assumed one.

It is also the only way to set a rate at all.
The `nl6` systemd unit passes collector endpoints but no rate arguments; rate lives in the scenario API.

## Usage

```bash
ssh mon-benchmark-01
nl6-loadtest --protocol snmp-trap --rate 200 --window 5m --label "trap sweep"
```

The wrapper supplies the endpoint and the fleet from the inventory; anything on the command line overrides it.

Ramp to find the knee, and read which buckets lost records:

```bash
nl6-loadtest --protocol syslog --window 5m --rate 100 \
  --rate-profile '{"kind":"linear","start_rate":5,"end_rate":200}'
```

Stop early when the generator itself starts failing, rather than measuring its own limits:

```bash
nl6-loadtest --protocol snmp-trap --rate 500 --window 10m --abort-on send_failures:100:5s
```

Protocols: `syslog`, `snmp-trap`, `netflow5`, `netflow9`, `ipfix`, `sflow`, `gnmi-dialout`.
`rate` is events/second **per device**, capped at 1000 by nl6.

## Exit status

| Code | Meaning |
|---|---|
| 0 | every requested record was sent |
| 1 | send failures, drops, or a shortfall against a constant profile |
| 2 | nl6's own ledger identity did not hold, so the report is not trustworthy |

A non-zero exit means the *generator* fell short, before OpenNMS is involved.
Reconciling against OpenNMS on a run that exits 1 measures the wrong thing.

## The ledger

nl6 documents an invariant, and the driver verifies it rather than trusting it:

```
emitted = in_window + drain + send_failures + dropped + suppressed_pre_window
sent    = in_window + drain
```

**`sent` is the reconciliation denominator**, not the requested rate.
A run that asked for 900 records and sent 675 has already lost 225 at the generator; comparing OpenNMS against 900 would charge it for someone else's loss.

For a constant profile the expected count is exact: `rate × window × devices`.
Under a rate profile there is no closed form, so the report says `n/a` instead of inventing one.

## Loss localization

The chart shows in-window sends across the ten equal buckets nl6 splits the window into.
Drain sends are excluded by definition, being post-`T1`.

A shortfall concentrated in the **late** buckets points at the collector giving way under sustained load.
One spread **evenly** points at the generator.
That distinction is the whole reason the buckets exist, and it is the first thing to read after a run that exits 1.

## Reproducibility

Every report records `config_sha256`, `seed` and `nl6_version`.
nl6's reproduction guarantee is scoped to a version, so a comparison across an nl6 upgrade is not like-for-like even with the same seed.

## What this does not do yet

**It does not join the delivered ledger to what OpenNMS accepted.** That is deliberate, because the accepted side has more than one defensible definition and the right one depends on the question:

| Accepted at | Counts | Caveat |
|---|---|---|
| `OpenNMS.Sink.Trap` / `Sink.Syslog` offsets | what the Minion took | the sink batches, so an offset delta is messages, not records |
| OpenNMS events in PostgreSQL | what Core turned into events | trap-to-event is not always 1:1 |

Picking one without saying which would produce a reconciliation that looks authoritative and is not.
Until that lands, run this and the accepted-side count over the same window and compare by hand.

## Constraints worth knowing

- **One scenario at a time, fleet-wide.** A second submit while one runs is refused.
- **nl6 state is in memory.** A restart loses every report not already fetched; this driver writes its JSON sidecar immediately for that reason.
- **Device creation and deletion are blocked** between arm and stop.
- The driver talks to nl6 over the **mgmt** network. That is a control-plane call, so it cannot contaminate the `sim` network the generator measures on.
