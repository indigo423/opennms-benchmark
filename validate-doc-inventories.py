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

# A clone creates the repository directory, so a `cd` into it enters the clone
# rather than a subdirectory of the checkout. The captured group is the URL, so
# the directory name can be matched: consuming whatever `cd` came next would
# erase a `cd <clone>/bootstrap` and resolve its inventory one level too high,
# which is a false pass on exactly the shape this check exists for.
CLONE_RE = re.compile(r"\bgit\s+clone\b\s+(?:--\S+\s+)*(?P<url>\S+)")


# Trees that are not this repository's documentation. Fixtures are inputs to
# this check rather than subjects of it: they hold deliberately broken commands
# whose relative paths only resolve against their own root. `.ansible/` is the
# vendored collection closure, which documents its own commands and is not ours
# to fix.
#
# Applied to both listings below, not only the git one. The fallback walk sees
# every markdown file on disk, so without this a checkout with no git metadata
# scans the vendored closure and its own fixtures and fails with 4,970
# documents' worth of findings that say nothing about this repository.
EXCLUDED_ROOTS = ("tests/", ".ansible/")


def tracked_markdown(repo_root: Path) -> list[str]:
    """Markdown files to scan.

    `git ls-files` matches how every other lint target in this repository picks
    its inputs, so an untracked scratch document is not checked, and so the
    gitignored trees are never read.

    A fixture is a bare directory rather than a repository, so a root with no
    `.git` is walked instead. That also covers a source export or a container
    build context, neither of which carries git metadata.

    A root that *is* a repository and whose `git ls-files` fails is an error
    rather than a reason to walk. Walking a real checkout reads every ignored
    tree in it, which here is around five thousand markdown files belonging to
    tool caches and the vendored collection closure, and reports findings about
    documentation this repository does not own.
    """
    if (repo_root / ".git").exists():
        try:
            out = subprocess.run(
                ["git", "ls-files", "*.md"],
                cwd=repo_root,
                capture_output=True,
                text=True,
                check=True,
            )
        except (subprocess.CalledProcessError, FileNotFoundError) as error:
            raise SystemExit(
                f"error: {repo_root} is a git repository but `git ls-files` "
                f"failed ({error}). Refusing to fall back to walking it, which "
                f"would read every ignored tree in the checkout"
            ) from error
        return [
            line
            for line in out.stdout.splitlines()
            if line and not line.startswith(EXCLUDED_ROOTS)
        ]

    walked = (
        str(path.relative_to(repo_root))
        for path in repo_root.rglob("*.md")
        if path.is_file() and not any(part.startswith(".") for part in path.parts)
    )
    return sorted(rel for rel in walked if not rel.startswith(EXCLUDED_ROOTS))


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
    # A placeholder may contain spaces (`<your inventory file>`). shlex would
    # split it into `<your`, which then expands to a glob matching nothing and
    # reports a false failure with an unreadable message. Spaces inside a
    # placeholder are hidden from the splitter and restored after it.
    masked = PLACEHOLDER_RE.sub(lambda m: m.group(0).replace(" ", "\x00"), command)
    try:
        tokens = [token.replace("\x00", " ") for token in shlex.split(masked, comments=True)]
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
    """Split a logical line on `&&`, `;` and `||`, outside quotes only.

    `cd ../../bootstrap && ansible-playbook -i inventory site.yml` is two
    commands, and the first one changes where the second resolves its path.

    Quote state is tracked because a separator inside a quoted argument is not
    a separator. Splitting `-e 'note=a;b'` mid-quote leaves both halves
    unbalanced, `shlex` then raises, and the invocation is dropped with no
    finding recorded. A missing inventory in such a command would go unreported,
    which is the silent pass this check exists to prevent.
    """
    parts: list[str] = []
    current: list[str] = []
    quote: str | None = None
    index = 0
    while index < len(line):
        char = line[index]
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            index += 1
            continue
        if char in "'\"":
            quote = char
            current.append(char)
            index += 1
            continue
        pair = line[index : index + 2]
        if pair in ("&&", "||"):
            parts.append("".join(current))
            current = []
            index += 2
            continue
        if char == ";":
            parts.append("".join(current))
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    parts.append("".join(current))
    return [part.strip() for part in parts if part.strip()]


def generated_patterns(repo_root: Path) -> list[str]:
    """Ignore rules from `.gitignore`, kept as written.

    The per-provider inventories are generated by Terraform and gitignored
    (#277), so they exist in a deployed checkout and never in continuous
    integration. Requiring them to exist would fail every run on the machine
    that most needs the check.

    Reading `.gitignore` rather than listing the names here keeps the two in
    step. The entries are kept whole rather than reduced to basenames, because
    git anchors a pattern containing a slash to the directory the file sits in.
    Collapsing `terraform/kvm/inventory` to `inventory` would whitelist that
    bare name in every document and silently re-admit the bug this check
    exists for.
    """
    path = repo_root / ".gitignore"
    if not path.is_file():
        return []
    patterns: list[str] = []
    for line in path.read_text().splitlines():
        entry = line.strip()
        if not entry or entry.startswith("#") or entry.startswith("!"):
            continue
        patterns.append(entry.rstrip("/").lstrip("/"))
    return patterns


def is_generated(relative: str, patterns: list[str]) -> bool:
    """Would git ignore this path, by the rules in `.gitignore`?

    Git's two anchoring cases, and nothing else: a pattern containing a slash
    matches the path from the repository root, while a pattern without one
    matches a basename at any depth. An inventory that git ignores is one the
    repository generates, which is why its absence is not a defect.
    """
    name = relative.rsplit("/", 1)[-1]
    for pattern in patterns:
        if "/" in pattern:
            if fnmatch(relative, pattern):
                return True
        elif fnmatch(name, pattern):
            return True
    return False


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
    # Matched on the path relative to the repository root, so an ignore rule
    # anchored to one directory does not excuse the same bare name elsewhere.
    try:
        relative = str(target.relative_to(repo_root))
    except ValueError:
        relative = str(target)
    if is_generated(relative, generated):
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
        cloned: str | None = None
        for offset, logical in join_continuations(body):
            where = f"{rel}:{start + offset}"
            for command in segments(logical):
                clone = CLONE_RE.search(command)
                if clone:
                    cloned = clone.group("url").rstrip("/").rsplit("/", 1)[-1]
                    if cloned.endswith(".git"):
                        cloned = cloned[: -len(".git")]
                    continue
                tokens_cd = command.split()
                if tokens_cd and tokens_cd[0] == "cd" and len(tokens_cd) > 1:
                    destination = tokens_cd[1]
                    head, _, tail = destination.partition("/")
                    if cloned and head == cloned:
                        # The reader started outside the repository and has just
                        # entered the fresh clone. That directory is this
                        # checkout, so anything below it resolves from here.
                        cwd = (repo_root / tail).resolve() if tail else repo_root
                        cloned = None
                    else:
                        cwd = (cwd / destination).resolve()
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
