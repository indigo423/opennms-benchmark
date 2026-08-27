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

# The aws provider is configured on every `terraform console` invocation, even
# though this check only evaluates locals. With no credentials it falls through
# to IMDS, and on a CI runner 169.254.169.254 answers without being EC2, so the
# SDK retries with backoff for the better part of a minute -- per render, times
# fifteen specs plus fixtures. deploy.sh disables it for exactly this reason
# ("a two-minute IMDS probe"); a check that renders aws needs the same. Harmless
# for the other providers.
export AWS_EC2_METADATA_DISABLED=true
# Providers whose Terraform root consumes deployments/<slug>/topology.yml. Adding
# one here is what makes its copy of the rules checked; while this looped over
# kvm alone, aws's identical invariants went unasserted from the day it landed.
# Overridable so a single provider can be checked in isolation while iterating.
read -r -a PROVIDERS <<< "${TOPOLOGY_PROVIDERS:-kvm aws proxmox}"
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
# coalesce(r.via, "-") rather than r.via: contains() rejects a null "value"
# argument, and a spec with no generator leaves net_sim.via null (es-cluster-min
# is elasticsearch + monitoring only). The `r.via != null` guard in front does not
# save it -- HCL evaluates both operands of && on some versions and not others,
# which is the same trap as the unresolved-route test, and the reason this passed
# locally on 1.12 and failed in CI on the version `~1.5` resolves. "-" is never an
# address, so the result is unchanged wherever the guard does short-circuit.
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
# coalesce(r.via, "-") rather than r.via: contains() rejects a null "value"
# argument, and a spec with no generator leaves net_sim.via null (es-cluster-min
# is elasticsearch + monitoring only). The `r.via != null` guard in front does not
# save it -- HCL evaluates both operands of && on some versions and not others,
# which is the same trap as the unresolved-route test, and the reason this passed
# locally on 1.12 and failed in CI on the version `~1.5` resolves. "-" is never an
# address, so the result is unchanged wherever the guard does short-circuit.
#
# The last is the invariant the preconditions do not express, and precisely the
# one #171 violated: .134 was a well-formed address that belonged to nothing.
read -r -d '' EXPR <<'HCL' || true
concat([for u in local.spec_unsupported : "unsupported ${u}"], [for a in distinct(local.all_addresses) : "duplicate address ${a}" if length([for b in local.all_addresses : b if b == a]) > 1], [for r in local.unresolved_named_routes : "unresolved route ${r}"], [for h, v in local.inv_hosts : "unreachable node ${h} has no mgmt address" if v.ansible_host == ""], [for n, r in local.named_routes : "next hop not held ${n} -> ${r.via}" if r.via != null && !contains(local.all_addresses, coalesce(r.via, "-"))])
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
# subnet_lab is the exception that matters: a spec that declares the `lab`
# subnet renders its NICs from it, so it has to be a real CIDR or that spec
# cannot be evaluated.
# Placeholder values per provider. None affects the invariants being asserted;
# they exist because Terraform requires every declared variable to have a value.
# Deliberately does NOT read <provider>.tfvars: those are host-specific and
# gitignored, so depending on them would make the check pass or fail differently
# on a developer's machine than in CI -- the opposite of a gate.
#
# subnet_lab is the exception that matters on kvm: a spec that declares the `lab`
# subnet renders its NICs from it, so it has to be a real CIDR.
#
# libvirt_uri points at 127.0.0.1:1 rather than a .invalid hostname. The provider
# connects when it is configured, and a name that does not resolve is not the same
# as a connection that is refused: on a CI runner the lookup does not fail
# promptly, so the first render produced no output and was killed at the per-spec
# timeout -- which is why this check has never passed in CI, on this branch or on
# #264. Port 1 on loopback refuses immediately and needs no DNS. It still has to
# contain "@host/", because output "libvirt_host" extracts the hostname with a
# regex that errors on a URI without one.
provider_var_args() {
  case "$1" in
    kvm)
      printf '%s\n' \
        -var-file=../lab.tfvars -var-file=../lab-addresses.tfvars \
        -var-file=../disk-sizes.tfvars \
        -var "project_name=benchmark" -var "environment=validation" \
        -var "libvirt_uri=qemu+ssh://placeholder@127.0.0.1:1/system" \
        -var "storage_pool=default" \
        -var "ubuntu_cloud_image=https://example.invalid/noble.img" \
        -var "ssh_key_path=$DUMMY_KEY_DIR/id" \
        -var "bridge_name=br0" -var "subnet_lab=192.168.11.0/24" \
        -var 'lab_nameservers=["192.168.11.1"]'
      ;;
    aws)
      # aws derives every address from the spec and declares none of
      # lab-addresses, so passing that file would warn on every render.
      printf '%s\n' \
        -var-file=../lab.tfvars -var-file=../disk-sizes.tfvars \
        -var "region=eu-central-1" \
        -var "project_name=benchmark" -var "environment=validation"
      ;;
    proxmox)
      # No project_name/environment: proxmox names guests from the topology and
      # has no resource-name prefix, so it declares neither. No lab-addresses
      # either: like aws, every address comes from the spec.
      printf '%s\n' \
        -var-file=../lab.tfvars -var-file=../disk-sizes.tfvars \
        -var "proxmox_endpoint=https://validation.invalid:8006/" \
        -var "proxmox_api_token=validation@pam!placeholder=00000000-0000-0000-0000-000000000000" \
        -var "proxmox_node=validation" \
        -var "ssh_key_path=$DUMMY_KEY_DIR/id"
      ;;
    *) echo "no placeholder vars defined for provider '$1'" >&2; return 1 ;;
  esac
}


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
  ( cd "$REPO_ROOT/terraform/$PROVIDER" && printf '%s\n' "$EXPR" \
      | terraform console "${VAR_ARGS[@]}" -var "deployment=$slug" ) >"$out_f" 2>"$err_f" &
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
  # Through run_bounded, which was defined and never called: a render that hung
  # sat until the workflow timeout instead of reporting a named per-spec failure,
  # which is precisely what the function exists to prevent.
  #
  # stderr kept separate: terraform writes warnings there, and folding them into
  # stdout put warning prose inside the result brackets and had it parsed as a
  # violation.
  run_bounded "$tmp" "$err" "$slug" || rc=$?
  out="$(cat "$tmp")"
  local errout; errout="$(cat "$err")"
  rm -f "$tmp" "$err"

  if [[ $rc -eq 124 ]]; then
    printf '  %-24s ERROR  render timed out after %ss\n' "$slug" "$SPEC_TIMEOUT"
    { echo "$errout"; echo "$out"; } | grep -v '^$' | sed 's/^/      /' | head -8
    return 2
  fi

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

  # A provider that declares it cannot run this spec has already answered the
  # question; the address and reachability violations that follow are
  # consequences of the same fact, not independent defects. Report it as skipped
  # and do not fail the gate -- a KVM-only spec is a real, supported state
  # (es-victorialogs puts every role on the physical `lab` subnet, which has no
  # VPC equivalent), not a broken one.
  local unsupported
  unsupported=$(printf '%s\n' "$violations" | grep '^unsupported ' || true)
  if [[ -n "$unsupported" ]]; then
    printf '  %-24s skip  %s\n' "$slug" "$(printf '%s' "$unsupported" | head -1 | sed 's/^unsupported //')"
    return 3
  fi

  if [[ -n "$violations" ]]; then
    printf '  %-24s FAIL\n' "$slug"
    printf '      %s\n' "$violations"
    return 1
  fi
  printf '  %-24s ok\n' "$slug"
  return 0
}

# One provider's worth of work: every real spec, then the fixtures. Unchanged in
# logic from when this ran only against kvm; the point is that it now runs once
# per provider that consumes the specs.
# `terraform console` needs the provider plugins present. Each provider root is
# initialised by its own CI job, but those are separate jobs with separate
# checkouts, and a fresh clone has none -- so initialise on demand rather than
# assuming. -backend=false keeps it credential-free and state-free.
ensure_init() {
  [[ -d "$REPO_ROOT/terraform/$PROVIDER/.terraform/providers" ]] && return 0
  printf '==> Initialising terraform/%s (first run)\n' "$PROVIDER"
  local log
  # -upgrade so the community libvirt provider downloads on kvm, matching the
  # Makefile's own init for that root.
  if ! log="$(terraform -chdir="$REPO_ROOT/terraform/$PROVIDER" init -backend=false -upgrade -input=false 2>&1)"; then
    printf 'ERROR  terraform init failed in %s\n' "terraform/$PROVIDER" >&2
    printf '%s\n' "$log" | sed 's/^/      /' >&2
    return 2
  fi
  return 0
}

check_provider() {
  PROVIDER="$1"
  # A while-read loop rather than `mapfile`: mapfile is bash 4+, and macOS ships
  # 3.2, so it would have passed in CI and failed on a maintainer's laptop --
  # the local/CI split the Makefile front door exists to prevent.
  VAR_ARGS=()
  local argf line
  argf="$(mktemp)"
  if ! provider_var_args "$PROVIDER" >"$argf"; then rm -f "$argf"; return 2; fi
  while IFS= read -r line; do VAR_ARGS+=("$line"); done <"$argf"
  rm -f "$argf"
  [[ ${#VAR_ARGS[@]} -gt 0 ]] || return 2
  ensure_init || return 2

  echo "==> Validating rendered topologies (provider: $PROVIDER)"

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
    # 3 is "this provider says it cannot run this spec", which is a supported
    # state and not a violation. Anything else non-zero is.
    if [[ $rc -ne 0 && $rc -ne 3 ]]; then fail=1; fi
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
          # A fixture the provider calls unsupported was never actually judged, so
          # the invariant it exists to assert went unasserted. Distinct from a real
          # spec, where skip is a legitimate outcome.
          3) printf '  %-24s FAIL  provider calls it unsupported, so the invariant\n' "$slug"
             printf '  %-24s       under test was never asserted\n' "" ; fail=1 ;;
          *) printf '  %-24s FAIL  did not render at all; a fixture must be caught by an\n' "$slug"
             printf '  %-24s       invariant, not be too broken to evaluate\n' "" ; fail=1 ;;
        esac
      fi
    done
  fi


  return 0
}

for provider in "${PROVIDERS[@]}"; do
  check_provider "$provider" || fail=1
  echo
done

echo
if [[ $fail -ne 0 ]]; then
  echo "topology validation FAILED ($checked spec(s) checked)"
  exit 1
fi
echo "all $checked rendered topolog(ies) valid"
