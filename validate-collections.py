#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Assert the installed Ansible collections match the declared closure exactly.

Ansible has no lockfile — `ansible-galaxy collection` offers no lock or freeze —
so requirements.yml is the manifest, and nothing verifies it. This does:

  1. every collection installed is declared, and at the declared version
  2. every dependency of every installed collection is declared, at a version
     satisfying its constraint
  3. the pinned ansible-core satisfies every collection's requires_ansible,
     which is two-sided and can be violated from either end

All facts are derived from the installed tree (MANIFEST.json, meta/runtime.yml).
Nothing about upstream's dependency graph is restated here, because a copy would
drift from it — which is the failure this check exists to prevent.

Usage:
    validate-collections.py
    validate-collections.py --path ~/.ansible/collections --requirements requirements.yml
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

# A git- or dir-sourced entry names a repository or a path, not a collection, so
# its FQCN is not derivable from the string (opennms-forge/ansible-opennms ->
# indigo423.opennms). git entries are recovered by matching the installed
# collection's own `repository` field and dir entries by reading the checkout's
# galaxy.yml, so no hand-maintained mapping can go stale. Both pin by SHA or
# path rather than by version, so they are exempt from the exact-version rule.
SOURCE_TYPES = {"git", "dir"}

OPERATORS = (">=", "<=", "==", "!=", "~=", ">", "<")


def parse_version(text):
    """Return a comparable tuple from the leading numeric components of a version."""
    parts = re.findall(r"\d+", text or "")
    return tuple(int(p) for p in parts) or (0,)


def _pad(left, right):
    """Pad two version tuples to equal length so 2.21 and 2.21.0 compare equal."""
    width = max(len(left), len(right))
    return left + (0,) * (width - len(left)), right + (0,) * (width - len(right))


def satisfies(version, constraint):
    """True if version meets a comma-separated constraint such as '>=2.18.0,<=2.21.99'.

    Raises ValueError on a clause it cannot parse. Returning True or False on an
    unrecognised operator would be a guess reported as a fact: an unhandled '~='
    once fell through to '==' and produced a ceiling breach that read exactly
    like a real one.
    """
    if not constraint or constraint == "*":
        return True
    have = parse_version(version)
    for raw in constraint.split(","):
        clause = raw.strip()
        op = next((candidate for candidate in OPERATORS if clause.startswith(candidate)), None)
        if op is None:
            raise ValueError(f"no comparison operator in constraint clause {clause!r}")
        want_text = clause[len(op):].strip().lstrip("v")
        if not re.match(r"^\d", want_text):
            raise ValueError(f"unparseable version in constraint clause {clause!r}")
        want = parse_version(want_text)
        if op == "~=":
            # PEP 440 compatible release: >= want, and < the next release of the
            # component one level up. ~=2.21.3 means >=2.21.3,<2.22.
            if len(want) < 2:
                raise ValueError(f"'~=' needs at least two version components, got {clause!r}")
            ceiling = want[:-1][:-1] + (want[-2] + 1,)
            low_have, low_want = _pad(have, want)
            high_have, high_ceiling = _pad(have, ceiling)
            if not (low_have >= low_want and high_have < high_ceiling):
                return False
            continue
        left, right = _pad(have, want)
        ok = {
            ">=": left >= right,
            "<=": left <= right,
            ">": left > right,
            "<": left < right,
            "==": left == right,
            "!=": left != right,
        }[op]
        if not ok:
            return False
    return True


def load_declared(path):
    """Return the declared map, the git URLs to resolve, and the presence-only keys.

    declared maps a key (FQCN, or a normalised git URL awaiting resolution) to
    the exact version required, or None where the entry legitimately pins by
    something other than a version. presence_only holds those keys so a missing
    `version:` on an ordinary Galaxy entry is still an error.
    """
    doc = yaml.safe_load(path.read_text()) or {}
    declared, git_urls, presence_only = {}, set(), set()
    for entry in doc.get("collections") or []:
        if isinstance(entry, str):
            declared[entry] = None
            continue
        name, version = entry.get("name"), entry.get("version")
        source = entry.get("type")
        if source == "git":
            key = normalise_repo(name)
            git_urls.add(key)
            declared[key] = None  # a SHA, not a comparable version
            presence_only.add(key)
        elif source == "dir":
            # The documented local-iteration override. Recover the FQCN from the
            # checkout's own galaxy.yml so `make validate-collections` keeps
            # working while a role is being developed against a local tree.
            key = fqcn_from_checkout(name) or name
            declared[key] = None
            presence_only.add(key)
        else:
            declared[name] = version
    return declared, git_urls, presence_only


def fqcn_from_checkout(path):
    """Read namespace.name from a local collection checkout's galaxy.yml, or None."""
    galaxy = Path(os.path.expanduser(path or "")) / "galaxy.yml"
    if not galaxy.is_file():
        return None
    meta = yaml.safe_load(galaxy.read_text()) or {}
    if meta.get("namespace") and meta.get("name"):
        return f"{meta['namespace']}.{meta['name']}"
    return None


def normalise_repo(url):
    """Strip the scheme-agnostic noise so a requirements URL matches a MANIFEST repository."""
    url = (url or "").strip()
    url = re.sub(r"^git\+", "", url)
    url = re.sub(r"\.git$", "", url)
    url = re.sub(r"^(https?://|git@)", "", url).replace(":", "/", 1)
    return url.rstrip("/").lower()


def load_installed(root):
    """Return a list of dicts describing every collection under root/ansible_collections."""
    base = root / "ansible_collections"
    if not base.is_dir():
        sys.exit(
            f"error: no ansible_collections directory under {root}\n"
            f"       nothing is installed yet — run `make install-collections` first"
        )
    found = []
    for manifest in sorted(base.glob("*/*/MANIFEST.json")):
        info = json.loads(manifest.read_text())["collection_info"]
        runtime = manifest.parent / "meta" / "runtime.yml"
        requires = None
        if runtime.is_file():
            requires = (yaml.safe_load(runtime.read_text()) or {}).get("requires_ansible")
        found.append(
            {
                "fqcn": f"{info['namespace']}.{info['name']}",
                "version": info["version"],
                "dependencies": info.get("dependencies") or {},
                "repository": normalise_repo(info.get("repository")),
                "requires_ansible": requires,
            }
        )
    return found


def pinned_core(constraints):
    """Return (version, source) for ansible-core: the constraints file, else what is running."""
    if constraints.is_file():
        for line in constraints.read_text().splitlines():
            match = re.match(r"^\s*ansible-core\s*==\s*([\w.]+)", line)
            if match:
                return match.group(1), str(constraints)
    out = subprocess.run(["ansible", "--version"], capture_output=True, text=True, check=False).stdout
    match = re.search(r"core\s+([\w.]+)", out)
    if not match:
        sys.exit("error: no ansible-core pin in constraints and `ansible --version` unreadable")
    return match.group(1), "running ansible (unpinned)"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--path", default="~/.ansible/collections", help="collections path to inspect")
    parser.add_argument("--requirements", default="requirements.yml", help="the declared manifest")
    parser.add_argument("--constraints", default="constraints.txt", help="file pinning ansible-core")
    args = parser.parse_args()

    declared, git_urls, presence_only = load_declared(Path(args.requirements))
    installed = load_installed(Path(os.path.expanduser(args.path)))
    core, core_source = pinned_core(Path(args.constraints))

    # Resolve git-sourced entries to the FQCN of the collection that came from them.
    for item in installed:
        if item["repository"] in git_urls:
            declared[item["fqcn"]] = declared.pop(item["repository"], None)
            presence_only.discard(item["repository"])
            presence_only.add(item["fqcn"])
            git_urls.discard(item["repository"])

    by_fqcn = {item["fqcn"]: item for item in installed}
    findings = []

    for item in installed:
        if item["fqcn"] not in declared:
            findings.append(f"{item['fqcn']} {item['version']} is installed but not declared in {args.requirements}")
            continue
        want = declared[item["fqcn"]]
        if want is None and item["fqcn"] not in presence_only:
            # The manifest's premise is that every collection is named at an
            # exact version. A Galaxy entry with no `version:` key would
            # otherwise be accepted silently, which is the regression this
            # check exists to catch.
            findings.append(f"{item['fqcn']} is declared without a version in {args.requirements}")
        elif want and item["version"] != want:
            findings.append(f"{item['fqcn']} is installed at {item['version']} but declared as {want}")

    for name in declared:
        if name not in by_fqcn:
            findings.append(f"{name} is declared in {args.requirements} but not installed")

    for item in installed:
        for dep, constraint in item["dependencies"].items():
            if dep not in declared:
                findings.append(
                    f"{item['fqcn']} {item['version']} requires {dep} {constraint}, which is not declared"
                )
            elif dep in by_fqcn:
                try:
                    ok = satisfies(by_fqcn[dep]["version"], constraint)
                except ValueError as exc:
                    findings.append(f"{item['fqcn']} {item['version']} declares an unreadable {dep} constraint: {exc}")
                    continue
                if not ok:
                    findings.append(
                        f"{item['fqcn']} {item['version']} requires {dep} {constraint}, "
                        f"but {dep} is at {by_fqcn[dep]['version']}"
                    )

    for item in installed:
        constraint = item["requires_ansible"]
        if not constraint:
            continue
        try:
            ok = satisfies(core, constraint)
        except ValueError as exc:
            findings.append(f"{item['fqcn']} {item['version']} declares an unreadable requires_ansible: {exc}")
            continue
        if not ok:
            findings.append(
                f"{item['fqcn']} {item['version']} requires_ansible {constraint}, "
                f"but ansible-core is pinned at {core} ({core_source})"
            )

    print(f"{len(installed)} collections installed, {len(declared)} declared, ansible-core {core} ({core_source})")
    if not findings:
        print("closure is complete and consistent")
        return 0
    print(f"\n{len(findings)} finding(s):", file=sys.stderr)
    for finding in findings:
        print(f"  - {finding}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
