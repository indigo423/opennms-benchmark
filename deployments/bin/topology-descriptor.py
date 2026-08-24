#!/usr/bin/env python3
"""Derive the canonical descriptor from a deployment topology.yml.

The descriptor is a reproducibility fingerprint: <count><code> tokens in a fixed
component order, joined by '-', e.g. 3es-3mm-1pg-3sn-3kf-1on-2mn-nl6.

Usage:
    topology-descriptor.py <path/to/topology.yml>
    topology-descriptor.py --validate <path/to/topology.yml>   # exit non-zero on schema errors
"""
import re
import sys

# role -> descriptor code. monitoring is infra and intentionally excluded.
ROLE_CODES = {
    "core": "on",
    "minion": "mn",
    "sentinel": "sn",
    "database": "pg",
    "kafka": "kf",
    "rrd": "rr",
    "elasticsearch": "es",
    "mimir": "mm",
    "victoriametrics": "vm",
    "rustfs": "rs",
    "loadgen": "nl6",
}
# Roles that are infrastructure rather than components under test, and are
# deliberately absent from the descriptor. Anything not here and not in
# ROLE_CODES is an error: silently dropping it would let two different
# topologies share a fingerprint.
EXCLUDED_ROLES = {"monitoring"}
# Fixed emit order for a stable, comparable descriptor.
ORDER = ["es", "mm", "vm", "rs", "rr", "pg", "sn", "kf", "on", "mn", "nl6"]
KNOWN_SIZES = {"tiny", "small", "medium", "large", "xlarge"}
KNOWN_SUBNETS = {"mgmt", "db", "kafka", "sim", "external", "lab"}


def _load(path):
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML required: pip install pyyaml")
    with open(path) as fh:
        return yaml.safe_load(fh)


def descriptor(spec):
    counts = {}
    for role, cfg in (spec.get("roles") or {}).items():
        if role in EXCLUDED_ROLES:
            continue
        code = ROLE_CODES.get(role)
        if code is None:
            raise SystemExit(
                f"unknown role '{role}': add it to ROLE_CODES (and ORDER) or to "
                "EXCLUDED_ROLES. Skipping it silently would drop a component "
                "from the descriptor that is meant to identify the topology."
            )
        n = int(cfg.get("count", 1))
        if n > 0:
            counts[code] = counts.get(code, 0) + n
    # nl6 is a singleton presence flag — emit bare "nl6" (no count) when count == 1.
    def tok(c):
        return "nl6" if c == "nl6" and counts[c] == 1 else f"{counts[c]}{c}"

    return "-".join(tok(c) for c in ORDER if c in counts)


def validate(path, spec):
    errors = []
    slug = spec.get("name")
    dir_slug = path.split("/")[-2] if "/" in path else None
    if not slug:
        errors.append("missing 'name'")
    elif dir_slug and slug != dir_slug:
        errors.append(f"name '{slug}' != directory '{dir_slug}'")
    if slug and not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?", slug):
        errors.append(f"slug '{slug}' not a valid DNS-1123 label (lowercase, digits, hyphen)")
    if len(slug or "") > 63:
        errors.append("slug exceeds 63 chars")
    roles = spec.get("roles") or {}
    if not roles:
        errors.append("no roles defined")
    for role, cfg in roles.items():
        where = f"role '{role}'"
        if cfg.get("size") not in KNOWN_SIZES:
            errors.append(f"{where}: size '{cfg.get('size')}' not in {sorted(KNOWN_SIZES)}")
        for sn in cfg.get("subnets") or []:
            if sn not in KNOWN_SUBNETS:
                errors.append(f"{where}: unknown subnet '{sn}'")
        if not cfg.get("groups") and role != "monitoring":
            errors.append(f"{where}: no inventory groups")
    return errors


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    do_validate = "--validate" in argv
    if len(args) != 1:
        sys.exit(__doc__)
    path = args[0]
    spec = _load(path)
    errs = validate(path, spec)
    if do_validate:
        if errs:
            print(f"INVALID {path}:", file=sys.stderr)
            for e in errs:
                print(f"  - {e}", file=sys.stderr)
            return 1
        print(f"OK {spec['name']}: {descriptor(spec)}")
        return 0
    if errs:
        print(f"warning: {path} has schema issues: {errs}", file=sys.stderr)
    print(descriptor(spec))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
