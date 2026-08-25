#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# sync.sh — export this repository's main to the public fork as one squash commit.
#
# The public fork is NOT a fast-forward mirror of main. Main's history contains
# benchmarking work that is out of scope for the public fork: it was added over
# a dozen commits and later removed again. Replaying that history would publish
# every line of it and then delete it, which leaves it permanently reachable.
# So each sync imports the whole upstream range as a single commit whose tree is
# main's tip, parented on the fork's current head. Granular history stays here;
# the fork gets a clean, linear series of sync commits.
#
# On top of the squash, scrub.py rewrites the prose that still names that work,
# and this directory is dropped from the exported tree — the sync tooling is a
# lab-side concern and its rules necessarily spell out the terms being removed.
#
# The export is gated: if the deny pattern matches anywhere in the exported tree
# or in any commit message reachable from the new head, the script aborts and
# nothing is pushed. Add a rule to scrub.py rather than weakening the gate.
#
# Usage:
#   tools/forge/sync.sh                 # build and verify, do not push
#   tools/forge/sync.sh --push          # build, verify, then push
#   tools/forge/sync.sh --upstream <ref> --remote <name>
#
# Defaults: --upstream origin/main, --remote fork.

set -euo pipefail

UPSTREAM="origin/main"
REMOTE="fork"
PUSH="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --push)     PUSH="yes"; shift ;;
    --upstream) UPSTREAM="${2:?--upstream needs a ref}"; shift 2 ;;
    --remote)   REMOTE="${2:?--remote needs a name}"; shift 2 ;;
    -h|--help)  sed -n '5,30p' "$0"; exit 0 ;;
    *)          echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
TOOL_DIR="tools/forge"
SCRUB="$REPO_ROOT/$TOOL_DIR/scrub.py"

cd "$REPO_ROOT"

# ── fetch both sides so the comparison is against reality, not a stale ref ────

echo "==> fetching $REMOTE"
git fetch "$REMOTE" --quiet

# --upstream may name a remote-tracking ref (origin/main) or a local one. Only
# the former has a remote to refresh; a local ref is taken as-is.
UPSTREAM_REMOTE="${UPSTREAM%%/*}"
if git remote | grep -qx "$UPSTREAM_REMOTE"; then
  echo "==> fetching $UPSTREAM_REMOTE"
  git fetch "$UPSTREAM_REMOTE" --quiet
fi

FORK_HEAD="$(git rev-parse "$REMOTE/main")"
UP_HEAD="$(git rev-parse "$UPSTREAM")"

echo "    fork head:     $(git rev-parse --short "$FORK_HEAD")"
echo "    upstream head: $(git rev-parse --short "$UP_HEAD")"

if [ "$(git rev-parse "$FORK_HEAD^{tree}")" = "$(git rev-parse "$UP_HEAD^{tree}")" ]; then
  echo "==> fork tree already matches upstream; nothing to sync"
  exit 0
fi

# ── build the export in a throwaway worktree, never in the caller's tree ──────

WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-sync.XXXXXX")"
cleanup() {
  git worktree remove --force "$WORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  git worktree prune
}
trap cleanup EXIT

echo "==> staging export in $WORK"
git worktree add --detach "$WORK" "$FORK_HEAD" >/dev/null

# Replace the fork's tree wholesale with upstream's, then subtract what must
# not ship. read-tree touches the index and working tree together, so the
# export starts out byte-identical to the upstream tip.
git -C "$WORK" read-tree -u --reset "$UP_HEAD"
if git -C "$WORK" ls-files --error-unmatch "$TOOL_DIR" >/dev/null 2>&1; then
  git -C "$WORK" rm -r --quiet --cached "$TOOL_DIR" >/dev/null
  rm -rf "${WORK:?}/$TOOL_DIR"
  echo "    dropped $TOOL_DIR from the export"
fi

echo "==> applying prose rules"
python3 "$SCRUB" apply "$WORK"

# ── gate: nothing matching the deny pattern may reach the fork ───────────────

PATTERN="$(python3 "$SCRUB" pattern)"

echo "==> scanning exported tree"
git -C "$WORK" add -A
if MATCHES="$(git -C "$WORK" grep -inE "$PATTERN" -- . 2>/dev/null)"; then
  echo "REFUSING TO EXPORT — deny pattern matches the exported tree:" >&2
  echo "$MATCHES" >&2
  echo "Add a rule to $TOOL_DIR/scrub.py; do not weaken the pattern." >&2
  exit 1
fi
echo "    clean"

if git -C "$WORK" diff --cached --quiet; then
  echo "==> export is identical to the fork's head; nothing to commit"
  exit 0
fi

# ── commit ───────────────────────────────────────────────────────────────────

UP_SHORT="$(git rev-parse --short "$UP_HEAD")"
UP_SUBJECT="$(git log -1 --format=%s "$UP_HEAD")"

git -C "$WORK" commit --quiet -s -F - <<EOF
chore: sync upstream through $UP_SHORT

Squash-sync of upstream main onto this fork, covering the range from the
previous sync point ($(git rev-parse --short "$FORK_HEAD")) to upstream $UP_SHORT.

The range is imported as a single commit whose tree is the upstream tip
rather than replayed commit by commit: it carries work that is out of
scope for this repository and was later reverted upstream, and replaying
it would publish those lines into this history only to delete them again.

Generated by tools/forge/sync.sh, which is itself not exported.

Upstream tip: $UP_SHORT $UP_SUBJECT

Assisted-by: ClaudeCode:claude-opus-5
EOF

NEW_HEAD="$(git -C "$WORK" rev-parse HEAD)"

echo "==> scanning commit messages across the fork's whole history"
if MSG_HITS="$(git -C "$WORK" log --format='%H %s%n%b' "$NEW_HEAD" | grep -inE "$PATTERN")"; then
  echo "REFUSING TO EXPORT — deny pattern matches a commit message:" >&2
  echo "$MSG_HITS" >&2
  exit 1
fi
echo "    clean"

echo
echo "==> export ready: $(git -C "$WORK" rev-parse --short "$NEW_HEAD")"
git -C "$WORK" show --stat --format='    %h %s' "$NEW_HEAD" | head -20

if [ "$PUSH" != "yes" ]; then
  # The worktree is about to go away. Anchor the commit to a ref so it stays
  # reachable (and inspectable) instead of becoming garbage.
  git update-ref refs/forge-sync/pending "$NEW_HEAD"
  echo
  echo "Not pushing (no --push). The commit is kept at refs/forge-sync/pending:"
  echo "    git show refs/forge-sync/pending"
  echo "    git push $REMOTE refs/forge-sync/pending:refs/heads/main"
  exit 0
fi

echo
echo "==> pushing to $REMOTE/main (fast-forward)"
git push "$REMOTE" "$NEW_HEAD:refs/heads/main"
echo "==> done"
