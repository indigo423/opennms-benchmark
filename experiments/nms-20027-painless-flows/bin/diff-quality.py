#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Data-quality diff between the two variants' persisted trial responses:
# per-column (application/conversation) sums, per-bucket deviations, and
# WHERE differences sit (window-edge vs interior buckets — the NMS-20001 fix
# changes partial-interval attribution, so edge-concentration is the expected
# signature). Also checks within-variant determinism (trial-2 vs trial-3).
import json
import sys
from pathlib import Path

EXP = Path(__file__).resolve().parent.parent
RESULTS = EXP / (sys.argv[1] if len(sys.argv) > 1 else "results")
B, C = "variant-b-plugin", "variant-c-painless"


def body(variant, qid, trial=2):
    shape, name = qid.split("/")
    return json.loads((RESULTS / "benchmark" / variant / shape / name / f"trial-{trial}.body.json").read_text())


def num(x):
    """Coerce a series cell: numbers pass through, 'NaN'/null/other -> None."""
    return x if isinstance(x, (int, float)) else None


def series_diff(qid):
    b, c = body(B, qid), body(C, qid)
    det_b = body(B, qid, 2) == body(B, qid, 3)
    det_c = body(C, qid, 2) == body(C, qid, 3)
    def keyfn(col):
        return json.dumps(col, sort_keys=True)

    kb = {keyfn(col): i for i, col in enumerate(b["columns"])}
    kc = {keyfn(col): i for i, col in enumerate(c["columns"])}
    shared, only_b, only_c = sorted(kb.keys() & kc.keys()), kb.keys() - kc.keys(), kc.keys() - kb.keys()

    n = len(b["timestamps"])
    per_col, edge_hits, interior_hits, diff_buckets, total_buckets = [], 0, 0, 0, 0
    worst = (0.0, None, None)
    for k in shared:
        vb = [num(x) for x in b["values"][kb[k]]]
        vc = [num(x) for x in c["values"][kc[k]]]
        sb = sum(x for x in vb if x is not None)
        sc = sum(x for x in vc if x is not None)
        col_diffs = 0
        # strict=False keeps the existing truncate-to-shorter behaviour. The two
        # series come from the same query against two variants and should be the
        # same length; if they ever are not, the extra buckets are silently
        # dropped rather than reported. Made explicit here, not changed.
        for i, (x, y) in enumerate(zip(vb, vc, strict=False)):
            total_buckets += 1
            if x != y and not (x is None and y is None):
                if x is None or y is None:
                    x, y = x or 0.0, y or 0.0
                col_diffs += 1
                rel = abs(y - x) / abs(x) if x else float("inf")
                if rel > worst[0] and x:
                    worst = (rel, k, i)
                if i <= 1 or i >= n - 2:
                    edge_hits += 1
                else:
                    interior_hits += 1
        diff_buckets += col_diffs
        per_col.append({
            "column": json.loads(k), "sum_plugin": sb, "sum_painless": sc,
            "rel_delta_pct": round((sc - sb) / sb * 100, 4) if sb else None,
            "buckets_differing": col_diffs, "buckets": n,
        })
    return {
        "kind": "series", "query": qid,
        "deterministic_within_variant": {"plugin": det_b, "painless": det_c},
        "columns": {"shared": len(shared), "only_plugin": len(only_b), "only_painless": len(only_c)},
        "buckets": {
            "total_compared": total_buckets, "differing": diff_buckets,
            "identical_pct": round((1 - diff_buckets / total_buckets) * 100, 3) if total_buckets else None,
            "differing_at_window_edges": edge_hits, "differing_interior": interior_hits,
        },
        "worst_bucket_rel_diff_pct": round(worst[0] * 100, 4),
        "per_column": per_col,
    }


def totals_diff(qid):
    b, c = body(B, qid), body(C, qid)
    rows_b = {r[0]: r[1:] for r in b.get("rows", [])}
    rows_c = {r[0]: r[1:] for r in c.get("rows", [])}
    per_app = []
    for app in sorted(rows_b.keys() & rows_c.keys()):
        vb, vc = rows_b[app], rows_c[app]
        deltas = [round((y - x) / x * 100, 4) if isinstance(x, (int, float)) and x else None
                  for x, y in zip(vb, vc, strict=False)]  # see note in series_diff
        per_app.append({"app": app, "plugin": vb, "painless": vc, "rel_delta_pct": deltas})
    return {
        "kind": "totals", "query": qid, "headers": b.get("headers"),
        "apps": {"shared": len(rows_b.keys() & rows_c.keys()),
                 "only_plugin": sorted(rows_b.keys() - rows_c.keys()),
                 "only_painless": sorted(rows_c.keys() - rows_b.keys())},
        "per_app": per_app,
    }


# Independent implementation of the proportional-attribution semantics: each
# flow's bytes are distributed uniformly over [delta_switched, last_switched]
# and clipped to the window. This is the EXPECTED value a correct windowed
# query must return (its 100%), computed as an ES sum-script — a different
# code path from both the drift plugin and the PR's per-bucket scripted_metric.
TRIM_SCRIPT = (
    "if (doc['netflow.delta_switched'].size()==0 || "
    "doc['netflow.last_switched'].size()==0 || doc['netflow.bytes'].size()==0) return 0; "
    "long t0 = (long) params.t0; long t1 = (long) params.t1; "
    "long fs = doc['netflow.delta_switched'].value.toInstant().toEpochMilli(); "
    "long ls = doc['netflow.last_switched'].value.toInstant().toEpochMilli(); "
    "double b = (double) doc['netflow.bytes'].value; "
    "long s = fs > t0 ? fs : t0; long e = ls < t1 ? ls : t1; "
    "if (e < s) return 0; long dur = ls - fs; "
    "return dur <= 0 ? b : b * (e - s) / dur;"
)


def ground_truth():
    """Best-effort: per-app EXPECTED (proportionally trimmed) and raw upper-
    bound byte sums vs. what each variant's totals endpoint reported.
    Skipped when ES is down."""
    import urllib.request
    es = "http://localhost:9200"
    ident = json.loads((EXP / "build" / "corpus-identity.json").read_text())
    t0, t1 = ident["window_start_ms"], ident["window_end_ms"]
    q = json.dumps({
        "size": 0,
        "query": {"bool": {"filter": [
            {"range": {"netflow.delta_switched": {"lte": t1}}},
            {"range": {"netflow.last_switched": {"gte": t0}}},
            {"terms": {"netflow.direction": ["ingress", "egress"]}}]}},
        "aggs": {"apps": {
            "terms": {"field": "netflow.application", "size": 50,
                      "order": {"trimmed": "desc"}},
            "aggs": {
                "bytes": {"sum": {"field": "netflow.bytes"}},
                "trimmed": {"sum": {"script": {
                    "lang": "painless",
                    "params": {"t0": t0, "t1": t1},
                    "source": TRIM_SCRIPT}}}}}},
    }).encode()
    try:
        req = urllib.request.Request(f"{es}/netflow-*/_search", data=q,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=10) as r:
            aggs = json.load(r)["aggregations"]["apps"]["buckets"]
    except Exception as exc:
        print(f"ground truth skipped (ES not reachable: {exc})", file=sys.stderr)
        return None
    raw = {b["key"]: b["bytes"]["value"] for b in aggs}
    expected = {b["key"]: b["trimmed"]["value"] for b in aggs}
    rows_b = {r[0]: r[1] for r in body(B, "dense/app-totals").get("rows", [])}
    rows_c = {r[0]: r[1] for r in body(C, "dense/app-totals").get("rows", [])}
    shared = rows_b.keys() & rows_c.keys() & raw.keys()
    dropped = sorted((rows_b.keys() | rows_c.keys()) - shared)
    rows = []
    for app in sorted(shared, key=lambda a: -expected[a]):
        exp = expected[app]
        rows.append({"app": app, "expected_bytes": exp, "raw_bytes": raw[app],
                     "plugin_bytes": rows_b[app], "painless_bytes": rows_c[app],
                     "plugin_pct_of_expected": round(rows_b[app] / exp * 100, 1) if exp else None,
                     "painless_pct_of_expected": round(rows_c[app] / exp * 100, 1) if exp else None})
    return {"query": "dense/app-totals (Bytes In)", "window_ms": [t0, t1],
            "rows": rows, "apps_not_matched": dropped}


def main():
    out = []
    for shape_dir in sorted((RESULTS / "benchmark" / B).iterdir()):
        if not shape_dir.is_dir():
            continue
        for qdir in sorted(shape_dir.iterdir()):
            qid = f"{shape_dir.name}/{qdir.name}"
            probe = body(B, qid)
            out.append(series_diff(qid) if "values" in probe else totals_diff(qid))

    gt = ground_truth()
    dest = RESULTS / "elasticsearch" / "data-quality.json"
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps({"queries": out, "ground_truth": gt}, indent=2))

    print(f"written: {dest}\n")
    if gt:
        for r in gt["rows"]:
            print(f"ground truth {r['app']}: expected {r['expected_bytes']:,.0f} "
                  f"(raw {r['raw_bytes']:,.0f}) — plugin {r['plugin_pct_of_expected']}% / "
                  f"painless {r['painless_pct_of_expected']}% of expected")
        if gt["apps_not_matched"]:
            print(f"  (not matched against ES ground truth: {', '.join(gt['apps_not_matched'])})")
        print()
    for d in out:
        if d["kind"] == "series":
            bk = d["buckets"]
            print(f"{d['query']}: {d['columns']['shared']} shared columns "
                  f"(+{d['columns']['only_plugin']}/{d['columns']['only_painless']} unshared), "
                  f"{bk['identical_pct']}% of {bk['total_compared']} buckets identical, "
                  f"{bk['differing']} differ (edges: {bk['differing_at_window_edges']}, "
                  f"interior: {bk['differing_interior']}), worst bucket {d['worst_bucket_rel_diff_pct']}%, "
                  f"determinism plugin={d['deterministic_within_variant']['plugin']} "
                  f"painless={d['deterministic_within_variant']['painless']}")
            for col in d["per_column"]:
                print(f"    {col['column']}: {col['rel_delta_pct']}% total delta, "
                      f"{col['buckets_differing']}/{col['buckets']} buckets differ")
        else:
            print(f"{d['query']}: {d['apps']['shared']} shared apps "
                  f"(only-plugin: {d['apps']['only_plugin']}, only-painless: {d['apps']['only_painless']})")
            for a in d["per_app"]:
                print(f"    {a['app']}: rel deltas {a['rel_delta_pct']}%")


if __name__ == "__main__":
    main()
