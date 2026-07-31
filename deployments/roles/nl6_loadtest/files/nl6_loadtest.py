#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Driver for nl6 load-test scenarios.
#
# Runs one bounded scenario end to end (submit, arm, start, wait, stop, report)
# and renders the sent-ledger as a self-contained HTML report plus a JSON
# sidecar.
#
# This is the *delivered* half of a delivered-vs-accepted reconciliation. nl6
# keeps an immutable sent-ledger, so what left the generator is a measured
# number rather than an assumed one. The accepted half is counted on the
# OpenNMS side; see the role README for why joining them is not yet automatic.
#
# Only one scenario runs at a time, fleet-wide, and nl6 keeps its state in
# memory. A restart loses every report that was not fetched.
import argparse
import html
import ipaddress
import json
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

# Categorical slot 1 of the validated reference palette. One series, so no
# legend: the title names it. Both modes pass the six checks. Do not substitute
# by eye; re-run scripts/validate_palette.js if this changes.
SERIES_LIGHT = "#2a78d6"
SERIES_DARK = "#3987e5"

# nl6 rejects a rate above this per device, so catching it here turns a 4xx
# from the far end into an argument error naming the limit.
MAX_RATE = 1000

# summary fields that make up the ledger identity, in the documented order.
LEDGER = ("in_window", "drain", "send_failures", "dropped", "suppressed_pre_window")

PROTOCOLS = ("syslog", "snmp-trap", "netflow5", "netflow9", "ipfix", "sflow", "gnmi-dialout")


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Run one nl6 load-test scenario and report its sent-ledger.",
        epilog="One scenario runs at a time, fleet-wide. nl6 state is in memory and does not survive a restart.",
    )
    p.add_argument("--url", required=True, help="nl6 base URL, e.g. http://192.0.2.144:8080")
    p.add_argument("--protocol", required=True, choices=PROTOCOLS)
    p.add_argument("--rate", type=int, required=True, help=f"events/second per device (1-{MAX_RATE})")
    p.add_argument("--window", required=True, help="measurement window as a Go duration, e.g. 30s, 5m")
    p.add_argument("--drain", default="2s", help="post-window grace period (default: 2s)")
    p.add_argument("--seed", type=int, default=42, help="pinned for reproducibility (default: 42)")
    p.add_argument("--start-ip", required=True, help="first simulated device address")
    p.add_argument("--count", type=int, required=True, help="number of consecutive devices from --start-ip")
    p.add_argument("--rate-profile", help='JSON, e.g. \'{"kind":"linear","start_rate":5,"end_rate":200}\'')
    p.add_argument("--abort-on", help="metric:threshold:grace, e.g. send_failures:100:5s")
    p.add_argument("--label", default="", help="run label recorded in the report")
    p.add_argument("--html", type=Path, default=Path("loadtest-report.html"))
    p.add_argument("--json", dest="json_out", type=Path, default=Path("loadtest-report.json"))
    args = p.parse_args(argv)
    if not 0 < args.rate <= MAX_RATE:
        p.error(f"--rate must be 1..{MAX_RATE} (nl6 limit), got {args.rate}")
    if args.count < 1:
        p.error("--count must be at least 1")
    return args


def api(url, path, method="GET", body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(  # noqa: S310 - operator-supplied lab URL
        f"{url.rstrip('/')}{path}",
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"nl6 {method} {path} failed: HTTP {e.code} {e.read().decode(errors='replace')[:400]}") from e
    except urllib.error.URLError as e:
        raise SystemExit(f"nl6 {method} {path} unreachable at {url}: {e.reason}") from e


def participants(start_ip, count):
    """Expand a start address and a count into consecutive addresses.

    The lab configures nl6 with -auto-start-ip and -auto-count, so deriving the
    participant list the same way keeps the driver in step with the fleet the
    role actually created, without querying an endpoint for it.
    """
    first = ipaddress.ip_address(start_ip)
    return [str(first + i) for i in range(count)]


def go_seconds(duration):
    """Parse the Go duration subset nl6 accepts, for the expected-count maths."""
    units = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}
    # An empty string would otherwise fall through the loop as 0.0, making the
    # expected-count maths silently produce nothing. "0s" stays legal.
    if not duration or not duration.strip():
        raise SystemExit("empty duration; use forms like 30s, 5m, 1h")
    total, number = 0.0, ""
    i = 0
    while i < len(duration):
        c = duration[i]
        if c.isdigit() or c == ".":
            number += c
            i += 1
            continue
        unit = duration[i : i + 2] if duration[i : i + 2] in units else c
        if unit not in units or not number:
            raise SystemExit(f"cannot parse duration {duration!r}; use forms like 30s, 5m, 1h")
        total += float(number) * units[unit]
        number = ""
        i += len(unit)
    if number:
        raise SystemExit(f"cannot parse duration {duration!r}; a unit is missing")
    return total


def run_scenario(args):
    body = {
        "participants": participants(args.start_ip, args.count),
        "protocol": args.protocol,
        "rate": args.rate,
        "window": args.window,
        "drain": args.drain,
        "seed": args.seed,
    }
    if args.rate_profile:
        body["rate_profile"] = json.loads(args.rate_profile)
    if args.abort_on:
        metric, threshold, grace = args.abort_on.split(":")
        body["abort_predicate"] = {"metric": metric, "threshold": int(threshold), "grace": grace}

    submitted = api(args.url, "/api/v1/scenarios", "POST", body)
    sid = submitted["id"]
    print(f"scenario  {sid}  config_sha256={submitted.get('config_sha256', '')[:16]}")

    armed = api(args.url, f"/api/v1/scenarios/{sid}/arm", "POST")
    n_armed = armed.get("participants_armed", 0)
    if not n_armed:
        raise SystemExit(f"no participants armed; excluded_by_reason={armed.get('excluded_by_reason')}")
    if armed.get("excluded_total"):
        print(f"WARNING   {armed['excluded_total']} excluded: {armed.get('excluded_by_reason')}", file=sys.stderr)
    print(f"armed     {n_armed} device(s)")

    api(args.url, f"/api/v1/scenarios/{sid}/start", "POST")
    window_s = go_seconds(args.window)
    drain_s = go_seconds(args.drain)
    print(f"running   {args.window} window + {args.drain} drain")
    time.sleep(window_s + drain_s + 1)

    # stop is idempotent and returns the finalized report, so it is safe even
    # when the window has already auto-closed.
    api(args.url, f"/api/v1/scenarios/{sid}/stop", "POST")
    return sid, api(args.url, f"/api/v1/scenarios/{sid}/report"), armed


def check_ledger(summary):
    """nl6 documents an invariant. Verify it rather than trust it.

    emitted = in_window + drain + send_failures + dropped + suppressed_pre_window
    """
    parts = {k: summary.get(k, 0) for k in LEDGER}
    total = sum(parts.values())
    emitted = summary.get("emitted", 0)
    return {"emitted": emitted, "sum_of_parts": total, "holds": total == emitted, "parts": parts}


def summarise(sid, report, armed, args):
    summary = report.get("summary", {})
    meta = summary.get("metadata", {})
    sent = summary.get("in_window", 0) + summary.get("drain", 0)
    window_s = go_seconds(args.window)
    n = summary.get("participants_armed", armed.get("participants_armed", 0))

    # A constant profile is deterministic: rate x window x devices. Any other
    # profile varies the rate over the window, so no closed form applies and
    # claiming one would be worse than reporting nothing.
    expected = None
    if not args.rate_profile:
        expected = int(args.rate * window_s * n)

    return {
        "scenario_id": sid,
        "label": args.label,
        "protocol": summary.get("protocol", args.protocol),
        "phase": summary.get("phase", "unknown"),
        "generated": datetime.now(UTC).isoformat(timespec="seconds"),
        "request": {
            "rate": args.rate,
            "window": args.window,
            "drain": args.drain,
            "seed": args.seed,
            "devices": n,
            "rate_profile": json.loads(args.rate_profile) if args.rate_profile else {"kind": "constant"},
        },
        "metadata": {
            "config_sha256": meta.get("config_sha256", ""),
            "nl6_version": meta.get("nl6_version", ""),
            "t0": meta.get("t0", ""),
            "t1": meta.get("t1", ""),
            "sub_window_duration": meta.get("sub_window_duration", ""),
        },
        "delivered": {
            "emitted": summary.get("emitted", 0),
            "sent": sent,
            "in_window": summary.get("in_window", 0),
            "drain": summary.get("drain", 0),
            "send_failures": summary.get("send_failures", 0),
            "dropped": summary.get("dropped", 0),
            "suppressed_pre_window": summary.get("suppressed_pre_window", 0),
            "expected": expected,
            "shortfall": None if expected is None else expected - sent,
        },
        "ledger_check": check_ledger(summary),
        "sub_windows": summary.get("sub_windows", []),
        "excluded_by_reason": summary.get("excluded_by_reason", {}),
        "participants": report.get("counters", []),
    }


def svg_chart(rep):
    """Bar chart of in-window sends per loss-localization bucket."""
    buckets = rep["sub_windows"]
    if not buckets:
        return '<p class="empty">No sub-window data — nothing to plot.</p>'

    w, h = 960, 260
    pad = {"l": 64, "r": 24, "t": 16, "b": 44}
    plot_w, plot_h = w - pad["l"] - pad["r"], h - pad["t"] - pad["b"]
    y_max = max(max(buckets), 1)

    # An even split of the expected total across buckets is the line a healthy
    # constant-rate run should sit on. Only meaningful without a rate profile.
    expected_per_bucket = None
    if rep["delivered"]["expected"] is not None and len(buckets):
        expected_per_bucket = rep["delivered"]["expected"] / len(buckets)
        y_max = max(y_max, expected_per_bucket)
    y_top = y_max * 1.15

    def y_of(v):
        return pad["t"] + plot_h - (v / y_top) * plot_h

    parts = []
    for i in range(5):
        v = y_top * i / 4
        y = y_of(v)
        parts.append(f'<line class="grid" x1="{pad["l"]}" y1="{y:.1f}" x2="{pad["l"] + plot_w}" y2="{y:.1f}"/>')
        parts.append(f'<text class="tick ty" x="{pad["l"] - 10}" y="{y + 4:.1f}">{v:,.0f}</text>')

    # 2px surface gap between adjacent bars; 4px rounded ends on the data end.
    slot = plot_w / len(buckets)
    bw = max(slot - 2, 1)
    for i, v in enumerate(buckets):
        x = pad["l"] + i * slot + 1
        y = y_of(v)
        bh = pad["t"] + plot_h - y
        parts.append(
            f'<rect class="bar" x="{x:.1f}" y="{y:.1f}" width="{bw:.1f}" height="{max(bh, 0):.1f}" rx="4">'
            f"<title>bucket {i + 1}: {v:,} sends</title></rect>"
        )
        parts.append(f'<text class="tick tx" x="{x + bw / 2:.1f}" y="{h - 22}">{i + 1}</text>')

    if expected_per_bucket is not None:
        y = y_of(expected_per_bucket)
        parts.append(f'<line class="expected" x1="{pad["l"]}" y1="{y:.1f}" x2="{pad["l"] + plot_w}" y2="{y:.1f}"/>')
        parts.append(f'<text class="expected-l" x="{pad["l"] + 6}" y="{y - 6:.1f}">expected</text>')

    parts.append(f'<text class="axis-l" x="{pad["l"] + plot_w / 2:.1f}" y="{h - 4}">loss-localization bucket</text>')
    return (
        f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="In-window sends per loss-localization bucket" '
        f'preserveAspectRatio="xMidYMid meet"><title>In-window sends per loss-localization bucket</title>'
        f'{"".join(parts)}'
        f'<line class="axis" x1="{pad["l"]}" y1="{pad["t"] + plot_h}"'
        f' x2="{pad["l"] + plot_w}" y2="{pad["t"] + plot_h}"/>'
        f"</svg>"
    )


TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>nl6 load test — {label}</title>
<style>
  .viz-root {{
    color-scheme: light;
    --surface-1: #fcfcfb; --surface-2: #f3f3f1; --border: #d9d8d4;
    --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #7a7974;
    --series: {c_light};
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) .viz-root {{
      color-scheme: dark;
      --surface-1: #1a1a19; --surface-2: #242423; --border: #3a3a38;
      --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #94938b;
      --series: {c_dark};
    }}
  }}
  :root[data-theme="dark"] .viz-root {{
    color-scheme: dark;
    --surface-1: #1a1a19; --surface-2: #242423; --border: #3a3a38;
    --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #94938b;
    --series: {c_dark};
  }}
  body {{ margin: 0; background: var(--surface-1); }}
  .viz-root {{
    font: 15px/1.5 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    color: var(--text-primary); background: var(--surface-1);
    max-width: 1040px; margin: 0 auto; padding: 32px 24px 64px;
  }}
  h1 {{ font-size: 21px; margin: 0 0 4px; }}
  h2 {{ font-size: 15px; margin: 40px 0 12px; color: var(--text-secondary); font-weight: 600; }}
  .sub {{ color: var(--text-muted); font-size: 13px; margin: 0 0 32px; }}
  .tiles {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 2px; }}
  .tile {{ background: var(--surface-2); padding: 16px 18px; }}
  .tile .k {{ font-size: 12px; color: var(--text-secondary); text-transform: uppercase; letter-spacing: .04em; }}
  .tile .v {{ font-size: 28px; font-variant-numeric: tabular-nums; margin-top: 4px; }}
  .tile .u {{ font-size: 13px; color: var(--text-muted); }}
  figure {{ margin: 0; }}
  figcaption {{ color: var(--text-secondary); font-size: 13px; margin-bottom: 8px; }}
  svg {{ width: 100%; height: auto; display: block; }}
  .grid, .axis {{ stroke: var(--border); stroke-width: 1; }}
  .bar {{ fill: var(--series); }}
  .expected {{ stroke: var(--text-muted); stroke-width: 2; stroke-dasharray: 4 4; }}
  .expected-l {{ fill: var(--text-muted); font-size: 11px; }}
  .tick {{ fill: var(--text-muted); font-size: 11px; font-variant-numeric: tabular-nums; }}
  .ty {{ text-anchor: end; }} .tx {{ text-anchor: middle; }}
  .axis-l {{ fill: var(--text-muted); font-size: 11px; text-anchor: middle; }}
  table {{ border-collapse: collapse; width: 100%; font-size: 13px; font-variant-numeric: tabular-nums; }}
  th, td {{ text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--border); }}
  th:first-child, td:first-child {{ text-align: left; }}
  th {{ color: var(--text-secondary); font-weight: 600; }}
  details {{ margin-top: 12px; }} summary {{ cursor: pointer; color: var(--text-secondary); font-size: 13px; }}
  .warn {{ background: var(--surface-2); border-left: 3px solid var(--series);
           padding: 12px 16px; margin: 24px 0; font-size: 13px; }}
  .empty {{ color: var(--text-muted); padding: 48px 0; text-align: center; }}
  code {{ font-size: 12px; }}
</style></head>
<body><div class="viz-root">
<h1>nl6 load test{label_suffix}</h1>
<p class="sub">{scenario} · {protocol} · {devices} device(s) × {rate}/s for {window} · phase <strong>{phase}</strong>
 · nl6 {nl6_version} · generated {generated}</p>

<div class="tiles">
  <div class="tile"><div class="k">Sent</div>
    <div class="v">{sent}</div><div class="u">in-window + drain</div></div>
  <div class="tile"><div class="k">Expected</div>
    <div class="v">{expected}</div><div class="u">{expected_note}</div></div>
  <div class="tile"><div class="k">Send failures</div>
    <div class="v">{send_failures}</div><div class="u">resolve/encode/write</div></div>
  <div class="tile"><div class="k">Dropped</div>
    <div class="v">{dropped}</div><div class="u">never confirmed on wire</div></div>
</div>
{warnings}
<h2>Loss localization</h2>
<figure>
  <figcaption>In-window sends per bucket, each {sub_window} wide. Drain sends are excluded by definition.
  A shortfall concentrated in the late buckets points at the collector giving way under sustained load;
  one spread evenly points at the generator.</figcaption>
  {svg}
</figure>

<h2>Sent-ledger</h2>
<table>
  <tr><th>Bucket</th><th>Records</th></tr>
  <tr><td>In window <code>[T0, T1)</code></td><td>{in_window}</td></tr>
  <tr><td>Drain (post-T1 grace)</td><td>{drain}</td></tr>
  <tr><td>Send failures</td><td>{send_failures}</td></tr>
  <tr><td>Dropped</td><td>{dropped}</td></tr>
  <tr><td>Suppressed pre-window</td><td>{suppressed}</td></tr>
  <tr><td><strong>Emitted</strong></td><td><strong>{emitted}</strong></td></tr>
</table>
<p class="sub">Identity <code>emitted = in_window + drain + send_failures + dropped + suppressed_pre_window</code>
 {ledger_verdict}. <code>sent = in_window + drain</code> is the reconciliation denominator: compare it against
 what OpenNMS accepted, never against the requested rate.</p>

<details><summary>Reproducibility</summary><pre>config_sha256 {config_sha256}
seed          {seed}
nl6_version   {nl6_version}
t0            {t0}
t1            {t1}</pre></details>
<details><summary>Per-participant counters</summary><pre>{counters}</pre></details>
</div></body></html>
"""


def render_html(rep, svg):
    d = rep["delivered"]
    warn = []
    if not rep["ledger_check"]["holds"]:
        warn.append(
            f"nl6's own ledger identity does not hold: parts sum to "
            f"{rep['ledger_check']['sum_of_parts']:,} against emitted {rep['ledger_check']['emitted']:,}. "
            f"Treat every figure here as suspect."
        )
    if rep["phase"] == "aborted":
        warn.append("The scenario aborted on its predicate, so the window is short and the totals are partial.")
    if d["shortfall"]:
        warn.append(
            f"{d['shortfall']:,} fewer records were sent than a constant profile predicts. "
            f"That is the generator falling behind, before OpenNMS is even involved."
        )
    if rep["excluded_by_reason"]:
        warn.append(f"Participants excluded at arm time: {rep['excluded_by_reason']}.")
    warnings = f'<div class="warn"><strong>Read with care.</strong> {" ".join(warn)}</div>' if warn else ""

    counters = json.dumps(rep["participants"], indent=2) if rep["participants"] else "none returned"
    label = html.escape(rep["label"])
    return TEMPLATE.format(
        label=label or "run",
        label_suffix=f" — {label}" if label else "",
        scenario=html.escape(rep["scenario_id"]),
        protocol=html.escape(rep["protocol"]),
        phase=html.escape(rep["phase"]),
        devices=rep["request"]["devices"],
        rate=rep["request"]["rate"],
        window=html.escape(rep["request"]["window"]),
        generated=rep["generated"],
        nl6_version=html.escape(rep["metadata"]["nl6_version"] or "unknown"),
        sent=f"{d['sent']:,}",
        expected="n/a" if d["expected"] is None else f"{d['expected']:,}",
        expected_note="rate × window × devices" if d["expected"] is not None else "no closed form under a rate profile",
        send_failures=f"{d['send_failures']:,}",
        dropped=f"{d['dropped']:,}",
        in_window=f"{d['in_window']:,}",
        drain=f"{d['drain']:,}",
        suppressed=f"{d['suppressed_pre_window']:,}",
        emitted=f"{d['emitted']:,}",
        ledger_verdict="holds" if rep["ledger_check"]["holds"] else "<strong>does not hold</strong>",
        sub_window=html.escape(rep["metadata"]["sub_window_duration"] or "?"),
        config_sha256=html.escape(rep["metadata"]["config_sha256"] or "?"),
        seed=rep["request"]["seed"],
        t0=html.escape(rep["metadata"]["t0"] or "?"),
        t1=html.escape(rep["metadata"]["t1"] or "?"),
        warnings=warnings,
        svg=svg,
        counters=html.escape(counters),
        c_light=SERIES_LIGHT,
        c_dark=SERIES_DARK,
    )


def main(argv=None):
    args = parse_args(argv)
    sid, report, armed = run_scenario(args)
    rep = summarise(sid, report, armed, args)
    args.json_out.write_text(json.dumps(rep, indent=2))
    args.html.write_text(render_html(rep, svg_chart(rep)))

    d = rep["delivered"]
    print(f"sent      {d['sent']:,} (in_window {d['in_window']:,} + drain {d['drain']:,})")
    if d["expected"] is not None:
        print(f"expected  {d['expected']:,}  shortfall {d['shortfall']:,}")
    print(f"failures  {d['send_failures']:,} send_failures, {d['dropped']:,} dropped")
    print(f"report    {args.html}")

    if not rep["ledger_check"]["holds"]:
        print(f"ERROR     nl6 ledger identity does not hold: {rep['ledger_check']}", file=sys.stderr)
        return 2
    if d["send_failures"] or d["dropped"] or d["shortfall"]:
        print("WARNING   the generator did not deliver the full requested load", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
