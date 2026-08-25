# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Text rules for the public-fork export (see sync.sh).
#
# `main` carries prose that names benchmarking work which is out of scope for
# the public fork. The material itself is long gone from the tree; what is left
# are references by name in comments and READMEs. This module rewrites those to
# describe the prior harnesses generically, and owns the deny pattern that
# sync.sh gates the export on.
#
# RULES are best effort: upstream prose drifts, and a stale rule is reported,
# not fatal. The deny scan is the actual gate. If the scan trips, a rule needs
# adding here — do not weaken the pattern.

import sys
from pathlib import Path

# Terms that must never reach the public fork, in any tracked file.
DENY_PATTERN = r"akvorado|riptide|clickhouse"

# (relative path, exact text to find, replacement). Multi-line by design: these
# are wrapped comment blocks, and matching across the wrap keeps the rule exact
# enough that it fails loudly rather than matching something unintended.
RULES = [
    (
        "deployments/es-victorialogs/playbook.yml",
        "# Flow-backend A/B stack. Replaces opennms-playbook.yml entirely (the\n"
        "# clickhouse-riptide precedent): the SUT",
        "# Flow-backend A/B stack. Replaces opennms-playbook.yml entirely (as the\n"
        "# earlier flow-backend harnesses did): the SUT",
    ),
    (
        "deployments/roles/opennms_tarball_prereqs/tasks/main.yml",
        "# offered IPFIX datagrams (riptide-flow-capacity measured the same). The\n"
        "# buffer is a pinned experiment control, identical for every variant.",
        "# offered IPFIX datagrams (an earlier flow-capacity harness measured the\n"
        "# same). The buffer is a pinned experiment control, identical for every\n"
        "# variant.",
    ),
    (
        "experiments/flows-es-vs-victorialogs/README.md",
        "Like `riptide-flow-capacity` this is a standalone harness",
        "Like the earlier flow-capacity harnesses this is a standalone harness",
    ),
    (
        "experiments/flows-es-vs-victorialogs/README.md",
        "verified against `riptide-flow-capacity/run_scenario.sh`, not docs",
        "verified against a prior harness's `run_scenario.sh`, not docs",
    ),
    (
        "experiments/flows-es-vs-victorialogs/plan.md",
        "~7.9 on this nl6 version by the riptide experiment)",
        "~7.9 on this nl6 version by an earlier flow-capacity experiment)",
    ),
]


def apply(root: Path) -> int:
    """Rewrite every rule that still matches under root. Returns rules applied."""
    applied = 0
    for rel, old, new in RULES:
        path = root / rel
        if not path.exists():
            print(f"  rule skipped (no such file): {rel}", file=sys.stderr)
            continue
        text = path.read_text(encoding="utf-8")
        hits = text.count(old)
        if hits == 0:
            print(f"  rule stale (no match): {rel}", file=sys.stderr)
            continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        applied += 1
        print(f"  rewrote {hits}x in {rel}")
    return applied


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: scrub.py pattern | scrub.py apply <root>", file=sys.stderr)
        return 2

    if sys.argv[1] == "pattern":
        print(DENY_PATTERN)
        return 0

    if sys.argv[1] == "apply":
        if len(sys.argv) != 3:
            print("usage: scrub.py apply <root>", file=sys.stderr)
            return 2
        root = Path(sys.argv[2])
        if not root.is_dir():
            print(f"not a directory: {root}", file=sys.stderr)
            return 1
        applied = apply(root)
        print(f"  {applied}/{len(RULES)} rules applied")
        return 0

    print(f"unknown command: {sys.argv[1]}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
