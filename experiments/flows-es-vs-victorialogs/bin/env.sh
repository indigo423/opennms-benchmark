# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
# Shared harness environment — source, don't execute.
# shellcheck shell=bash
# shellcheck disable=SC2034  # consumed by the sibling bin/ scripts that source this
# Addresses are the pinned lab-bridge addresses of deployments/es-victorialogs.
CORE_IP=${CORE_IP:-192.168.11.35}
STORE_IP=${STORE_IP:-192.168.11.36}
DB_IP=${DB_IP:-192.168.11.37}
NL6=${NL6:-http://192.168.11.73:8080}
CORE="ubuntu@${CORE_IP}"
STORE="ubuntu@${STORE_IP}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
OPENNMS_HOME=/opt/opennms
BASE_URL="http://${CORE_IP}:8980/opennms"
EXP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PINNED_SHA=bddd104c1016aedcdf5f3cf69c1ae9485b94cdcc
