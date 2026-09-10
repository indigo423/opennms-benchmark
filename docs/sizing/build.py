#!/usr/bin/env python3
# Copyright 2026 The OpenNMS Group, Inc.
# SPDX-License-Identifier: AGPL-3.0-or-later
# Created by Ronny Trommer <ronny@opennms.com>
"""Build the standalone sizing document.

The house style is authored by the benchmark-report skill, which inlines it into
every rendered report. This wraps the body fragment in a vendored copy of it,
kept beside this script as house-style.css, and emits one file with no external
references, openable from file://.

Lifting the style from a rendered report at build time would be the better
design and was the original one. It cannot work here: every report carrying the
stylesheet lives under experiments/*/results/bundle/, which is gitignored, so
the build succeeded only on the machine that had rendered one. See the note at
STYLE_SHEET for why vendoring costs nothing in drift.

    python3 docs/sizing/build.py

Re-run it after editing sizing.body.html. Never edit the built HTML directly.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# ── ISO 80000-1 number formatting ────────────────────────────────────────────
# Vendored from the benchmark-report skill's render.py so this document formats
# quantities the same way every rendered report in this repository does.
THIN = "\u202f"  # narrow no-break space: ISO 80000-1's group separator, never breaks a line
_NUM = re.compile(r"(?<![\w.])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+\.\d+)(?!\d|\.\d|,\d)")
_PCT = re.compile(r"(\d)%")
_VERSION_BEFORE = re.compile(r"(?:\bv|version|PostgreSQL|Java|OpenJDK|JDK|Horizon|Meridian|Ubuntu|Debian|Proxmox|"
                             r"Kafka|Prometheus|Grafana|Python|Ansible|Terraform|nl6|sysstat|SNMP4J)\s*$", re.I)
_SKIP_TAGS = {"script", "style", "code", "pre", "kbd"}
_VOID = {"br", "hr", "img", "input", "meta", "link", "path", "line", "rect", "circle", "use"}


def iso_text(text: str) -> str:
    """Groups of three split by a thin space, never a comma; the point stays as the decimal
    sign; a space before %. Versions, IPs and dates are left alone."""
    def one(m: re.Match) -> str:
        if _VERSION_BEFORE.search(text[: m.start()]):
            return m.group(0)
        return m.group(1).replace(",", THIN)
    return _PCT.sub(lambda m: m.group(1) + THIN + "%", _NUM.sub(one, text))


def iso_numbers(html: str) -> str:
    """Apply iso_text to every text node outside code, pre, kbd, script and style. Those carry
    literals (config values, shell, JavaScript) that must stay byte-exact; they are written in
    ISO form by hand in the source instead."""
    parts = re.split(r"(<[^>]+>)", html)
    stack: list[str] = []
    for i, part in enumerate(parts):
        if i % 2:
            m = re.match(r"<(/?)([A-Za-z][A-Za-z0-9-]*)", part)
            if not m:
                continue
            closing, name = m.group(1), m.group(2).lower()
            if closing:
                if name in stack:
                    del stack[len(stack) - 1 - stack[::-1].index(name):]
            elif not part.endswith("/>") and name not in _VOID:
                stack.append(name)
        elif part and not (_SKIP_TAGS & set(stack)):
            parts[i] = iso_text(part)
    return "".join(parts)

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BODY = HERE / "sizing.body.html"
OUT = HERE / "snmp-collector-sizing.html"

# The house stylesheet, vendored verbatim. It is 8 base64 @font-face rules and
# the design tokens, and it must be a TRACKED input: every rendered report that
# carries it lives under experiments/*/results/bundle/, which is gitignored, so
# lifting it from a report at build time works only on the machine that rendered
# one and fails in every clone.
#
# Vendoring does not introduce drift. This document's built HTML is committed
# with the stylesheet inlined, so the style is already frozen at render time;
# tracking the input as well only makes the build reproducible. Re-extract with:
#
#   python3 -c 'import re,pathlib as p; \
#     h=p.Path("<a rendered report>.html").read_text(); \
#     p.Path("docs/sizing/house-style.css").write_text( \
#       re.findall(r"<style>(.*?)</style>", h, re.S)[-1])'
#
# Extracted from campaigns/pm-snmp-sizing-rule/results/bundle/report.html,
# rendered 2026-09-07. Take the LAST <style> block: some reports open with a
# small print-only block, and the design tokens are in the last one.
STYLE_SHEET = HERE / "house-style.css"

TITLE = "Sizing a Collectd SNMP collector"
DESCRIPTION = (
    "How many threads, cores and gigabytes a Collectd SNMP collector needs for a "
    "given metric rate and collection duration, with the constants measured."
)

# The form controls are this document's own; everything else comes from the
# house stylesheet. Kept small and token-driven so it inherits light and dark.
EXTRA_CSS = """
  .calc-form {
    display: grid; gap: .9rem 1.4rem;
    grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
    background: var(--raised); border: 1px solid var(--line);
    border-radius: 3px; padding: 1.3rem var(--pad);
  }
  .calc-form label {
    display: flex; flex-direction: column; gap: .35rem;
    font-size: var(--step--1); color: var(--ink-2);
  }
  .calc-form label.wide { grid-column: 1 / -1; flex-direction: row; align-items: center; gap: .6rem; }
  .calc-form input[type=number] {
    font-family: "JetBrains Mono", monospace; font-size: .95rem;
    padding: .45rem .6rem; border-radius: 2px;
    border: 1px solid var(--line); background: var(--surface); color: var(--ink);
  }
  .calc-form input[type=number]:focus-visible,
  .calc-form input[type=checkbox]:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
  .calc-form input[type=checkbox] { accent-color: var(--accent); width: 1rem; height: 1rem; }
  #out { margin-top: 1.2rem; }
  #out dd { color: var(--accent-2); font-weight: 500; }
  /* ISO 80000-1: symbols for quantities are set in italic */
  var { font-style: italic; font-family: inherit; }
  pre var { font-family: inherit; }
  h3 { font-family: Archivo, sans-serif; font-size: var(--step-1); color: var(--ink); margin-top: .6rem; }
  @media print { .calc-form { break-inside: avoid; } }
"""

SKELETON = """<!DOCTYPE html>
<!-- Copyright 2026 The OpenNMS Group, Inc.
     SPDX-License-Identifier: AGPL-3.0-or-later
     Created by Ronny Trommer <ronny@opennms.com>
     GENERATED by docs/sizing/build.py from sizing.body.html. Do not edit. -->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="{description}">
<meta name="author" content="Ronny Trommer">
<title>{title}</title>
<style>
{css}
{extra}
</style>
</head>
<body>
{body}
</body>
</html>
"""


def main() -> int:
    for path in (BODY, STYLE_SHEET):
        if not path.exists():
            print(f"build: missing {path.relative_to(ROOT)}", file=sys.stderr)
            return 1

    css = STYLE_SHEET.read_text(encoding="utf-8")

    body = BODY.read_text(encoding="utf-8")
    # \b so <header> is not mistaken for <head>
    for tag in ("!doctype", "html", "head", "body"):
        if re.search(rf"<{tag}\b", body, re.I):
            print(f"build: {BODY.name} must be a fragment, found <{tag}>", file=sys.stderr)
            return 1

    page = SKELETON.format(
        description=DESCRIPTION, title=TITLE, css=css, extra=EXTRA_CSS, body=iso_numbers(body)
    )
    stray = re.findall(r"\d,\d{3}", re.sub(r"(?s)<(script|style|pre|code)\b.*?</\1>", "", page))
    if stray:
        print(f"build: comma-grouped numbers survived outside code/pre: {stray[:5]}", file=sys.stderr)
        return 1
    OUT.write_text(page, encoding="utf-8")
    kib = OUT.stat().st_size / 1024
    print(f"build: {OUT.relative_to(ROOT)}  {kib:.0f} KiB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
