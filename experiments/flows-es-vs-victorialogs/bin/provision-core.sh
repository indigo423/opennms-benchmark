#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# ssh-tarball provisioner (skill provisioner-ssh.md): ship the assembly core
# tarball to the core VM once, unpack to /opt/opennms, configure the
# datasource, run the installer, and record the SUT identity. The sha256 is
# taken from the LOCAL file before scp — hash what you shipped.
# shellcheck disable=SC1091,SC2015,SC2029,SC2086,SC2087,SC2153
# env.sh resolves at runtime; $SSH_OPTS must word-split; ssh commands
# expand on the client by design - the heredocs carry only local values.
set -euo pipefail
. "$(dirname "$0")/env.sh"

TARBALL=${TARBALL:-$EXP_DIR/../nms-20027-painless-flows/build/opennms/opennms-full-assembly/target/opennms-full-assembly-37.0.0-SNAPSHOT-core.tar.gz}
MARKER="$(dirname "$TARBALL")/.built-from-sha"

[ "$(cat "$MARKER")" = "$PINNED_SHA" ] || { echo "ABORT: tarball not built from $PINNED_SHA" >&2; exit 1; }
TARBALL_SHA256=$(shasum -a 256 "$TARBALL" | awk '{print $1}')

# DB credentials come from the lab vault (names as written by init_secrets).
VAULT_YML="$EXP_DIR/../../group_vars/opennms_stack/vault.yml"
DB_PASS=$(cd "$EXP_DIR/../.." && ansible-vault view "$VAULT_YML" | awk '/vault_opennms_db_password:/ {print $2}')
PG_PASS=$(cd "$EXP_DIR/../.." && ansible-vault view "$VAULT_YML" | awk '/vault_postgres_password:/ {print $2}')
[ -n "$DB_PASS" ] && [ -n "$PG_PASS" ] || { echo "ABORT: could not read datasource passwords from vault" >&2; exit 1; }

if ! ssh $SSH_OPTS "$CORE" "test -f /tmp/sut.tar.gz && shasum -a 256 /tmp/sut.tar.gz | grep -q $TARBALL_SHA256" 2>/dev/null; then
  scp $SSH_OPTS "$TARBALL" "$CORE:/tmp/sut.tar.gz"
fi

ssh $SSH_OPTS "$CORE" "sudo mkdir -p $OPENNMS_HOME && sudo tar -xzf /tmp/sut.tar.gz -C $OPENNMS_HOME && sudo chown -R opennms:opennms $OPENNMS_HOME"

# Pristine etc snapshot for config_delta (before any experiment overlay).
ssh $SSH_OPTS "$CORE" "sudo rm -rf /opt/etc-pristine && sudo cp -a $OPENNMS_HOME/etc /opt/etc-pristine"

# Datasource via the stock env-substituted opennms-datasources.xml (this
# branch resolves ${env:POSTGRES_HOST|...} tokens itself — hand-written XML
# fails to unmarshal). Fixed heap is a control, identical for both variants.
ssh $SSH_OPTS "$CORE" "sudo cp /opt/etc-pristine/opennms-datasources.xml $OPENNMS_HOME/etc/opennms-datasources.xml"
ssh $SSH_OPTS "$CORE" "sudo tee $OPENNMS_HOME/etc/opennms.conf >/dev/null" <<EOF
JAVA_HEAP_SIZE=8192
export POSTGRES_HOST=${DB_IP}
export OPENNMS_DBNAME=onms_benchmark
export OPENNMS_DBUSER=opennms
export OPENNMS_DBPASS=${DB_PASS}
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=${PG_PASS}
EOF

ssh $SSH_OPTS "$CORE" "sudo $OPENNMS_HOME/bin/runjava -s && sudo env POSTGRES_HOST=${DB_IP} OPENNMS_DBNAME=onms_benchmark OPENNMS_DBUSER=opennms OPENNMS_DBPASS='${DB_PASS}' POSTGRES_USER=postgres POSTGRES_PASSWORD='${PG_PASS}' $OPENNMS_HOME/bin/install -dis"

mkdir -p "$EXP_DIR/build"
jq -n --arg sha "$PINNED_SHA" --arg t "$(basename "$TARBALL")" --arg s "$TARBALL_SHA256" \
  '{git_sha:$sha, tarball:$t, tarball_sha256:$s, provisioner:"ssh-tarball"}' \
  > "$EXP_DIR/build/sut-identity.json"
echo "provisioned: $(cat "$EXP_DIR/build/sut-identity.json")"
