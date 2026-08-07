<!--
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0
-->
# Correctness phase (dual-write)

The correctness diff needs both stores populated with the *same* flow stream.
The VictoriaLogs module is additive by design: ingest and querying enable
independently, so both backends can persist simultaneously while exactly one
answers queries.

Sequence (driven by `../bin/apply-variant.sh dual-write` + `../bin/run-queries.sh`):

1. Push BOTH cfgs: the elastic cfg from variant A unchanged, plus
   `org.opennms.features.flows.persistence.victorialogs.cfg` with
   `skipVictoriaLogsQueries=true` (ES answers the flow REST API). Both store
   services running.
2. Run one 15-min ingest window — both stores receive the stream.
3. Run the query set once → `results/correctness/es/`.
4. Flip `skipVictoriaLogsQueries=false` AND **restart OpenNMS**: the flow REST
   consumer holds a singleton reference that stays bound to the Elasticsearch
   query service until rebind — a config reload alone leaves ES answering
   (observed: the "VL" query set returned a 36 s success on a shape the VL
   client kills at its 30 s read timeout). Then run the query set once →
   `results/correctness/vl/`.
5. `../bin/diff-quality.py results/correctness/es results/correctness/vl`
   reports per-query totals/series deltas. Expected noise sources: LogsQL
   rounding (`ElasticFuzziness`), and VL's `maxFlowDurationMs` cap silently
   under-attributing flows longer than 120 s.
