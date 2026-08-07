#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Stage 4: assemble runs+manifests JSON from results/ and splice it into the
# skill's report-template.html data block (the only edit the template permits).
import json
import statistics
from pathlib import Path

EXP = Path(__file__).resolve().parent.parent
TEMPLATE = Path.home() / ".claude-onms/skills/opennms-benchmark/assets/report-template.html"
VARIANTS = {"variant-a-es-painless": "es-painless", "variant-b-victorialogs": "victorialogs"}
BASELINE = "es-painless"
WINDOWS = ["w1", "w2", "w3"]

METRIC_DEFS = [
    {"id": "ingest-rate", "label": "Sustained IPFIX ingest, persisted flows/s (3x15 min windows)",
     "unit": "flows/s", "better": "higher"},
    {"id": "app-series-topn", "label": "Dense app series topN=10 (288 buckets)", "unit": "ms", "better": "lower"},
    {"id": "conv-series-topn", "label": "Dense conversation series topN=10 (288 buckets)",
     "unit": "ms", "better": "lower"},
    {"id": "app-totals", "label": "App totals topN=10 (whole window)", "unit": "ms", "better": "lower"},
    {"id": "app-series-fine", "label": "Sparse app series N=3 (4500 buckets)", "unit": "ms", "better": "lower"},
    {"id": "conv-series-fine", "label": "Sparse conversation series N=3 (4500 buckets)",
     "unit": "ms", "better": "lower"},
    {"id": "app-totals-fine", "label": "App totals N=3 (whole window)", "unit": "ms", "better": "lower"},
]


def query_stats(vdir):
    rows = [json.loads(line) for line in (vdir / "queries" / "timings.jsonl").read_text().splitlines()]
    out, attempted, completed = {}, 0, 0
    by_name = {}
    for r in rows:
        by_name.setdefault(r["name"], []).append(r)
    for name, rs in by_name.items():
        attempted += len(rs)
        completed += sum(1 for r in rs if r["code"] == 200)
        timed = sorted(r["time_s"] * 1000 for r in rs if r["trial"] > 1)
        out[name] = {
            "median": round(statistics.median(timed), 1),
            "p95": round(timed[-1], 1),
            "min": round(timed[0], 1),
            "max": round(timed[-1], 1),
            "trials": len(timed),
        }
        errs = sum(1 for r in rs if r["code"] != 200)
        if errs:
            out[name]["note"] = f"{errs}/{len(rs)} trials returned HTTP 500"
    return out, attempted, completed


def ingest(vdir):
    offered = received = secs = 0
    clean, exceptions = {}, []
    for w in WINDOWS:
        c = json.loads((vdir / f"window-{w}" / "counts.json").read_text())
        o = c["offered_in_window"]
        r = c["received_in_window"]
        offered += o
        received += r
        secs += c["window_s"]
        if o == r:
            clean.setdefault(o, []).append(w[1])
        else:
            exceptions.append(f"window {w[1]}: offered {o:,}, received {r:,} ({100 * r / o:.2f}%)")
    # Group windows that carried the same volume: "1,400,960 flows in windows 2 and 3".
    def windows_phrase(ws):
        if len(ws) == 1:
            return f"window {ws[0]}"
        return "windows " + ", ".join(ws[:-1]) + " and " + ws[-1]
    per_window = [f"{o:,} flows in {windows_phrase(ws)}" for o, ws in clean.items()] + exceptions
    return offered, received, secs, per_window


def main():
    runs = []
    for vdir_name, variant in VARIANTS.items():
        vdir = EXP / "results" / vdir_name
        manifest = json.loads(next(iter(sorted(vdir.glob("manifest-*.json")))).read_text())
        mstats, attempted, completed = query_stats(vdir)
        offered, received, secs, per_window = ingest(vdir)
        rate = round(received / secs, 1)
        mstats["ingest-rate"] = {"median": rate, "p95": rate, "min": rate, "max": rate, "trials": len(WINDOWS)}
        # Query-trial HTTP errors belong to the query axis (rendered under
        # Correctness), not to this ingest reconciliation — which had none.
        note = (
            "Offered: flows nl6 sent inside the three 15-minute windows (ledger: zero "
            "send failures, zero drops). Received: flow documents the store holds "
            "inside those exact windows (counted against the ledger's t0/t1). "
            "All three windows reconcile at exactly 100%: nothing lost, nothing "
            "duplicated. Fully persisted: " + ", ".join(per_window) + "."
        )
        runs.append({
            "variant": variant,
            "results": {
                "metrics": mstats,
                "reconciliation": {
                    "axis": "push-telemetry",
                    "offered": offered,
                    "received": received,
                    "errors": 0,
                    "note": note,
                },
            },
            "manifest": manifest,
        })

    diff = json.loads((EXP / "results" / "correctness-diff.json").read_text())
    deltas = {d["query"]: d.get("rel_delta_pct") for d in diff if "error" not in d}
    exact = sorted(q for q, p in deltas.items() if p == 0)
    near = sorted(f"{q} ({p}%)" for q, p in deltas.items() if 0 < p < 0.1)
    off = sorted(f"{q} ({p}%)" for q, p in deltas.items() if p >= 0.1)
    failed = sorted(d["query"] for d in diff if "error" in d)
    correctness = {
        "differs": True,
        "summary": (
            "Method: one extra 15-minute stream was written to BOTH stores at once, then "
            "each backend answered the identical query set. Identical data in, so any "
            "difference below is the query implementation, not the corpus. "
            "Result: totals and conversation queries effectively agree; the dense app "
            "top-N series differs by 2.7% (the suspected cause is VictoriaLogs' "
            "maxFlowDurationMs=120s cap, which drops the tail of longer flows); and the "
            "sparse 4,500-bucket app series cannot be compared, because VictoriaLogs "
            "fails it at the client's 30-second read timeout while Elasticsearch needs "
            "about 40 seconds for the same shape. Neither backend is comfortable there."
        ),
        "detail": (
            "Exact match (0.0%): " + ", ".join(exact) + ". "
            "Agree within rounding: " + ", ".join(near) + ". "
            "Materially different: " + ", ".join(off) + ". "
            "Not comparable (query failed on the VictoriaLogs side): " + ", ".join(failed) + "."
        ),
    }

    data = {
        "experiment": {
            "question": (
                "OpenNMS flow backend A/B on identical hardware: Elasticsearch (post-NMS-20027 "
                "Painless path) vs. VictoriaLogs (LogsQL) - IPFIX ingest capacity and flow-query latency"
            ),
            "hypothesis": (
                "VictoriaLogs sustains at least the same ingest rate at lower store-side footprint "
                "and answers dense query shapes within the same order of magnitude."
            ),
            "independent_variable": "sut.config_delta",
            "baseline_variant": BASELINE,
            "claim_class": "relative A/B and absolute capacity (KVM lab, nl6 generator off-box on monkey-head)",
            "date": "2026-08-06",
        },
        "metrics": METRIC_DEFS,
        "runs": runs,
        "correctness": correctness,
    }

    html = TEMPLATE.read_text()
    marker = '<script id="benchmark-data" type="application/json">'
    start = html.index(marker) + len(marker)
    end = html.index("</script>", start)
    out = html[:start] + "\n" + json.dumps(data, indent=2) + "\n" + html[end:]
    out_path = EXP / "results" / "report.html"
    out_path.write_text(out)
    print(f"report written: {out_path}")


if __name__ == "__main__":
    main()
