#!/usr/bin/env python3
"""Assert every update annotation is bound to the pin it names.

`renovate.json`'s custom manager associates a `# renovate:` annotation with the
version it updates by proximity: it takes the first quoted `*_version:` below
the annotation, wherever that is. Nothing in the expression requires that pin to
be the one the annotation names.

So one unquoted annotated value is enough to redirect an annotation onto an
unrelated pin. Renovate then opens a pull request raising the wrong variable to
a version that has nothing to do with it, while the intended pin quietly stops
moving. Both halves are silent (#263).

The obvious response is a stricter pattern, and it does not work. Requiring the
value on the next line fixes that case and breaks two others: an unquoted value
carrying a trailing comment is captured as `1.2.3  # pinned deliberately`, and a
blank line before the value makes the pin silently unmanaged. Renovate's custom
managers use RE2, which has no lookarounds, so no expression here can fail
loudly when the binding is absent. Every candidate is a heuristic; they differ
only in which shape they mishandle in silence.

This asserts the shape the existing pattern assumes instead, which is cheaper
than out-thinking the regex and catches one thing no regex can: an annotation
whose pin has been renamed or deleted, which is a routine edit rather than a
formatting slip.

The rule, for every annotation in a file the manager reads:

    the next line that is not a comment is a quoted `*_version:` assignment

Comment lines are skipped because `rustfs_version` carries an explanation
between its annotation and its value, and that is worth keeping. A blank line is
not skipped: every annotated pin in the repository is written without one, so
requiring it costs nothing today and keeps an annotation visually attached to
the pin it owns.

Quoting is required rather than accommodated. A quote is an unambiguous
terminator; accepting bare values means deciding where the value ends, which is
what produces the trailing-comment corruption above. All five annotated pins are
already quoted, so this describes existing practice rather than imposing on it.

The manager's own `managerFilePatterns` are read from `renovate.json` rather
than restated here, so this check follows the manager if the manager moves.

Usage:
    validate-renovate-pins.py [--repo-root PATH]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# An annotation, not prose about one. `datasource=` is what the manager requires
# and what separates a directive from a comment explaining why a pin has none.
ANNOTATION_RE = re.compile(r"^\s*#\s*renovate:\s*datasource=\S+\s+depName=(?P<dep>\S+)")
COMMENT_RE = re.compile(r"^\s*#")
PIN_RE = re.compile(r'^[a-z0-9_]+_version:\s*"[^"]+"\s*$')
VERSION_KEY_RE = re.compile(r"^([a-z0-9_]+_version):")


def manager_patterns(repo_root: Path) -> list[re.Pattern[str]]:
    """File patterns the custom managers read, as Renovate writes them.

    Renovate spells these `/^…$/`, a regex wrapped in slashes. A plain string
    would be a prefix match, which the repository does not use, and treating one
    as a regex would silently match nothing.
    """
    config = json.loads((repo_root / "renovate.json").read_text())
    patterns: list[re.Pattern[str]] = []
    for manager in config.get("customManagers", []):
        for raw in manager.get("managerFilePatterns", []) or manager.get("fileMatch", []):
            if raw.startswith("/") and raw.endswith("/"):
                patterns.append(re.compile(raw[1:-1]))
            else:
                sys.stderr.write(
                    f"warning: managerFilePatterns entry {raw!r} is not a /regex/; skipped\n"
                )
    return patterns


def candidate_files(repo_root: Path) -> list[str]:
    """Files to scan, tracked ones by preference.

    `git ls-files` matches how every other lint target in this repository picks
    its inputs, so an untracked scratch file is not checked. A fixture is a bare
    directory rather than a repository, so fall back to walking it; the manager
    patterns filter either list to the same set.
    """
    try:
        out = subprocess.run(
            ["git", "ls-files"], cwd=repo_root, capture_output=True, text=True, check=True
        )
        listed = out.stdout.splitlines()
        if listed:
            return listed
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return [
        str(path.relative_to(repo_root))
        for path in sorted(repo_root.rglob("*"))
        if path.is_file()
    ]


def check_file(path: Path, rel: str) -> list[str]:
    """Findings for one file, as human-readable lines."""
    findings: list[str] = []
    lines = path.read_text().splitlines()
    for index, line in enumerate(lines):
        match = ANNOTATION_RE.match(line)
        if not match:
            continue
        dep = match.group("dep")
        cursor = index + 1
        while cursor < len(lines) and COMMENT_RE.match(lines[cursor]):
            cursor += 1
        where = f"{rel}:{index + 1}"
        if cursor >= len(lines):
            findings.append(
                f"{where}: annotation for {dep} is the last thing in the file, "
                f"so it names no pin"
            )
            continue
        candidate = lines[cursor]
        if PIN_RE.match(candidate):
            continue
        key = VERSION_KEY_RE.match(candidate)
        if key:
            findings.append(
                f"{where}: annotation for {dep} is followed by {key.group(1)}, "
                f"whose value is not quoted. The manager skips it and binds this "
                f"annotation to the next quoted pin instead"
            )
        elif not candidate.strip():
            findings.append(
                f"{where}: annotation for {dep} is followed by a blank line. "
                f"Put the pin directly beneath it, or beneath its explanation"
            )
        else:
            findings.append(
                f"{where}: annotation for {dep} is followed by "
                f"{candidate.strip()[:40]!r}, not a quoted *_version: assignment. "
                f"If the pin was renamed or removed, remove the annotation too"
            )
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root")
    args = parser.parse_args()
    repo_root = Path(args.repo_root).resolve()

    if not (repo_root / "renovate.json").is_file():
        sys.stderr.write(f"error: no renovate.json under {repo_root}\n")
        return 2

    patterns = manager_patterns(repo_root)
    if not patterns:
        sys.stderr.write("error: no usable managerFilePatterns in renovate.json\n")
        return 2

    findings: list[str] = []
    checked = 0
    annotations = 0
    for rel in candidate_files(repo_root):
        if not any(pattern.search(rel) for pattern in patterns):
            continue
        path = repo_root / rel
        if not path.is_file():
            continue
        checked += 1
        # Counted per line, not with findall over the whole text: ANNOTATION_RE
        # is anchored with ^ and findall would silently return nothing, which
        # would let this check report a vacuous pass over files it never read.
        annotations += sum(1 for line in path.read_text().splitlines()
                           if ANNOTATION_RE.match(line))
        findings.extend(check_file(path, rel))

    if findings:
        for finding in findings:
            sys.stderr.write(f"{finding}\n")
        sys.stderr.write(
            f"\n{len(findings)} annotation(s) not bound to a pin, across "
            f"{checked} file(s) the manager reads\n"
        )
        return 1

    if annotations == 0:
        sys.stderr.write(
            "error: no update annotations found in any file the manager reads. "
            "Either every pin lost its annotation, or this check is looking in "
            "the wrong place; both are worth failing over\n"
        )
        return 1

    print(f"{annotations} update annotation(s) bound to a pin, across {checked} file(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
