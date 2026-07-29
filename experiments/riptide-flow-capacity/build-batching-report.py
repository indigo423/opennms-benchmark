#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
"""Assemble batching-runs.json and splice it into the self-contained A/B report."""
import json
import pathlib

HERE = pathlib.Path(__file__).parent
TEMPLATE = pathlib.Path.home() / ".claude-indigo/skills/opennms-benchmark/assets/report-template.html"

SECS = {"4m": 240, "10m": 600}


def steps(path):
    p = HERE / path
    return [json.loads(line) for line in p.read_text().splitlines()] if p.exists() else []


def rate(rec, field):
    return rec[field] / SECS[rec["window"]]


ladder = {v: steps(f"batching-runs/steps-{v}.jsonl") for v in ("batch_off", "batch_on")}
confirm = {v: steps(f"batching-confirm/steps-{v}.jsonl") for v in ("batch_off", "batch_on")}

COMMON_SUT = {
    "version_identity": {
        "version": "0.6.7-SNAPSHOT",
        "git_sha": "82b7a041e7ff4d4591bcfc21247bb210270690a8",
        "branch": "feat/382-batch-clickhouse-inserts",
        "image": "riptide:pr382-amd64",
        "image_id": "sha256:0efc35efa0f02c029a2bd5f4d4f7ca85af135bc7f2f92e24f7292bb2e1eb75b6",
    },
    "jvm": {"heap": "container default", "gc": "container default", "java": "OpenJDK 25.0.3 LTS"},
    "db_version": "ClickHouse 26.7.1.1315",
    "tss_backend": "clickhouse",
    "provisioner": "kvm/ansible (clickhouse-riptide), container run manually per variant",
}
COMMON_HOST = {
    "cpu": "Intel i9-10880H host-passthrough, 4 vCPU",
    "ram_gb": 7,
    "disk": "qcow2/nvme",
    "generator_colocated": False,
    "net_core_rmem_max": 134217728,
    "hygiene_notes": (
        "CPU governor not pinned (KVM guest); nl6 daemon shared with an idle foreign"
        " 5-device fleet targeting 192.168.11.87"
    ),
}
COMMON_WORKLOAD = {
    "axis": "push-telemetry",
    "generator_scenario": (
        "nl6 ipfix fidelity loadtest; ladder by exporter count (rate=1 export/s/device),"
        " 4m steps + 10m confirm"
    ),
    "generator_version": "nl6 v0.20.1",
    "parameters": {
        "protocol": "ipfix",
        "flow_model": (
            "~7.9 flows/s per simulated exporter (ConcurrentFlows profile); nl6 'rate' sets"
            " export cadence only, so offered load scales with exporter count"
        ),
        "seed": 7,
    },
    "fixtures": [
        {
            "name": "riptide-image",
            "identity": "sha256:0efc35ef… built from 82b7a04 (make oci, cross-built linux/amd64)",
        },
        {
            "name": "nl6-fleet",
            "identity": "2000 auto exporters on 10.42.1.0–10.42.9.x, /16, ipfix -> 192.168.11.33:9999",
        },
    ],
}


def variant_run(variant, label, cfg_delta):
    lad = ladder[variant]
    con = confirm[variant][0] if confirm[variant] else None
    clean = [s for s in lad if (s["loss_pct"] or 0) == 0]
    best_clean = max((rate(s, "sent") for s in clean), default=0)
    return {
        "variant": label,
        "results": {
            "metrics": {
                "sustained_rows_s": {
                    "median": round(rate(con, "persisted")) if con else None,
                    "trials": 1,
                    "note": "10-minute confirmed steady window, persisted rows/s",
                },
                "max_clean_offered_s": {
                    "median": round(best_clean),
                    "trials": 1,
                    "note": "highest 4-minute ladder step with zero loss",
                },
                "inserts_per_s": {"median": round(rate(con, "inserts"), 2) if con else None, "trials": 1},
                "rows_per_insert": {
                    "median": (
                        round(con["written_rows"] / con["inserts"])
                        if con and con["inserts"] and con["written_rows"]
                        else 1
                    ),
                    "trials": 1,
                    "note": (
                        "async_insert acknowledges before the write, so query_log written_rows"
                        " is 0 for batch-off; 1 row per insert by construction"
                    ),
                },
                "new_parts_per_s": {"median": round(rate(con, "parts_flows"), 2) if con else None, "trials": 1},
            },
            "reconciliation": {
                "axis": "push-telemetry",
                "attempted": con["sent"] if con else 0,
                "completed": con["persisted"] if con else 0,
                "errors": (con["sent"] - con["persisted"]) if con else 0,
                "note": (
                    f"10-min confirm: nl6 in_window {con['sent']:,} vs ClickHouse row delta {con['persisted']:,}"
                    f" ({con['loss_pct']}% loss)" if con else "n/a"
                ),
            },
            "ladder": [
                [s["devices"], round(rate(s, "sent")), round(rate(s, "persisted")), s["loss_pct"],
                 round(rate(s, "inserts"), 2), round(rate(s, "parts_flows"), 2),
                 "clean" if (s["loss_pct"] or 0) == 0 else "lossy"]
                for s in lad
            ],
        },
        "manifest": {
            "experiment": {
                "question": (
                    "Does client-side ClickHouse insert batching raise riptide's sustained"
                    " flow-ingest ceiling, and is delivered == persisted preserved?"
                ),
                "independent_variable": "sut.config_delta",
                "variant": label,
                "plan": "see plan-batching.md",
            },
            "sut": dict(COMMON_SUT, config_delta=cfg_delta),
            "host": COMMON_HOST,
            "workload": COMMON_WORKLOAD,
            "run": {"date": "2026-07-28", "operator": "indigo", "trials": 1},
            "comparability_key": ["sut.version_identity", "sut.db_version", "host", "workload"],
        },
    }


data = {
    "experiment": {
        "question": (
            "Does client-side ClickHouse insert batching (riptide#382 / PR#387) raise the"
            " sustained flow-ingest ceiling above the ~3,600 flows/s of 0.6.6, and does it"
            " preserve delivered == persisted?"
        ),
        "hypothesis": (
            "The 0.6.6 ceiling is insert-cadence-bound, not CPU-bound: one blocking insert per"
            " flow record caps throughput at ~150 inserts/s x ~24 rows. Batching to 10k rows / 2s"
            " should collapse insert and part cadence and move the ceiling several-fold higher."
        ),
        "independent_variable": "sut.config_delta (riptide.clickhouse.batch.enabled)",
        "baseline_variant": "batch-off (per-record inserts + async_insert coalescing)",
        "claim_class": "absolute capacity (generator off-box on monkey-head) + relative A/B",
        "date": "2026-07-28",
    },
    "metrics": [
        {"id": "sustained_rows_s", "label": "Sustained persisted rate, 10-min confirmed window",
         "unit": "rows/s", "better": "higher"},
        {"id": "max_clean_offered_s", "label": "Highest zero-loss offered rate (4-min ladder step)",
         "unit": "flows/s", "better": "higher"},
        {"id": "inserts_per_s", "label": "ClickHouse INSERT statements per second",
         "unit": "inserts/s", "better": "lower"},
        {"id": "rows_per_insert", "label": "Rows carried per INSERT", "unit": "rows", "better": "higher"},
        {"id": "new_parts_per_s", "label": "NewPart cadence on the flows table", "unit": "parts/s", "better": "lower"},
    ],
    "runs": [
        variant_run("batch_off", "batch-off",
                    "riptide.clickhouse.batch.enabled=false (async-inserts derives true: pre-change per-record path)"),
        variant_run("batch_on", "batch-on",
                    "riptide.clickhouse.batch.enabled=true, max-rows=10000, max-latency=2s"
                    " (async-inserts derives false)"),
    ],
    "profiling": {
        "part_log_totals": {
            "batch_off": {"flows_parts": 9844, "avg_rows_per_part": 444},
            "batch_on": {"flows_parts": 1695, "avg_rows_per_part": 9817},
        },
        "measurement_limitations": [
            "riptide registers Dropwizard metrics but exports them nowhere (no reporter, no"
            " endpoint), so queue depth, batch-size histogram and drop/fail counters were NOT"
            " readable during the run; buffer behaviour is inferred from ClickHouse"
            " query_log/part_log and riptide's logs.",
            "Under batch-off, async_insert acknowledges before the server writes, so"
            " system.query_log written_rows is 0 for those INSERTs; rows-per-insert is 1 by"
            " construction (one insert per flow record).",
            "The 4-minute ladder step at 3,973 flows/s showed zero loss for batch-off, but the"
            " 10-minute confirm at 3,947 flows/s lost 7.04% — the short window hid mid-run"
            " degradation. Only the 10-minute confirmed figures are headlined.",
        ],
    },
}

(HERE / "batching-runs.json").write_text(json.dumps(data, indent=2) + "\n")

html = TEMPLATE.read_text()
DATA_TAG = '<script id="benchmark-data" type="application/json">'
start = html.index(DATA_TAG) + len(DATA_TAG)
end = html.index("</script>", start)
out = html[:start] + "\n" + json.dumps(data, indent=2) + "\n" + html[end:]
(HERE / "batching-report.html").write_text(out)
print("wrote batching-runs.json and batching-report.html")
for r in data["runs"]:
    m = r["results"]["metrics"]
    print(f"  {r['variant']:10s} sustained={m['sustained_rows_s']['median']} rows/s  "
          f"inserts/s={m['inserts_per_s']['median']}  parts/s={m['new_parts_per_s']['median']}")
