# riptide

Runs the [riptide](https://github.com/Riptide-Labs/riptide) NetFlow analysis
engine as a systemd-managed container with host networking (UDP flow ingest
needs real exporter source addresses, and a capacity benchmark must not pay
the Docker NAT/conntrack tax).

The container manages its ClickHouse schema itself on startup
(`riptide.clickhouse.manage-schema=true` is the image default), so the only
required knob is `riptide_clickhouse_endpoint` — deployments point it at the
lab address of their `clickhouse` role.

Ports (host network): `9999/udp` flow ingest, `8080` management/health
(`/livez`, `/readyz`). Docker is expected from the `docker_engine` group.
