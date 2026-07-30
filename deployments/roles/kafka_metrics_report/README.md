# kafka_metrics_report

Installs a batch consumer on the monitoring node that counts OpenNMS metric samples on a Kafka topic and writes a self-contained HTML report.

Built for the `kfk-exclusive` deployment, where the Kafka `metrics` topic **is** the time-series store.
`EmptyResourceStorageDao` means the OpenNMS UI shows no graphs, so the topic is the only measurement point a performance-management benchmark has.

## What the report answers

- **How many metrics arrived** — total numeric samples.
- **Metrics per second, mean** — over the accepted-clock span.
- **Metrics per second over time** — a line chart, plus the same data as a table.

## Usage

```bash
ssh mon-benchmark-01
kafka-metrics-report --label "c1km1 snmp 5k nodes" --html /tmp/run.html
```

The wrapper supplies `--bootstrap`, `--topic` and `--bucket-seconds` from the role's variables; anything on the command line overrides them.

To measure one run rather than the whole topic, capture the offsets first and pass them back:

```bash
kafka-metrics-report --html /tmp/before.html          # writes metrics-report.json
jq '.offsets | map_values(.end)' metrics-report.json > /tmp/start.json
#   … run the benchmark …
kafka-metrics-report --start-offsets /tmp/start.json --html /tmp/run.html --json /tmp/run.json
```

To reproduce an existing report exactly, replay its sidecar:

```bash
kafka-metrics-report --replay /tmp/run.json --html /tmp/run-again.html
```

## Why batch and not a live tail

The consumer reads from a start offset to an end offset, then exits.

`--start-offsets` pins only the start; the end is the high watermark at the moment the run begins, so two invocations against a live topic cover different slices.
**`--replay` is what makes a report reproducible** — it takes both bounds from a previous sidecar, so the same command reads the same records and produces the same numbers.
A tail can offer neither.

The bound is enforced per record, not merely tracked. A partition that drains early keeps receiving newly produced messages while its siblings catch up; counting those would make the totals disagree with the offsets the report prints.

The cost is that retention must outlive the benchmark. `kfk-exclusive` sets `log.retention.hours: 24` with a byte cap for exactly this reason.

## Counting: what "a metric" means

One **numeric attribute** is one metric. Message count is not a proxy for it:

- a `CollectionSet` carries many resources, each with many `NumericAttribute`s;
- with `disable.metrics.splitting` false (the default), the producer may split one collection set across several Kafka messages.

The report shows records, resources and samples separately so the ratio is visible.

## The two clocks

Never conflated, and both plotted:

| Series | Source | Means |
|---|---|---|
| Collected | `CollectionSet.timestamp` | when OpenNMS took the sample |
| Accepted by Kafka | Kafka record timestamp | when the broker stored it |

They track each other while the broker keeps up and separate when it does not.
That separation is the single clearest signal that the benchmark is measuring Kafka rather than OpenNMS, which is the failure mode this whole deployment is exposed to.

The mean rate is computed over the **accepted** span, since that is what the broker actually sustained.

## Dependencies

Pinned in `defaults/main.yml` and installed into a virtualenv at `{{ kafka_metrics_report_home }}/venv`.
`grpcio-tools` carries its own `protoc`, so the generated bindings and the protobuf runtime come from one pinned set — an apt `protoc` would drift against the pip runtime and fail at import.

`collectionset.proto` is vendored from upstream OpenNMS (`features/kafka/producer/src/main/proto/`).
Bindings regenerate whenever that file changes.

The floor is **CPython 3.11** (`datetime.UTC`, matching `ruff.toml`'s `target-version`); wheels are available through 3.13, which spans Debian 12 and 13.

## Records the report excludes

A record is counted only if it lands inside the offset bound *and* carries usable timestamps.
Anything dropped is named in a banner at the top of the report and sets a non-zero exit status, so a partial read is never mistaken for a clean one:

| Warning | Meaning |
|---|---|
| `poll_timeout` | the read stopped before every partition reached its end offset |
| `undecodable` | not parseable as a `CollectionSet` |
| `no_record_timestamp` | the broker supplied no timestamp — would otherwise place the sample in 1970 |
| `no_collection_timestamp` | `CollectionSet.timestamp` was unset (proto3 zero) |
| `sparse_timeline` | timestamps spanned an implausible range, so the chart shows only observed buckets rather than a zero-filled range |

## Chart

Colours are categorical slots 1 and 2 of the validated reference palette.
Both light and dark modes pass all six checks — worst adjacent CVD ΔE 24.7 light / 26.8 dark.
Do not substitute them by eye; re-run the palette validator if they change.

Identity never rests on colour alone: both series are direct-labelled at the line end (de-collided when they end at the same rate), a legend is present, and the timeline is available as a table.
