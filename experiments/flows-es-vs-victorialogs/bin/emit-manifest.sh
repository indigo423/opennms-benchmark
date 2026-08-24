#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Run-time manifest probes (skill measure.md) + schema validation. Everything
# is probed from the running system, never asserted from config files here.
#   emit-manifest.sh <variant> <run-id>
# shellcheck disable=SC1091,SC2029,SC2086,SC2153
# env.sh resolves at runtime; $SSH_OPTS must word-split; ssh commands
# expand on the client by design - the heredocs carry only local values.
set -euo pipefail
. "$(dirname "$0")/env.sh"
V=${1:?variant}; RUN=${2:?run-id}
OUT="$EXP_DIR/results/$V"; mkdir -p "$OUT"

INFO=$(curl -sf -u admin:admin "$BASE_URL/rest/info")
PID=$(ssh $SSH_OPTS "$CORE" "pgrep -f opennms_bootstrap | head -1")
FLAGS=$(ssh $SSH_OPTS "$CORE" "sudo jcmd $PID VM.flags 2>/dev/null | tail -1")
HEAP=$(ssh $SSH_OPTS "$CORE" "ps -o command= -p $PID" | grep -oE '\-Xmx[^ ]+' | head -1)
GC=$(echo "$FLAGS" | grep -oE 'Use[A-Za-z0-9]+GC' | head -1)
DBV=$(ssh $SSH_OPTS "$CORE" "psql 'host=$DB_IP dbname=opennms_horizon user=opennms password=***' -tAc 'select version()'" 2>/dev/null \
  || ssh $SSH_OPTS "ubuntu@$DB_IP" "sudo -u postgres psql -tAc 'select version()'")
TSS=$(ssh $SSH_OPTS "$CORE" "grep -h 'org.opennms.timeseries.strategy' $OPENNMS_HOME/etc/opennms.properties* 2>/dev/null | tail -1" || echo "default=rrd")
DELTA=$(ssh $SSH_OPTS "$CORE" "sudo diff -r /opt/etc-pristine $OPENNMS_HOME/etc 2>/dev/null | head -100" || true)
CPU=$(ssh $SSH_OPTS "$CORE" "nproc; lscpu | head -3" | tr '\n' ';')
RAM=$(ssh $SSH_OPTS "$CORE" "free -g | awk '/Mem:/ {print \$2}'")
NL6V=$(curl -sf "$NL6/api/v1/version" 2>/dev/null || curl -sf "$NL6/version" 2>/dev/null || echo "unknown")
IDENT="$EXP_DIR/build/sut-identity.json"

jq -n \
  --arg question "$(sed -n '/^## Question/,/^## /p' "$EXP_DIR/plan.md" | sed '1d;$d')" \
  --arg plan "$(cat "$EXP_DIR/plan.md")" \
  --arg variant "$V" --arg run "$RUN" \
  --argjson info "$INFO" --slurpfile ident "$IDENT" \
  --arg heap "${HEAP:-unknown}" --arg gc "${GC:-unknown}" --arg flags "$FLAGS" \
  --arg dbv "$DBV" --arg tss "$TSS" --arg delta "$DELTA" \
  --arg cpu "$CPU" --arg ram "$RAM" --arg nl6v "$NL6V" \
  --arg now "$(date -u +%FT%TZ)" \
'{
  experiment: {
    question: $question,
    plan: $plan,
    independent_variable: "sut.config_delta",
    variant: $variant
  },
  sut: {
    provisioner: "ssh-tarball",
    version_identity: { version: $info.displayVersion, git_sha: $ident[0].git_sha, tarball_sha256: $ident[0].tarball_sha256 },
    jvm: { heap: $heap, gc: $gc, flags: $flags },
    db_version: ($dbv | gsub("^\\s+|\\s+$";"")),
    tss_backend: $tss,
    config_delta: $delta
  },
  host: {
    cpu: $cpu, ram_gb: ($ram|tonumber),
    disk: "qcow2 on mad-monkey default pool",
    generator_colocated: false,
    hygiene_notes: "KVM guests; governor not pinnable in-guest; hypervisor otherwise idle (lab-k8s shut off); nl6 daemon on monkey-head shared but no other active fleets"
  },
  workload: {
    axis: "push-telemetry",
    # The variant name must NOT appear here: generator_scenario is part of the
    # comparability key, and the workload is identical across variants.
    generator_scenario: "flow-ingest ipfix 200-devices seed=7 3x15min",
    generator_version: $nl6v,
    parameters: { protocol: "ipfix", rate: 1, seed: 7, listener: "Multi-UDP-9999" },
    fixtures: [ { name: "sut-tarball", identity: $ident[0].tarball_sha256 } ]
  },
  run: { id: $run, started_at: $now, ended_at: $now, trial: 1 },
  comparability_key: [
    "sut.version_identity","sut.jvm.heap","sut.jvm.gc","sut.db_version",
    "sut.tss_backend","sut.config_delta","host.cpu","host.ram_gb","host.disk",
    "host.generator_colocated","workload.axis","workload.generator_scenario",
    "workload.generator_version","workload.parameters","workload.fixtures"
  ]
}' > "$OUT/manifest-$RUN.json"

npx --yes ajv-cli validate --spec=draft2020 -s "$EXP_DIR/run-manifest.schema.json" -d "$OUT/manifest-$RUN.json"
