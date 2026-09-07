#!/usr/bin/env python3
"""Assert no two roles in one play define the same handler name.

Ansible keeps one handler per name for a play. The last definition loaded wins,
and notified handlers run in definition order, not notify order. So when two
roles in the same play both define `Reload systemd`, a notify from the first
role silently binds to the second role's handler, and the work runs in whatever
order the role list happens to produce.

That is #289. Five roles in the `Monitoring services` play defined that name
alongside their own `Restart <svc>`. The surviving definition was traefik's,
which sits last, so every other role restarted its service before systemd had
reloaded the changed unit. systemd restarts from the definition it currently
has loaded, so the service came back on the superseded unit and the play
reported success. It does not self-heal: the next run sees an unchanged
template and restarts nothing, so the stale definition survives until an
unrelated restart.

Nothing else in the repository can see this class of defect. ansible-lint has
no rule for it, yamllint sees one file at a time, and a role read on its own
looks correct. The bug is a property of the play, so the check has to be too:
correctness depends on which roles appear together, which is why traefik was
right by position, `kafka_ui` and `docker_ce` by being alone in their plays,
and `nl6` by spelling its handler differently. Add a role to a play and which
role is correct moves. That is how the `pyroscope` role acquired the bug when
it joined the monitoring play.

Only repository-local roles are considered. Collection roles are pinned by SHA
and their handlers are upstream's business, so a collision inside one is not
actionable here.

Usage:
    validate-handlers.py [--repo-root PATH]
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

ROLE_DIRS = ("bootstrap/roles", "deployments/roles", "experiments/roles")
PLAYBOOKS = ("bootstrap/preparation-playbook.yml", "opennms-playbook.yml")

# A play header, then every line up to the next one. Parsed with regex rather
# than a YAML load on purpose: the playbooks carry comments and Jinja that a
# round trip would drop, and this only needs the role list.
PLAY_RE = re.compile(
    r"- name: (?P<name>.+?)\n(?:.*?\n)*?  hosts: (?P<hosts>\S+)(?P<body>(?:\n(?!- name:).*)*)"
)
ROLE_RE = re.compile(r"^\s+-\s+(?:role:\s*)?([a-z0-9_.]+)\s*$", re.M)
HANDLER_RE = re.compile(r"^- name: (.+)$", re.M)


def handlers_of(repo_root: Path, role: str) -> list[str]:
    """Handler names a repository-local role defines, or [] for anything else.

    A dotted name is a collection role (indigo423.opennms.opennms_core), which
    is out of scope.
    """
    if "." in role:
        return []
    for base in ROLE_DIRS:
        path = repo_root / base / role / "handlers" / "main.yml"
        if path.is_file():
            return [name.strip() for name in HANDLER_RE.findall(path.read_text())]
    return []


def plays_of(repo_root: Path) -> list[tuple[str, str, list[str]]]:
    """Every play that applies roles, as (playbook, play name, role list)."""
    found = []
    for rel in PLAYBOOKS:
        path = repo_root / rel
        if not path.is_file():
            continue
        for match in PLAY_RE.finditer(path.read_text()):
            roles = ROLE_RE.findall(match.group("body"))
            if roles:
                found.append((rel, match.group("name"), roles))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root")
    args = parser.parse_args()
    repo_root = Path(args.repo_root).resolve()

    plays = plays_of(repo_root)
    if not plays:
        print(f"error: no plays with roles found under {repo_root}", file=sys.stderr)
        return 2

    collisions = 0
    for playbook, play, roles in plays:
        by_name: dict[str, list[str]] = defaultdict(list)
        for role in roles:
            for handler in handlers_of(repo_root, role):
                by_name[handler].append(role)
        for handler, owners in sorted(by_name.items()):
            if len(owners) > 1:
                collisions += 1
                print(
                    f"{playbook}: play '{play}' has {len(owners)} roles defining the "
                    f"handler '{handler}': {', '.join(owners)}",
                    file=sys.stderr,
                )
                print(
                    "  Ansible keeps one handler per name and runs notified handlers "
                    "in definition order, so a notify from one of these roles binds to "
                    "another role's handler. Give the handler a role-specific name, or "
                    "fold the work into the role's own restart handler (#289).",
                    file=sys.stderr,
                )

    if collisions:
        print(
            f"\n{collisions} handler-name collision(s) across {len(plays)} plays",
            file=sys.stderr,
        )
        return 1

    print(f"no handler-name collisions across {len(plays)} plays")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
