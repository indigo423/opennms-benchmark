#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Flip the SUT to a variant: push the shared telemetryd config + exactly the
# variant's flow-persistence cfg(s), start only the store service(s) that
# variant uses, restart OpenNMS, wait for REST.
#
#   apply-variant.sh variant-a-es-painless | variant-b-victorialogs
#                  | dual-write            # both persist, ES answers queries
#                  | dual-write-flip       # hand the query path to VL
# shellcheck disable=SC1091,SC2029,SC2086,SC2153
# env.sh resolves at runtime; $SSH_OPTS must word-split; ssh commands
# expand on the client by design - the heredocs carry only local values.
set -euo pipefail
. "$(dirname "$0")/env.sh"
V=${1:?variant}

ETC=$OPENNMS_HOME/etc
ELASTIC_CFG=$ETC/org.opennms.features.flows.persistence.elastic.cfg
VL_CFG=$ETC/org.opennms.features.flows.persistence.victorialogs.cfg

if [ "$V" = "dual-write-flip" ]; then
  # Runtime config reload — no restart, the registrar reacts to the cfg edit.
  ssh $SSH_OPTS "$CORE" "sudo sed -i 's/^skipVictoriaLogsQueries=.*/skipVictoriaLogsQueries=false/' $VL_CFG"
  echo "query path handed to VictoriaLogs"; exit 0
fi

ssh $SSH_OPTS "$CORE" "sudo $OPENNMS_HOME/bin/opennms stop || true"
scp $SSH_OPTS "$EXP_DIR/variants/common/telemetryd-configuration.xml" "$CORE:/tmp/telemetryd-configuration.xml"
ssh $SSH_OPTS "$CORE" "sudo cp /tmp/telemetryd-configuration.xml $ETC/ && sudo rm -f $ELASTIC_CFG $VL_CFG"

case "$V" in
  variant-a-es-painless)
    scp $SSH_OPTS "$EXP_DIR/variants/variant-a-es-painless/org.opennms.features.flows.persistence.elastic.cfg" "$CORE:/tmp/elastic.cfg"
    ssh $SSH_OPTS "$CORE" "sudo cp /tmp/elastic.cfg $ELASTIC_CFG"
    ssh $SSH_OPTS "$STORE" "sudo systemctl stop victoria-logs; sudo systemctl start elasticsearch"
    ;;
  variant-b-victorialogs)
    scp $SSH_OPTS "$EXP_DIR/variants/variant-b-victorialogs/org.opennms.features.flows.persistence.victorialogs.cfg" "$CORE:/tmp/vl.cfg"
    scp $SSH_OPTS "$EXP_DIR/variants/variant-b-victorialogs/org.opennms.features.flows.persistence.elastic.cfg" "$CORE:/tmp/elastic-off.cfg"
    ssh $SSH_OPTS "$CORE" "sudo cp /tmp/vl.cfg $VL_CFG && sudo cp /tmp/elastic-off.cfg $ELASTIC_CFG"
    ssh $SSH_OPTS "$STORE" "sudo systemctl stop elasticsearch; sudo systemctl start victoria-logs"
    ;;
  dual-write)
    scp $SSH_OPTS "$EXP_DIR/variants/variant-a-es-painless/org.opennms.features.flows.persistence.elastic.cfg" "$CORE:/tmp/elastic.cfg"
    scp $SSH_OPTS "$EXP_DIR/variants/variant-b-victorialogs/org.opennms.features.flows.persistence.victorialogs.cfg" "$CORE:/tmp/vl.cfg"
    ssh $SSH_OPTS "$CORE" "sudo cp /tmp/elastic.cfg $ELASTIC_CFG && sudo sed 's/^skipVictoriaLogsQueries=.*/skipVictoriaLogsQueries=true/' /tmp/vl.cfg | sudo tee $VL_CFG >/dev/null"
    ssh $SSH_OPTS "$STORE" "sudo systemctl start elasticsearch victoria-logs"
    ;;
  *) echo "unknown variant: $V" >&2; exit 1 ;;
esac

ssh $SSH_OPTS "$CORE" "sudo $OPENNMS_HOME/bin/opennms start"
for _ in $(seq 1 90); do
  curl -sf -u admin:admin "$BASE_URL/rest/info" >/dev/null && { echo "SUT up as $V"; exit 0; }
  sleep 10
done
echo "SUT did not come up within 15 min" >&2; exit 1
