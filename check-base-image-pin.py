#!/usr/bin/env python3
"""Refuse a KVM base image pin bump while the host still holds a lab built on the old one.

Bumping `ubuntu_cloud_image` changes `ubuntu_image_tag`, which changes the name
of `libvirt_volume.ubuntu_base`, which replaces it. Every `libvirt_volume.os` in
the lab is a qcow2 whose backing file is that volume, so each one plans a change
to `backing_store.path`.

libvirt 0.9.9 declares no `RequiresReplace` on `backing_store`, so that plans as
an in-place update and lands in the provider's `Update`, which errors
unconditionally (dmacvicar/terraform-provider-libvirt#1374). Terraform reaches
that error only after it has already destroyed the old base volume. The apply
aborts with the pool missing a file that both the state and every overlay's
qcow2 header still name; the running domains survive on an open file descriptor
and die at their next reboot; and no subsequent apply can converge. Measured in
#261.

`create_before_destroy` on the base volume makes that failure harmless, but it
does not make the bump work, and it will stop helping the moment #1374 lands and
the OS volumes start being replaced and recreated blank. So the bump is refused
here, before Terraform runs at all.

Why this is a script and not a `lifecycle.precondition`: the comparison needs the
tag recorded in prior state, and no Terraform expression can read it. A
`terraform_data` holding the tag has its `output` become `(known after apply)`
the moment the input changes, so a precondition against it defers to apply time
and then compares the new value with itself. Verified, not assumed. The
repository's other guards (`terraform_data.address_uniqueness`,
`terraform_data.named_route_targets`) are preconditions because they only ever
read config-derived locals, which is the one thing a precondition can do.

Usage:
    check-base-image-pin.py --state PATH --pin URL
    check-base-image-pin.py --assert-derivation PATH
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

# Must mirror `ubuntu_image_tag` in terraform/kvm/modules/compute/main.tf. The
# two live on opposite sides of the Terraform boundary and cannot share code, so
# --assert-derivation fails the build if that file's rule stops matching this
# one. See #261.
VOLUME_PREFIX = "ubuntu-24.04-base-"
DATED_RELEASE = re.compile(r"release-([0-9]+)")
HASH_LENGTH = 12


def derive_tag(pin: str) -> str:
    """The image tag `ubuntu_image_tag` produces for this pin."""
    match = DATED_RELEASE.search(pin)
    if match:
        return match.group(1)
    return hashlib.sha256(pin.encode()).hexdigest()[:HASH_LENGTH]


def recorded_tags(state_path: str) -> list[str]:
    """Distinct base image tags the OS volumes in this state were built from.

    Empty when there is no state, no OS volumes, or nothing recording a backing
    store. All of those mean there is no lab to protect.
    """
    try:
        with open(state_path, encoding="utf-8") as handle:
            state = json.load(handle)
    except FileNotFoundError:
        return []
    except json.JSONDecodeError as exc:
        raise SystemExit(f"error: {state_path} is not valid JSON: {exc}") from exc

    tags: list[str] = []
    for resource in state.get("resources", []):
        if resource.get("type") != "libvirt_volume" or resource.get("name") != "os":
            continue
        for instance in resource.get("instances", []):
            backing = (instance.get("attributes") or {}).get("backing_store")
            if not backing:
                continue
            path = backing.get("path")
            if not path:
                continue
            name = os.path.basename(path)
            if not name.startswith(VOLUME_PREFIX):
                continue
            tag = name[len(VOLUME_PREFIX):]
            if tag not in tags:
                tags.append(tag)
    return tags


def assert_derivation(tf_path: str) -> int:
    """Fail if the Terraform rule this script mirrors has changed."""
    try:
        with open(tf_path, encoding="utf-8") as handle:
            source = handle.read()
    except FileNotFoundError:
        print(f"error: {tf_path} not found", file=sys.stderr)
        return 1

    expected = {
        'regex("release-([0-9]+)"': "the dated-release capture",
        f", 0, {HASH_LENGTH})": f"the {HASH_LENGTH}-character hash fallback",
        f'"{VOLUME_PREFIX}${{local.ubuntu_image_tag}}"': "the volume name prefix",
    }
    missing = [why for literal, why in expected.items() if literal not in source]
    if missing:
        print(
            f"error: {tf_path} no longer matches the derivation in "
            f"{os.path.basename(__file__)}:",
            file=sys.stderr,
        )
        for why in missing:
            print(f"  missing: {why}", file=sys.stderr)
        print(
            "\nThe deploy-time guard derives the image tag independently, because "
            "prior state\nis unreachable from HCL. If the Terraform rule changed, "
            "change this script to match.",
            file=sys.stderr,
        )
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", help="path to the KVM terraform.tfstate")
    parser.add_argument("--pin", help="the configured ubuntu_cloud_image value")
    parser.add_argument(
        "--assert-derivation",
        metavar="PATH",
        help="check the Terraform rule still matches this script, then exit",
    )
    args = parser.parse_args()

    if args.assert_derivation:
        return assert_derivation(args.assert_derivation)

    if not args.state or not args.pin:
        parser.error("--state and --pin are both required")

    new_tag = derive_tag(args.pin)
    old_tags = recorded_tags(args.state)

    # No lab, nothing to protect. A first deploy must not be obstructed.
    if not old_tags:
        return 0

    if old_tags == [new_tag]:
        return 0

    # More than one recorded tag means a previous bump half-applied. Name them
    # all; reporting only the first would hide the mess.
    listed = ", ".join(old_tags)
    plural = "tags" if len(old_tags) > 1 else "tag"
    built = f"VM OS disks were built from base image {plural}:"
    wanted = "The configured pin would produce:"
    width = max(len(built), len(wanted))
    print(
        f"""error: refusing to apply. The base image pin does not match this lab.

  {built:<{width}}  {listed}
  {wanted:<{width}}  {new_tag}

Applying this would replace libvirt_volume.ubuntu_base. With libvirt 0.9.9 that
destroys the running VMs' backing file and then aborts on the provider's Update
(dmacvicar/terraform-provider-libvirt#1374), leaving a lab that cannot be
recovered by another apply. See #261.

A pin bump on a populated host is a rebuild. To proceed:

  make destroy PROVIDER=kvm
  make deploy PROVIDER=kvm [DEPLOYMENT=...]

To keep this lab, restore the pin that built it in terraform/kvm/kvm.tfvars.""",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
