#!/usr/bin/env python3
"""Assert every documented ansible-playbook command names an inventory that exists.

Ansible treats an unparseable inventory source as a warning, not an error. Plays
then match no hosts, and a play with no matching hosts is skipped rather than
failed. So a command naming an inventory that does not exist warns once, runs
every play against zero hosts, executes nothing, and exits reporting success.

That is what #262 found in the deployment guide's step five, first-time
bootstrap: `ansible-playbook -i inventory site.yml`, run from `bootstrap/`,
where no file called `inventory` has existed for a long time. Seven plays, zero
hosts, nothing done, no error. The defect is invisible in exactly the situation
it occurs in, which is somebody following the guide for the first time.

The rule, for every fenced shell block in tracked markdown:

    every -i argument of an ansible-playbook command names a path that exists

Two things make that harder than it reads.

A block is a shell session, so `cd` inside it moves the working directory for
the commands below it, and a relative inventory path resolves against wherever
the reader has been sent. Resolving each path against the repository root would
have passed the exact command this check exists to catch. So `cd` is tracked,
and a path is resolved the way the reader's shell would.

And the guides write `<provider>` where the reader substitutes one, because the
generated inventories are provider-scoped (#277). A placeholder is expanded
against the supported providers and accepted when any expansion names a real
file, which keeps the check honest about the filename without requiring every
provider's lab to have been deployed in the checkout it runs in.

Usage:
    validate-doc-inventories.py [--repo-root PATH]
"""

from __future__ import annotations

import argparse
import re
import shlex
import subprocess
import sys
from fnmatch import fnmatch
from pathlib import Path

FENCE_RE = re.compile(r"^\s*```+\s*(?P<lang>[A-Za-z0-9_+-]*)")
SHELL_LANGS = {"bash", "sh", "shell", "zsh", "console"}

# A `<provider>` or `<experiment-name>` stands where the reader substitutes a
# value. Expanded to a glob rather than to a list of known providers, so the
# check does not carry a second copy of the provider list to drift against.
PLACEHOLDER_RE = re.compile(r"<[^>]+>")

# Commands that create the repository directory, so the `cd` that follows one
# enters the clone rather than a subdirectory of the checkout.
CLONE_RE = re.compile(r"\bgit\s+clone\b")


# Fixture trees are inputs to this check, not subjects of it. They contain
# deliberately broken commands, and their relative paths only resolve against
# their own root, so scanning them from the repository root reports findings
# that are the point of the fixture rather than defects in the documentation.
EXCLUDED_ROOTS = ("tests/",)


def tracked_markdown(repo_root: Path) -> list[str]:
    """Markdown files to scan, tracked ones by preference.

    `git ls-files` matches how every other lint target in this repository picks
    its inputs, so an untracked scratch document is not checked. A fixture is a
    bare directory rather than a repository, so fall back to walking it: the
    exclusion below is skipped in that case, because the fixture is then the
    root and its own documents are exactly what must be read.
    """
    try:
        out = subprocess.run(
            ["git", "ls-files", "*.md"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=True,
        )
        listed = [
            line
            for line in out.stdout.splitlines()
            if line and not line.startswith(EXCLUDED_ROOTS)
        ]
        if listed:
            return listed
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass
    return sorted(
        str(path.relative_to(repo_root))
        for path in repo_root.rglob("*.md")
        if path.is_file()
    )


def shell_blocks(lines: list[str]) -> list[tuple[int, list[str]]]:
    """Fenced shell blocks, as (1-indexed line number of the first line, lines).

    Only shell blocks are read. A yaml or hcl block that happens to contain the
    word `ansible-playbook` is prose about a command, not a command.
    """
    blocks: list[tuple[int, list[str]]] = []
    in_block = False
    start = 0
    body: list[str] = []
    for index, line in enumerate(lines):
        fence = FENCE_RE.match(line)
        if not fence:
            if in_block:
                body.append(line)
            continue
        if not in_block:
            in_block = True
            start = index + 2
            body = []
            keep = fence.group("lang").lower() in SHELL_LANGS
        else:
            in_block = False
            if keep:
                blocks.append((start, body))
    return blocks


def join_continuations(body: list[str]) -> list[tuple[int, str]]:
    """Fold trailing-backslash continuations into one logical line.

    The OpenNMS stack command in both guides is written across four lines. Read
    line by line, its `-i` and its playbook would land in different commands.
    Returns (offset of the first physical line, joined text).
    """
    joined: list[tuple[int, str]] = []
    buffer = ""
    offset = 0
    for index, raw in enumerate(body):
        if not buffer:
            offset = index
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            buffer += stripped[:-1] + " "
            continue
        buffer += stripped
        joined.append((offset, buffer))
        buffer = ""
    if buffer:
        joined.append((offset, buffer))
    return joined


def inventory_args(command: str) -> list[str]:
    """The -i / --inventory values of an ansible-playbook command, if it is one.

    Returns an empty list for anything else, including a command that merely
    mentions ansible-playbook in a comment.
    """
    try:
        tokens = shlex.split(command, comments=True)
    except ValueError:
        # An unbalanced quote is prose, not a command this check can read.
        return []
    if not tokens or "ansible-playbook" not in tokens:
        return []
    # Only the first ansible-playbook in a `&&` chain is read from here; the
    # segmenting below hands us one command at a time.
    values: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in ("-i", "--inventory", "--inventory-file"):
            if index + 1 < len(tokens):
                values.append(tokens[index + 1])
            index += 2
            continue
        for prefix in ("--inventory=", "--inventory-file="):
            if token.startswith(prefix):
                values.append(token[len(prefix):])
        index += 1
    return values


def segments(line: str) -> list[str]:
    """Split a logical line on `&&`, `;` and `||` into separate commands.

    `cd ../../bootstrap && ansible-playbook -i inventory site.yml` is two
    commands, and the first one changes where the second resolves its path.
    """
    return [part.strip() for part in re.split(r"&&|\|\||;", line) if part.strip()]


def generated_patterns(repo_root: Path) -> list[str]:
    """Basename globs the repository generates, read from `.gitignore`.

    The per-provider inventories are generated by Terraform and gitignored
    (#277), so they exist in a deployed checkout and never in continuous
    integration. Requiring them to exist would fail every run on the machine
    that most needs the check.

    Reading `.gitignore` rather than listing them here keeps the two in step,
    and it distinguishes exactly the right way: `ansible-inventory.*.yml` is
    ignored because the repository produces it, while `inventory` and
    `opennms-lab-inventory.yml` are not ignored, are not produced, and are
    simply names that no longer refer to anything.
    """
    path = repo_root / ".gitignore"
    if not path.is_file():
        return []
    patterns: list[str] = []
    for line in path.read_text().splitlines():
        entry = line.strip()
        if not entry or entry.startswith("#") or entry.startswith("!"):
            continue
        patterns.append(entry.rstrip("/").rsplit("/", 1)[-1])
    return patterns


def resolve(
    cwd: Path, value: str, repo_root: Path, generated: list[str]
) -> tuple[bool, str]:
    """Does this inventory path exist, or is it one the repository generates?

    Returns (ok, the path as checked). A `-i` value ending in a comma is an
    inline host list, not a file, which is how ansible spells `-i localhost,`.
    """
    if value.endswith(","):
        return True, value

    globbed = PLACEHOLDER_RE.sub("*", value)
    target = (cwd / globbed).resolve()

    # An existing file, or an existing match for a placeholder path.
    if "*" in globbed:
        parent = (cwd / globbed).parent
        if parent.is_dir() and any(parent.glob(Path(globbed).name)):
            return True, str(target)
    elif target.exists():
        try:
            return True, str(target.relative_to(repo_root))
        except ValueError:
            return True, str(target)

    # Absent, but generated by the repository rather than missing from it.
    if any(fnmatch(Path(globbed).name, pattern) for pattern in generated):
        return True, str(target)

    try:
        return False, str(target.relative_to(repo_root))
    except ValueError:
        return False, str(target)


def check_file(
    path: Path, rel: str, repo_root: Path, generated: list[str]
) -> tuple[list[str], int]:
    """Findings for one document, and how many invocations it contained."""
    findings: list[str] = []
    seen = 0
    lines = path.read_text().splitlines()
    for start, body in shell_blocks(lines):
        # Each block is its own shell session, starting at the repository root.
        # That is what the guides now tell the reader, and treating a block as
        # continuing the previous one would make findings depend on reading
        # order rather than on the document.
        cwd = repo_root
        cloned = False
        for offset, logical in join_continuations(body):
            where = f"{rel}:{start + offset}"
            for command in segments(logical):
                if CLONE_RE.search(command):
                    cloned = True
                    continue
                tokens_cd = command.split()
                if tokens_cd and tokens_cd[0] == "cd" and len(tokens_cd) > 1:
                    if cloned:
                        # The reader started outside the repository and has just
                        # entered the fresh clone. That directory is this
                        # checkout, not a subdirectory of it.
                        cwd = repo_root
                        cloned = False
                    else:
                        cwd = (cwd / tokens_cd[1]).resolve()
                    continue
                for value in inventory_args(command):
                    seen += 1
                    ok, shown = resolve(cwd, value, repo_root, generated)
                    if not ok:
                        findings.append(
                            f"{where}: `-i {value}` resolves to {shown}, which does "
                            f"not exist. Ansible warns, matches no hosts, runs "
                            f"nothing and exits 0"
                        )
    return findings, seen


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root")
    args = parser.parse_args()
    repo_root = Path(args.repo_root).resolve()

    if not repo_root.is_dir():
        sys.stderr.write(f"error: {repo_root} is not a directory\n")
        return 2

    generated = generated_patterns(repo_root)
    findings: list[str] = []
    invocations = 0
    documents = 0
    for rel in tracked_markdown(repo_root):
        path = repo_root / rel
        if not path.is_file():
            continue
        documents += 1
        found, seen = check_file(path, rel, repo_root, generated)
        findings.extend(found)
        invocations += seen

    if findings:
        for finding in findings:
            sys.stderr.write(f"{finding}\n")
        sys.stderr.write(
            f"\n{len(findings)} documented command(s) name an inventory that does "
            f"not exist, across {documents} document(s)\n"
        )
        return 1

    if invocations == 0:
        # The mistake validate-renovate-pins.py made on its first attempt: a
        # check that reads nothing reports success. Finding no invocations at
        # all means the parsing broke or the documents moved, not that the
        # documentation is clean.
        sys.stderr.write(
            "error: no ansible-playbook invocations found in any tracked "
            "document. Either the guides stopped documenting one, or this check "
            "is no longer parsing them; both are worth failing over\n"
        )
        return 1

    print(
        f"{invocations} documented ansible-playbook invocation(s) name an "
        f"inventory that exists, across {documents} document(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
