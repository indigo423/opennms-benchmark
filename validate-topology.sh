#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Assert that every deployment spec renders a topology that could actually be
# provisioned.
#
# `terraform validate` checks types and syntax. It does not evaluate locals
# against real values, and it does not evaluate resource preconditions, which
# are plan-time only. `topology-descriptor.py` validates the spec's shape and
# never reads `routes`. So a spec whose route points at a node that does not
# exist passes every gate the repo has, which is how a hardcoded next hop stayed
# wrong from eea387e until it was found by hand (#171).
#
# This closes that gap. `terraform console` evaluates the provider's own locals
# without contacting a hypervisor, reading state or needing credentials, so the
# rules are asserted rather than reimplemented -- a second copy of them would
# drift from the first, which is the defect class this exists to prevent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$REPO_ROOT/terraform/kvm"
DEPLOY_DIR="$REPO_ROOT/deployments"
FIXTURE_DIR="$REPO_ROOT/tests/topology-fixtures"

# One expression returning every violation for one spec. Kept on a single line
# because `terraform console` reads piped input a line at a time.
#
#   duplicate_addresses  two interfaces handed the same address
#   unresolved_routes    a named route whose target role is absent or lacks the NIC
#   nodes_without_mgmt   a node Ansible would have no address to reach
#   route_hop_not_held   a next hop that is not an address any node in this spec holds
#
# The last is the invariant the preconditions do not express, and precisely the
# one #171 violated: .134 was a perfectly well-formed address that belonged to
# nothing.
# One expression returning every violation for one spec as a single flat list of
# strings. Kept on one line because `terraform console` reads piped input a line
# at a time, and flat because parsing a structured result out of console output
# is fragile -- an earlier version keyed on field names and silently passed
# everything, because console quotes keys on both sides and the regex allowed a
# quote on only one.
#
#   duplicate address    two interfaces handed the same one
#   unresolved route     a named route whose target role is absent or lacks the NIC
#   unreachable node     a node Ansible would have no address to reach
#   next hop not held    a hop that is not an address any node in this spec holds
#
# The last is the invariant the preconditions do not express, and precisely the
# one #171 violated: .134 was a well-formed address that belonged to nothing.
read -r -d '' EXPR <<'HCL' || true
concat([for a in distinct(local.all_addresses) : "duplicate address ${a}" if length([for b in local.all_addresses : b if b == a]) > 1], [for r in local.unresolved_named_routes : "unresolved route ${r}"], [for h, v in local.inv_hosts : "unreachable node ${h} has no mgmt address" if v.ansible_host == ""], [for n, r in local.named_routes : "next hop not held ${n} -> ${r.via}" if r.via != null && !contains(local.all_addresses, r.via)])
HCL

# module.compute reads the public key with file(), and `terraform console`
# evaluates module inputs even when the expression only touches locals. A
# throwaway key keeps the check independent of whether the runner has one.
DUMMY_KEY_DIR="$(mktemp -d)"
printf 'ssh-rsa AAAAB3NzaC1yc2ETOPOLOGYVALIDATIONPLACEHOLDER validation@placeholder\n' \
  > "$DUMMY_KEY_DIR/id.pub"

# Deliberately does NOT read kvm.tfvars. That file is host-specific and
# gitignored, so depending on it would make the check pass or fail differently
# on a developer's machine than in CI -- the opposite of a gate. The values
# below are placeholders: none of them affects the invariants being asserted,
# they exist because Terraform requires every declared variable to have a value.
#
# subnet_lab is the exception that matters: clickhouse-riptide renders `lab`
# NICs from it, so it has to be a real CIDR or that spec cannot be evaluated.
VAR_FILES=(
  -var-file=../lab.tfvars
  -var-file=../lab-addresses.tfvars
  -var-file=../disk-sizes.tfvars
  -var "project_name=benchmark"
  -var "environment=validation"
  # Must contain "@host/": output "libvirt_host" extracts the hostname with a
  # regex that errors on a URI without one.
  -var "libvirt_uri=qemu+ssh://placeholder@validation.invalid/system"
  -var "storage_pool=default"
  -var "ubuntu_cloud_image=https://example.invalid/noble.img"
  -var "ssh_key_path=$DUMMY_KEY_DIR/id"
  -var "bridge_name=br0"
  -var "subnet_lab=192.168.11.0/24"
  -var 'lab_nameservers=["192.168.11.1"]'
)

fail=0
checked=0

# Fixtures are symlinked into deployments/ so var.deployment can resolve them.
# A crashed run would otherwise leave one behind, and the next run would treat
# a deliberately-broken fixture as a real deployment.
cleanup_fixture_links() {
  local d
  for d in "$DEPLOY_DIR"/*; do
    if [[ -L "$d" ]]; then rm -f "$d"; fi
  done
  return 0
}

# Separate from the above: the key must survive until the run ends. Folding the
# two together meant the startup sweep deleted it before the first spec, every
# render then failed on file(), and the harness captured warning text instead of
# a result -- reporting every spec as valid while asserting nothing.
cleanup_all() {
  cleanup_fixture_links
  rm -rf "${DUMMY_KEY_DIR:-}"
}
trap cleanup_all EXIT
cleanup_fixture_links

# Renders one spec and prints any violations. Returns 1 if the spec is bad, 2 if
# the check itself could not run -- a distinction that matters, because a broken
# harness reporting "no violations" is worse than no harness.
# `timeout(1)` is GNU-only and absent on macOS, so bound the run by hand. A
# hang here is not hypothetical: the first CI attempt sat on the very first spec
# until the job was killed at ten minutes, reporting nothing useful. A bounded
# run turns that into a named per-spec failure.
SPEC_TIMEOUT="${SPEC_TIMEOUT:-30}"

run_bounded() {
  local out_f="$1" err_f="$2" slug="$3" i pid
  ( cd "$TF_DIR" && printf '%s\n' "$EXPR" \
      | terraform console "${VAR_FILES[@]}" -var "deployment=$slug" ) >"$out_f" 2>"$err_f" &
  pid=$!
  for ((i = 0; i < SPEC_TIMEOUT; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid"
}

check_spec() {
  local slug="$1" out rc tmp err
  tmp="$(mktemp)"; err="$(mktemp)"

  # Written to a file rather than captured in a subshell: command substitution
  # around a pipeline whose left side is `echo` proved unreliable here, and a
  # check that silently produces nothing reports every spec as valid.
  # `|| rc=$?` rather than toggling errexit: `set -e` inside a function is
  # global, so restoring it here would silently re-enable it for every caller
  # and turn a returned failure into a script exit.
  rc=0
  # stderr kept separate: terraform writes warnings there, and folding them into
  # stdout put warning prose inside the result brackets and had it parsed as a
  # violation.
  ( cd "$TF_DIR" && printf '%s\n' "$EXPR" | terraform console "${VAR_FILES[@]}" -var "deployment=$slug" ) >"$tmp" 2>"$err" || rc=$?
  out="$(cat "$tmp")"
  local errout; errout="$(cat "$err")"
  rm -f "$tmp" "$err"

  if [[ $rc -ne 0 ]]; then
    printf '  %-24s ERROR  could not render\n' "$slug"
    { echo "$errout"; echo "$out"; } | grep -v '^$' | sed 's/^/      /' | head -8
    return 2
  fi

  # A harness that renders nothing would pass everything, which is the failure
  # this whole check exists to prevent. Treat it as an error, not a pass.
  if [[ -z "${out//[[:space:]]/}" ]]; then
    printf '  %-24s ERROR  console produced no output\n' "$slug"
    return 2
  fi

  # The result is a flat list. Anything between the outermost brackets is a
  # violation; console wraps it as tolist([...]) or [...] depending on type.
  local violations
  violations=$(echo "$out" | tr -d '\n' \
    | sed -e 's/^[^[]*\[//' -e 's/\][^]]*$//' \
    | tr ',' '\n' | sed -e 's/^ *"//' -e 's/" *$//' -e 's/^ *//' \
    | grep -v '^$' || true)

  if [[ -n "$violations" ]]; then
    printf '  %-24s FAIL\n' "$slug"
    printf '      %s\n' "$violations"
    return 1
  fi
  printf '  %-24s ok\n' "$slug"
  return 0
}

echo "==> Validating rendered topologies (provider: kvm)"

for spec in "$DEPLOY_DIR"/*/topology.yml; do
  [[ -e "$spec" ]] || continue
  [[ -L "$(dirname "$spec")" ]] && continue
  slug="$(basename "$(dirname "$spec")")"
  checked=$((checked + 1))
  rc=0
  check_spec "$slug" || rc=$?
  if [[ $rc -eq 2 ]]; then
    echo
    echo "aborting: a spec could not be rendered at all, so the rest would only"
    echo "repeat the same failure past the CI job limit."
    exit 1
  fi
  [[ $rc -ne 0 ]] && fail=1
done

# Fixtures are specs that MUST fail. A check that only ever sees valid input
# cannot detect a regression in its own logic -- it would keep reporting success
# while asserting nothing. They live outside deployments/ so the deployment-spec
# validator does not treat them as real topologies.
if [[ -d "$FIXTURE_DIR" ]]; then
  echo
  echo "==> Fixtures"
  for spec in "$FIXTURE_DIR"/*/topology.yml; do
    [[ -e "$spec" ]] || continue
    slug="$(basename "$(dirname "$spec")")"
    checked=$((checked + 1))

    # An `expect-pass` marker says this fixture must render cleanly. Without at
    # least one, a check that rejected everything would look identical to one
    # that works.
    want_pass=false
    if [[ -f "$FIXTURE_DIR/$slug/expect-pass" ]]; then want_pass=true; fi

    # Symlinked into deployments/ so var.deployment resolves it; removed again
    # immediately, including if the render errors.
    link="$DEPLOY_DIR/$slug"
    ln -sfn "$FIXTURE_DIR/$slug" "$link"
    rc=0
    check_spec "$slug" >/dev/null 2>&1 || rc=$?
    rm -f "$link"

    if [[ "$want_pass" == true ]]; then
      if [[ $rc -eq 0 ]]; then
        printf '  %-24s ok    passed as expected\n' "$slug"
      else
        printf '  %-24s FAIL  expected to pass, was rejected\n' "$slug"
        fail=1
      fi
    else
      case $rc in
        0) printf '  %-24s FAIL  expected to be rejected, it passed\n' "$slug"; fail=1 ;;
        1) printf '  %-24s ok    rejected as expected\n' "$slug" ;;
        *) printf '  %-24s FAIL  did not render at all; a fixture must be caught by an\n' "$slug"
           printf '  %-24s       invariant, not be too broken to evaluate\n' "" ; fail=1 ;;
      esac
    fi
  done
fi

echo
if [[ $fail -ne 0 ]]; then
  echo "topology validation FAILED ($checked spec(s) checked)"
  exit 1
fi
echo "all $checked rendered topolog(ies) valid"
