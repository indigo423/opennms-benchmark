#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Report which *_version role defaults change between two indigo423.opennms refs.
#
# The collection pin is excluded from update automation for reproducibility,
# which also excludes from scrutiny everything its roles install: the JVM, the
# broker, the stores and the JMX exporter are all role defaults this repository
# does not pin. A reviewer has no reason to look for them, so a bump can move
# the JVM under a benchmark and read as a routine version change.
#
# This does not judge a change. It makes sure there is nothing to judge that
# nobody saw. Run it when preparing a pin bump; see docs/development-guide.md.
#
# Usage:
#   ./compare-role-defaults.sh <to-ref>              # from the pin in requirements.yml
#   ./compare-role-defaults.sh <from-ref> <to-ref>
set -euo pipefail

REPO="opennms-forge/ansible-opennms"

usage() {
  cat <<EOF
Usage: $0 [<from-ref>] <to-ref>

Compares *_version role defaults in $REPO between two refs (tag, branch or SHA).
With one argument, <from-ref> is the SHA currently pinned in requirements.yml.

Examples:
  $0 v0.9.0
  $0 v0.6.0 v0.9.0
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") echo "Error: a target ref is required" >&2; usage >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 1 ]]; then
  # The pin is a bare SHA on the `version:` line of the git-sourced entry.
  FROM=$(awk '/ansible-opennms\.git/{found=1} found && /version:/{print $2; exit}' \
    "$REPO_ROOT/requirements.yml")
  [[ -n "$FROM" ]] || { echo "Error: no pin found in requirements.yml" >&2; exit 1; }
  TO="$1"
else
  FROM="$1"
  TO="$2"
fi

# Emit "<role> <var>: <value>" for every *_version default at a ref, sorted so
# the two sides diff cleanly regardless of the order the API returns paths in.
versions_at() {
  local ref="$1" path role
  while read -r path; do
    role=$(printf '%s' "$path" | cut -d/ -f2)
    gh api "repos/$REPO/contents/$path?ref=$ref" --jq '.content' \
      | base64 -d 2>/dev/null \
      | grep -E '^[a-z_]+_version:' \
      | sed "s|^|$role |" || true
  done < <(gh api "repos/$REPO/git/trees/$ref?recursive=1" \
             --jq '.tree[].path | select(test("^roles/[^/]+/defaults/main\\.yml$"))') \
    | sort
}

echo "comparing $REPO role defaults"
echo "  from $FROM"
echo "  to   $TO"
echo

# diff exits 1 when there are differences, which is not an error here.
if out=$(diff <(versions_at "$FROM") <(versions_at "$TO")); then
  echo "no *_version role default changed"
else
  echo "$out" | grep -E '^[<>]' | sed 's/^</  removed-or-old:/; s/^>/  added-or-new:  /'
  echo
  echo "Each line above changes what a deploy installs. Confirm each is intended"
  echo "before merging the pin bump; an instrument or a measured component moving"
  echo "silently is what this check exists to prevent."
fi
