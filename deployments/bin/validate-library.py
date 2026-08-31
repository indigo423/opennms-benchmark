#!/usr/bin/env python3
"""Assert the invariants that hold across the deployment library as a whole.

topology-descriptor.py --validate judges one spec against the schema, and
validate-topology.sh renders one spec at a time through each provider. Two
classes of drift are invisible to both, because seeing them needs either the
whole library or the provider roots alongside it:

  size-class coverage   Every class in KNOWN_SIZES must have an entry in every
                        spec-driven provider's size map. Those maps are four
                        independent copies of one list. A class added to the
                        descriptor and missed in one provider passes fmt,
                        validate, tflint and validate-deployments, then fails at
                        `terraform plan` for the first deployment that uses it.

  lab address pins      `lab` is the physical bridge every deployment on a host
                        shares, so a pinned address there is a claim against a
                        segment other specs also use. Two specs pinning the same
                        address is two live VMs answering on it. The duplicate
                        check in validate-topology.sh is computed from a single
                        rendered spec and cannot see across the library.

Only `lab` addresses are checked. The other subnets are per-deployment networks
the provider allocates, so two specs naming the same address there is expected
and harmless.

Usage:
    validate-library.py [--repo-root PATH]
"""
import importlib.util
import re
import sys
from pathlib import Path

# Provider size maps, as (label, path, headers). `headers` is the chain of HCL
# block openers to descend through, outermost first; the keys of the innermost
# object are the size classes. Every spec-driven provider appears here — azure
# and vmware do not consume deployments at all, so they own no class map.
PROVIDER_SIZE_MAPS = [
    ("kvm", "terraform/kvm/main.tf", [r"\bsize_map\s*=\s*\{"]),
    ("proxmox", "terraform/proxmox/main.tf", [r"\bsize_map\s*=\s*\{"]),
    ("aws (measured)", "terraform/aws/variables.tf",
     [r'variable\s+"instance_types"\s*\{', r"\bdefault\s*=\s*\{"]),
    ("aws (smoke)", "terraform/aws/variables.tf",
     [r'variable\s+"instance_types_smoke"\s*\{', r"\bdefault\s*=\s*\{"]),
]


def _load_yaml(path):
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML required: pip install pyyaml")
    with open(path) as fh:
        return yaml.safe_load(fh)


def _known_sizes(repo_root):
    """KNOWN_SIZES imported from the descriptor, never copied.

    A second literal list here would be a fifth copy of the thing this script
    exists to keep in sync, and it would agree with the descriptor exactly until
    the day it mattered.
    """
    path = repo_root / "deployments" / "bin" / "topology-descriptor.py"
    spec = importlib.util.spec_from_file_location("topology_descriptor", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.KNOWN_SIZES


def _brace_body(text, open_idx):
    """The text between the brace at open_idx and its match."""
    depth = 0
    for i in range(open_idx, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[open_idx + 1:i]
    raise ValueError(f"unbalanced braces from offset {open_idx}")


def hcl_map_keys(text, headers):
    """Keys of the HCL object reached by descending through `headers`.

    Deliberately not a general HCL parser: it assumes the values in these maps
    hold no braces or '#' inside strings, which is true of instance types and
    {memory, vcpu} pairs. A real parser would be a dependency for four maps.
    """
    for header in headers:
        match = re.search(header, text)
        if match is None:
            return None
        text = _brace_body(text, match.end() - 1)
    keys = set()
    depth = 0
    for line in text.splitlines():
        stripped = line.split("#", 1)[0].strip()
        if not stripped:
            continue
        if depth == 0:
            key = re.match(r"([A-Za-z_][A-Za-z0-9_-]*)\s*=", stripped)
            if key:
                keys.add(key.group(1))
        depth += stripped.count("{") - stripped.count("}")
    return keys


def check_size_classes(repo_root):
    """Every KNOWN_SIZES class is defined by every spec-driven provider."""
    errors = []
    known = _known_sizes(repo_root)
    for label, rel, headers in PROVIDER_SIZE_MAPS:
        text = (repo_root / rel).read_text()
        keys = hcl_map_keys(text, headers)
        if keys is None:
            errors.append(f"{rel}: could not locate the {label} size map; the block was renamed or reshaped")
            continue
        for missing in sorted(known - keys):
            errors.append(
                f"size class '{missing}' is in KNOWN_SIZES but missing from {label} ({rel}). "
                f"A deployment using it fails at plan time on this provider."
            )
        for extra in sorted(keys - known):
            errors.append(
                f"size class '{extra}' is defined by {label} ({rel}) but not in KNOWN_SIZES "
                f"(deployments/bin/topology-descriptor.py). No spec can reference it."
            )
    return errors


def check_lab_addresses(repo_root):
    """No two specs pin the same address on the shared physical lab bridge."""
    errors = []
    claims = {}
    for spec_path in sorted((repo_root / "deployments").glob("*/topology.yml")):
        spec = _load_yaml(spec_path)
        slug = spec_path.parent.name
        for role, cfg in ((spec or {}).get("roles") or {}).items():
            for address in ((cfg or {}).get("addresses") or {}).get("lab") or []:
                claims.setdefault(address, []).append(f"{slug}/{role}")
    for address, holders in sorted(claims.items()):
        if len(holders) > 1:
            errors.append(
                f"lab address {address} is pinned by {' and '.join(holders)}. "
                f"The lab bridge is one physical segment, so both VMs answer on it."
            )
    return errors


def main(argv):
    root = Path(__file__).resolve().parents[2]
    if "--repo-root" in argv:
        root = Path(argv[argv.index("--repo-root") + 1]).resolve()
    errors = check_size_classes(root) + check_lab_addresses(root)
    if errors:
        print("deployment library invariants violated:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("deployment library invariants hold")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
