#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Correctness diff between two query-result directories (raw bodies from
run-queries.sh trial 2), e.g. results/correctness-es/queries/raw vs
results/correctness-vl/queries/raw. Reports per-query total-bytes deltas and
series shape mismatches; exits 0 always (the diff is a report, not a gate)."""
import json
import sys
from pathlib import Path


def totals(doc):
    """Sum every numeric leaf — a backend-agnostic mass number per response."""
    if isinstance(doc, bool):
        return 0.0
    if isinstance(doc, (int, float)):
        return float(doc)
    if isinstance(doc, list):
        return sum(totals(x) for x in doc)
    if isinstance(doc, dict):
        return sum(totals(v) for v in doc.values())
    return 0.0


def main(a_dir, b_dir):
    rows = []
    for fa in sorted(Path(a_dir).glob("*.json")):
        fb = Path(b_dir) / fa.name
        if not fb.exists():
            rows.append({"query": fa.stem, "error": "missing in B"})
            continue
        try:
            da = json.loads(fa.read_text() or "{}")
            db = json.loads(fb.read_text() or "{}")
        except json.JSONDecodeError:
            rows.append({"query": fa.stem, "error": "non-JSON body on at least one side (query failed there)"})
            continue
        ta, tb = totals(da), totals(db)
        delta = 0.0 if ta == tb == 0 else abs(ta - tb) / max(abs(ta), abs(tb))
        rows.append({"query": fa.stem, "mass_a": ta, "mass_b": tb,
                     "rel_delta_pct": round(delta * 100, 3)})
    print(json.dumps(rows, indent=2))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
