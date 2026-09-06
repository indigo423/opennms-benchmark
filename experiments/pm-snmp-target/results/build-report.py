#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Wrap the Artifact-published report fragment into a standalone HTML document.

The published version is a FRAGMENT: the artifact host supplies the
doctype/head/body skeleton and a CSS reset. A file opened straight from disk
gets neither, so headings and lists inherit the browser's default margins and
every gap in the layout doubles.

One source, two outputs, so the local copy cannot drift from the published one.

    ./build-report.py <fragment.html> <standalone.html>
"""
import sys

RESET = """<style>
  /* Minimal reset. The artifact host supplies one; a standalone file must not
     rely on that. */
  html { -webkit-text-size-adjust: 100%; }
  body { margin: 0; }
  h1, h2, h3, h4, p, figure, blockquote, dl, dd { margin: 0; }
  ul[class] { list-style: none; margin: 0; padding: 0; }
  img, svg { max-width: 100%; display: block; }
  table { border-collapse: collapse; }
</style>"""

DESC = ("What it takes to sustain 72 million SNMP metrics per hour in PoweredBy "
        "2026: measured infrastructure, workload, and the configuration "
        "changes required.")


def main(src: str, dst: str) -> None:
    with open(src, encoding="utf-8") as fh:
        s = fh.read()
    # Everything up to and including the last </style> belongs in <head>.
    cut = s.rindex("</style>") + len("</style>")
    head, body = s[:cut].strip(), s[cut:].strip()
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(
            f'<!DOCTYPE html>\n<html lang="en">\n<head>\n'
            f'<meta charset="utf-8">\n'
            f'<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            f'<meta name="description" content="{DESC}">\n'
            f'{RESET}\n{head}\n</head>\n<body>\n{body}\n</body>\n</html>\n'
        )
    print(f"wrote {dst}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
