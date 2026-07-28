#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Tasks 1.1-1.4: build the shared fixture ONCE — pinned checkout -> assembly
# tarball -> container image. Re-runs skip completed steps (shared-fixture rule:
# never rebuild an identical SHA). Identities land in build/fixture-identity.json.
set -euo pipefail

PINNED_SHA=03b6b6dd8cfb3d3b90094530d7b2d10439fe0a48
IMAGE_TAG="horizon-bench:${PINNED_SHA:0:8}"
EXP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$EXP_DIR/build}"
SRC_DIR="$BUILD_DIR/opennms"
IDENTITY="$BUILD_DIR/fixture-identity.json"

mkdir -p "$BUILD_DIR"

if [ -f "$IDENTITY" ]; then
  IDENTITY_SHA="$(jq -r '.git_sha' "$IDENTITY")"
  if [ "$IDENTITY_SHA" = "$PINNED_SHA" ]; then
    echo "HORIZON_IMAGE=$(jq -r '.image' "$IDENTITY")" > "$EXP_DIR/.env"
    echo "fixture-identity.json matches $PINNED_SHA — fixture already built, reusing (task 1.4):"
    cat "$IDENTITY"
    exit 0
  fi
  echo "fixture-identity.json is for $IDENTITY_SHA, not $PINNED_SHA — rebuilding"
  rm -f "$IDENTITY"
fi

# --- 1.1 pinned checkout + toolchain record ---------------------------------
if [ ! -d "$SRC_DIR/.git" ]; then
  git clone https://github.com/OpenNMS/opennms "$SRC_DIR"
fi
git -C "$SRC_DIR" fetch origin "$PINNED_SHA"
git -C "$SRC_DIR" checkout --detach "$PINNED_SHA"
if [ -n "$(git -C "$SRC_DIR" status --porcelain)" ]; then
  echo "ABORT: source tree has local modifications — a tarball built from it would" >&2
  echo "carry uncommitted changes while the manifest certifies $PINNED_SHA." >&2
  exit 1
fi

JAVA_VERSION="$(java -version 2>&1 | head -1)"
# Braces group the wrapper/fallback pair so this reads as "cd, then try ./mvnw
# else mvn" — the previous `cd && a || b` form let `mvn --version` run when the
# cd itself failed, reporting a toolchain from the wrong directory.
MVN_VERSION="$(cd "$SRC_DIR" && { ./mvnw --version 2>/dev/null || mvn --version; } | head -1)"
echo "toolchain: $JAVA_VERSION / $MVN_VERSION"

# --- 1.2 assembly tarball ----------------------------------------------------
# Exact invocation is defined by the checked-out branch (README/.circleci) —
# historically ./compile.pl then ./assemble.pl. Verify there before trusting this.
# A tarball is only reused when the marker ties it to the pinned SHA — a
# leftover from an interrupted or different-SHA build is discarded, never
# silently baked into the fixture.
MARKER="$SRC_DIR/opennms-full-assembly/target/.built-from-sha"
# The assembly emits a core + an optional tarball; opennms-container/core
# consumes the CORE one. Anything other than exactly one core tarball aborts.
pick_tarball() {
  local list count
  list="$(ls "$SRC_DIR"/opennms-full-assembly/target/*-core.tar.gz 2>/dev/null || true)"
  count="$(printf '%s' "$list" | grep -c . || true)"
  if [ "$count" -gt 1 ]; then
    echo "ABORT: multiple *-core.tar.gz in opennms-full-assembly/target — the" >&2
    echo "fixture identity would be ambiguous. Remove all but one:" >&2
    printf '%s\n' "$list" >&2
    exit 1
  fi
  printf '%s' "$list"
}
TARBALL="$(pick_tarball)"
if [ -n "$TARBALL" ] && [ "$(cat "$MARKER" 2>/dev/null || true)" != "$PINNED_SHA" ]; then
  echo "discarding stale tarball not tied to $PINNED_SHA: $TARBALL"
  rm -f "$SRC_DIR"/opennms-full-assembly/target/*.tar.gz "$MARKER"
  TARBALL=""
fi
if [ -z "$TARBALL" ]; then
  # -DskipTests=true: unit tests don't change the artifact, and the shell-test
  # harness (core/cli run-tests.sh) exits 1 on macOS even when all tests pass.
  (cd "$SRC_DIR" && ./compile.pl -DskipTests=true \
    && ./assemble.pl -DskipTests=true -Dopennms.home=/opt/opennms)
  TARBALL="$(pick_tarball)"
  [ -n "$TARBALL" ] || { echo "ABORT: assembly produced no tarball" >&2; exit 1; }
  echo "$PINNED_SHA" > "$MARKER"
fi
TARBALL_SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
echo "tarball: $TARBALL ($TARBALL_SHA256)"

# --- 1.3 container image from the tarball ------------------------------------
# Upstream recipe: `make image` sanity-checks the tarball, unpacks it into
# tarball-root/, and drives docker buildx with the branch's build args.
# It requires the DEFAULT buildx builder to be active and tags the result
# opennms/horizon:<pom-version>; we retag to our pinned fixture tag.
UPSTREAM_VERSION="$("$SRC_DIR/.circleci/scripts/pom2version.sh" "$SRC_DIR/pom.xml")"
make -C "$SRC_DIR/opennms-container/core" image
docker image tag "opennms/horizon:$UPSTREAM_VERSION" "$IMAGE_TAG"
IMAGE_DIGEST="$(docker inspect --format '{{.Id}}' "$IMAGE_TAG")"

# --- record identities (feeds every run manifest) -----------------------------
jq -n \
  --arg sha "$PINNED_SHA" \
  --arg tarball "$(basename "$TARBALL")" \
  --arg tarball_sha256 "$TARBALL_SHA256" \
  --arg image "$IMAGE_TAG" \
  --arg image_digest "$IMAGE_DIGEST" \
  --arg java "$JAVA_VERSION" \
  --arg maven "$MVN_VERSION" \
  '{git_sha: $sha, tarball: $tarball, tarball_sha256: $tarball_sha256,
    image: $image, image_digest: $image_digest,
    toolchain: {java: $java, maven: $maven}}' > "$IDENTITY"

echo "HORIZON_IMAGE=$IMAGE_TAG" > "$EXP_DIR/.env"

echo "fixture built once — identity:"
cat "$IDENTITY"
