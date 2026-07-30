# opennms_kafka_producer

Enables and configures the northbound Kafka Producer on an OpenNMS Core.

The pinned `indigo423.opennms` collection has no variable for this feature, so it lives here rather than in the collection.
Everything else the `kfk-exclusive` deployment needs is expressed as collection variables.

## What it does

- Drops `featuresBoot.d/kafka-producer.boot` so the `opennms-kafka-producer` feature starts with Karaf.
- Templates `org.opennms.features.kafka.producer.cfg` (topics, `forward.metrics`, filters).
- Templates `org.opennms.features.kafka.producer.client.cfg` (`bootstrap.servers`).
- Refuses to run when the time-series strategy is `osgi` but `forward.metrics` is false.

All files are written under `{{ opennms_home | default('/opt/opennms') }}/etc`, matching the collection.
`opennms_home` is a collection default, so it is out of scope in a play that does not run `opennms_core` — hence the explicit fallback.

## Why the assertion exists

`org.opennms.timeseries.strategy=osgi` selects a Spring context whose `OsgiPersisterFactory` is constructed to **block and wait** for a `PersisterFactory` in the OSGi registry.
`KafkaPersisterActivator` registers one only when `forward.metrics=true`.

Set the strategy without the flag and Collectd blocks forever: no metrics, no error, and a benchmark that reports zero looks exactly like a benchmark that measured zero.
The assertion turns a silent, measurable-looking failure into a loud one at deploy time.

It lives in `tasks/validate.yml` rather than inline so a playbook can run it *before* the stock stack is imported.
Run only as part of `main.yml`, the assert would fire after the core role had already applied `strategy=osgi` and restarted OpenNMS — aborting onto a hung lab instead of refusing to build one.
`deployments/kfk-exclusive/playbook.yml` does exactly that in its first play.

## Variables

See `defaults/main.yml`. The two that matter:

| Variable | Default | Notes |
|---|---|---|
| `opennms_kafka_producer_forward_metrics` | `true` | must stay true under the `osgi` strategy |
| `opennms_kafka_producer_bootstrap_servers` | `{{ kafka_bootstrap_servers }}` | inherited, not restated — see #161 |

`opennms_kafka_producer_metric_filter` is unset by default.
It becomes useful once OpenConfig sources exist, since their samples land on the same `metrics` topic as Collectd's and a Collectd-only benchmark needs the streams separated.

## Verifying after deploy

The role cannot prove metrics are flowing, only that the configuration is coherent. On the Core:

```bash
grep CORE_SERVICE "${OPENNMS_HOME:-/opt/opennms}/etc/opennms.conf"   # toggles exported to the JVM
ssh -p 8101 admin@localhost                                          # Karaf shell
  feature:list -i | grep kafka-producer
  config:list "(service.pid=org.opennms.features.kafka.producer)"
```

Then on the broker, confirm the topic exists at the expected partition count and that its end offsets advance between two samples.
**Only the advancing offsets distinguish "collecting into Kafka" from "blocked".**
