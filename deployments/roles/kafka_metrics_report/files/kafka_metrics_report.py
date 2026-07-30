#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Batch consumer for the OpenNMS Kafka Producer metrics topic.
#
# Reads a bounded slice of the topic — from a start offset set to the end
# offsets captured when the run begins — counts numeric samples, and writes a
# self-contained HTML report plus a JSON sidecar.
#
# Bounded on purpose: --replay against a previous sidecar re-reads exactly the
# same offsets and produces exactly the same numbers, which a live tail cannot
# promise. Retention has to outlive the benchmark; the kfk-exclusive deployment
# sets 24 h for this.
#
# Two clocks are tracked and never conflated:
#   collection  CollectionSet.timestamp, when OpenNMS collected the sample
#   accepted    Kafka record timestamp, when the broker took the message
# They diverge exactly when the broker is the bottleneck, which is the thing a
# Kafka-exclusive benchmark most needs to see. Reporting only one would hide it.
import argparse
import html
import json
import math
import sys
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

# confluent_kafka and the generated bindings are imported where they are used,
# not at module scope, so the summarise/render half stays importable — and
# testable — on a machine with no Kafka client and no protoc output.

# Categorical slots 1 and 2 of the validated reference palette. Both modes pass
# the six checks (lightness band, chroma floor, CVD separation, normal-vision
# floor, contrast) — worst adjacent CVD dE 24.7 light / 26.8 dark. Do not
# substitute by eye; re-run scripts/validate_palette.js if these ever change.
SERIES = {
    "collection": {"light": "#2a78d6", "dark": "#3987e5", "label": "Collected"},
    "accepted": {"light": "#eb6834", "dark": "#d95926", "label": "Accepted by Kafka"},
}

# A dense timeline zero-fills gaps, which is what makes a stall visible as a
# trough rather than a straight line between two points. But the bucket keys
# come from message timestamps, and one bogus stamp (proto3 leaves an unset
# int64 at 0, i.e. 1970) would span half a century — ~170M buckets at 10s, which
# hangs the report after the whole topic has already been read. Past this many
# buckets the timeline falls back to observed keys only and says so.
MAX_DENSE_BUCKETS = 20_000


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Count OpenNMS metric samples on a Kafka topic and render a report.",
        epilog="Reads a bounded slice and exits; it never tails.",
    )
    p.add_argument("--bootstrap", required=True, help="Kafka bootstrap servers, host:port")
    p.add_argument("--topic", default="metrics", help="metric topic (default: metrics)")
    p.add_argument("--group", default="kafka-metrics-report", help="consumer group id")
    p.add_argument("--bucket-seconds", type=int, default=10, help="timeline bucket width (default: 10)")
    p.add_argument("--timeout", type=float, default=30.0, help="seconds to wait for a poll before giving up")
    p.add_argument("--label", default="", help="run label recorded in the report")
    p.add_argument("--start-offsets", type=Path, help="JSON of {partition: offset} to start from")
    p.add_argument(
        "--replay",
        type=Path,
        help="a previous JSON sidecar; re-reads its exact start and end offsets, reproducing that report",
    )
    p.add_argument("--html", type=Path, default=Path("metrics-report.html"), help="HTML report path")
    p.add_argument("--json", dest="json_out", type=Path, default=Path("metrics-report.json"), help="JSON sidecar path")
    return p.parse_args(argv)


def bounded_slice(consumer, topic, start_offsets=None, replay_bounds=None):
    """Assign every partition and return the (start, end) offsets the run covers.

    With --replay the bounds come from a previous report, so the same command
    reads the same records. Otherwise end offsets are the high watermark
    captured once, up front: anything produced after this point belongs to the
    next report, not this one.
    """
    from confluent_kafka import TopicPartition

    meta = consumer.list_topics(topic, timeout=10)
    if topic not in meta.topics or meta.topics[topic].error:
        raise SystemExit(f"topic {topic!r} not found on the broker")
    partitions = sorted(meta.topics[topic].partitions)
    if not partitions:
        raise SystemExit(f"topic {topic!r} has no partitions")

    assignment, bounds = [], {}
    for part in partitions:
        low, high = consumer.get_watermark_offsets(TopicPartition(topic, part), timeout=10, cached=False)
        if replay_bounds and str(part) in replay_bounds:
            prev = replay_bounds[str(part)]
            start, end = max(int(prev["start"]), low), int(prev["end"])
        else:
            start = int(start_offsets.get(str(part), low)) if start_offsets else low
            start, end = max(start, low), high
        assignment.append(TopicPartition(topic, part, start))
        bounds[part] = {"start": start, "end": end}
    consumer.assign(assignment)
    return bounds


def consume(consumer, topic, bounds, timeout):
    """Read each partition up to its captured end offset, then stop.

    The bound is enforced per record, not merely tracked: a partition that
    drains early keeps receiving newly produced messages while its siblings are
    still catching up, and counting those would make the totals disagree with
    the offsets the report prints.
    """
    import collectionset_pb2
    from confluent_kafka import TIMESTAMP_NOT_AVAILABLE, KafkaException, TopicPartition

    remaining = {p for p, b in bounds.items() if b["end"] > b["start"]}
    samples, records, resources_total = [], 0, 0
    errors = Counter()

    while remaining:
        msg = consumer.poll(timeout)
        if msg is None:
            # Nothing left within the timeout. The bound is authoritative, so a
            # short read is a real finding, not a reason to keep waiting.
            errors["poll_timeout"] += 1
            break
        if msg.error():
            raise KafkaException(msg.error())

        part = msg.partition()
        # Produced after the bound was captured, or on a partition already
        # complete. Not part of this slice.
        if part not in remaining or msg.offset() >= bounds[part]["end"]:
            continue

        records += 1
        ts_type, ts_ms = msg.timestamp()
        try:
            cs = collectionset_pb2.CollectionSet()
            cs.ParseFromString(msg.value())
        except Exception:  # noqa: BLE001 - a malformed record must not abort a run
            errors["undecodable"] += 1
        else:
            # A "metric" is one numeric attribute. Message count is not a proxy:
            # a CollectionSet carries many resources, each with many attributes,
            # and the producer may split one set across several messages.
            n = sum(len(r.numeric) for r in cs.resource)
            resources_total += len(cs.resource)
            if n:
                if ts_type == TIMESTAMP_NOT_AVAILABLE or ts_ms < 0:
                    # A broker with no record timestamp would otherwise put this
                    # sample in 1970 and wreck the accepted span silently.
                    errors["no_record_timestamp"] += 1
                elif cs.timestamp <= 0:
                    errors["no_collection_timestamp"] += 1
                else:
                    samples.append((cs.timestamp / 1000.0, ts_ms / 1000.0, n))

        if msg.offset() >= bounds[part]["end"] - 1:
            remaining.discard(part)
            consumer.pause([TopicPartition(topic, part)])

    return samples, records, resources_total, errors


def timeline(samples, index, width, errors=None):
    """Bucket sample counts into fixed-width bins on one of the two clocks.

    Keys come from the observed buckets. A dense zero-filled range is nicer to
    read, so it is used whenever the span is sane; see MAX_DENSE_BUCKETS.
    """
    if not samples:
        return []
    buckets = Counter()
    for row in samples:
        buckets[math.floor(row[index] / width) * width] += row[2]
    lo, hi = min(buckets), max(buckets)
    if (hi - lo) / width + 1 > MAX_DENSE_BUCKETS:
        if errors is not None:
            errors["sparse_timeline"] += 1
        keys = sorted(buckets)
    else:
        keys = range(int(lo), int(hi) + width, width)
    return [{"t": t, "rate": buckets.get(t, 0) / width} for t in keys]


def summarise(samples, records, resources_total, errors, args, bounds):
    total = sum(row[2] for row in samples)
    series = {
        name: timeline(samples, idx, args.bucket_seconds, errors)
        for name, idx in (("collection", 0), ("accepted", 1))
    }
    spans = {}
    for name, idx in (("collection", 0), ("accepted", 1)):
        stamps = [row[idx] for row in samples]
        spans[name] = (max(stamps) - min(stamps)) if stamps else 0.0

    # Average over the accepted-clock span: that is the rate the broker actually
    # sustained. Dividing by wall-clock or by the collection span would flatter
    # a run whose tail arrived late. A slice too short to have a span yields no
    # rate at all rather than 0.0, which would read as a failed run.
    span = spans["accepted"]
    return {
        "label": args.label,
        "topic": args.topic,
        "generated": datetime.now(UTC).isoformat(timespec="seconds"),
        "bucket_seconds": args.bucket_seconds,
        "totals": {
            "samples": total,
            "records": records,
            "resources": resources_total,
            "samples_per_record": round(total / records, 2) if records else 0,
        },
        "rate": {
            "mean_per_second": round(total / span, 2) if span > 0 else None,
            "peak_per_second": round(max((b["rate"] for b in series["accepted"]), default=0.0), 2),
            "span_seconds": round(span, 1),
            "collection_span_seconds": round(spans["collection"], 1),
        },
        "offsets": bounds,
        "warnings": dict(errors),
        "series": series,
    }


def svg_chart(report):
    """Static SVG line chart. Points are also emitted as JSON for the hover layer."""
    w, h = 960, 320
    # Right pad holds the direct labels; "Accepted by Kafka" at 12px needs it.
    pad = {"l": 64, "r": 132, "t": 16, "b": 40}
    plot_w, plot_h = w - pad["l"] - pad["r"], h - pad["t"] - pad["b"]
    series = report["series"]
    all_pts = [b for s in series.values() for b in s]
    if not all_pts:
        return '<p class="empty">No samples in this slice — nothing to plot.</p>', "[]"

    t0 = min(b["t"] for b in all_pts)
    t1 = max(b["t"] for b in all_pts)
    y_max = max(b["rate"] for b in all_pts) or 1.0
    y_top = y_max * 1.1

    def x_of(t):
        return pad["l"] + (0 if t1 == t0 else (t - t0) / (t1 - t0) * plot_w)

    def y_of(v):
        return pad["t"] + plot_h - (v / y_top) * plot_h

    parts, labels, hover = [], [], []
    # Recessive gridlines and y ticks first, so marks sit above them.
    for i in range(5):
        v = y_top * i / 4
        y = y_of(v)
        parts.append(f'<line class="grid" x1="{pad["l"]}" y1="{y:.1f}" x2="{pad["l"] + plot_w}" y2="{y:.1f}"/>')
        parts.append(f'<text class="tick ty" x="{pad["l"] - 10}" y="{y + 4:.1f}">{v:,.0f}</text>')
    for i in range(5):
        t = t0 + (t1 - t0) * i / 4
        x = x_of(t)
        stamp = datetime.fromtimestamp(t, UTC).strftime("%H:%M:%S")
        parts.append(f'<text class="tick tx" x="{x:.1f}" y="{h - 14}">{stamp}</text>')

    anchors = []
    for order, (name, points) in enumerate(series.items()):
        if not points:
            continue
        if len(points) == 1:
            # A polyline of one point draws nothing; a marker keeps a one-bucket
            # slice visible instead of rendering an empty plot.
            b = points[0]
            parts.append(f'<circle class="dot s-{name}" cx="{x_of(b["t"]):.1f}" cy="{y_of(b["rate"]):.1f}" r="5"/>')
        else:
            d = " ".join(f"{x_of(b['t']):.1f},{y_of(b['rate']):.1f}" for b in points)
            parts.append(f'<polyline class="line s-{name}" points="{d}"/>')
        last = points[-1]
        anchors.append([y_of(last["rate"]), order, x_of(last["t"]) + 10, name])
        hover.append({"name": name, "label": SERIES[name]["label"], "points": points})

    # Direct labels carry identity so it never rests on colour alone — but two
    # series ending at the same rate put them on the same pixel, which makes one
    # unreadable. Push them apart to a legible gap. Ties break on the series'
    # plot order, not on its name, so the label stack matches the legend.
    anchors.sort(key=lambda a: (a[0], a[1]))
    gap = 15
    for i in range(1, len(anchors)):
        anchors[i][0] = max(anchors[i][0], anchors[i - 1][0] + gap)
    overflow = anchors[-1][0] - (pad["t"] + plot_h) if anchors else 0
    if overflow > 0:
        # Never push the stack off the top of the plot; a squeezed label is
        # better than one rendered outside the frame.
        shift = min(overflow, max(0, anchors[0][0] - pad["t"]))
        for a in anchors:
            a[0] -= shift
    for y, _order, x, name in anchors:
        labels.append(f'<text class="direct s-{name}" x="{x:.1f}" y="{y + 4:.1f}">{SERIES[name]["label"]}</text>')

    axes = (
        f'<line class="axis" x1="{pad["l"]}" y1="{pad["t"]}" x2="{pad["l"]}" y2="{pad["t"] + plot_h}"/>'
        f'<line class="axis" x1="{pad["l"]}" y1="{pad["t"] + plot_h}"'
        f' x2="{pad["l"] + plot_w}" y2="{pad["t"] + plot_h}"/>'
    )
    svg = (
        f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Metric samples per second over time" '
        f'preserveAspectRatio="xMidYMid meet">'
        f"<title>Metric samples per second over time</title>"
        f'{"".join(parts)}{axes}{"".join(labels)}'
        f'<g id="crosshair" hidden><line class="cross" y1="{pad["t"]}" y2="{pad["t"] + plot_h}"/></g>'
        f'<rect id="hit" x="{pad["l"]}" y="{pad["t"]}" width="{plot_w}" height="{plot_h}" fill="transparent"/>'
        f"</svg>"
    )
    geom = {"x0": pad["l"], "x1": pad["l"] + plot_w, "t0": t0, "t1": t1, "series": hover}
    return svg, json.dumps(geom)


TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenNMS Kafka metrics — {label}</title>
<style>
  .viz-root {{
    color-scheme: light;
    --surface-1: #fcfcfb; --surface-2: #f3f3f1; --border: #d9d8d4;
    --text-primary: #0b0b0b; --text-secondary: #52514e; --text-muted: #7a7974;
    --s-collection: {c_light}; --s-accepted: {a_light};
  }}
  @media (prefers-color-scheme: dark) {{
    :root:where(:not([data-theme="light"])) .viz-root {{
      color-scheme: dark;
      --surface-1: #1a1a19; --surface-2: #242423; --border: #3a3a38;
      --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #94938b;
      --s-collection: {c_dark}; --s-accepted: {a_dark};
    }}
  }}
  :root[data-theme="dark"] .viz-root {{
    color-scheme: dark;
    --surface-1: #1a1a19; --surface-2: #242423; --border: #3a3a38;
    --text-primary: #ffffff; --text-secondary: #c3c2b7; --text-muted: #94938b;
    --s-collection: {c_dark}; --s-accepted: {a_dark};
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
  figure {{ margin: 0; position: relative; }}
  figcaption {{ color: var(--text-secondary); font-size: 13px; margin-bottom: 8px; }}
  svg {{ width: 100%; height: auto; display: block; overflow: visible; }}
  .grid {{ stroke: var(--border); stroke-width: 1; }}
  .axis {{ stroke: var(--border); stroke-width: 1; }}
  .cross {{ stroke: var(--text-muted); stroke-width: 1; stroke-dasharray: 3 3; }}
  .tick {{ fill: var(--text-muted); font-size: 11px; font-variant-numeric: tabular-nums; }}
  .ty {{ text-anchor: end; }} .tx {{ text-anchor: middle; }}
  .line {{ fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }}
  .direct {{ font-size: 12px; font-weight: 600; }}
  .s-collection {{ stroke: var(--s-collection); }}
  text.s-collection {{ fill: var(--s-collection); stroke: none; }}
  circle.s-collection {{ fill: var(--s-collection); stroke: none; }}
  .s-accepted {{ stroke: var(--s-accepted); }}
  text.s-accepted {{ fill: var(--s-accepted); stroke: none; }}
  circle.s-accepted {{ fill: var(--s-accepted); stroke: none; }}
  .legend {{ display: flex; gap: 20px; margin: 12px 0 0; font-size: 13px; color: var(--text-secondary); }}
  .legend i {{ display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; }}
  #tip {{
    position: absolute; pointer-events: none; background: var(--surface-2); color: var(--text-primary);
    border: 1px solid var(--border); padding: 8px 10px; font-size: 12px; border-radius: 4px;
    font-variant-numeric: tabular-nums; white-space: nowrap; display: none;
  }}
  table {{ border-collapse: collapse; width: 100%; font-size: 13px; font-variant-numeric: tabular-nums; }}
  th, td {{ text-align: right; padding: 6px 10px; border-bottom: 1px solid var(--border); }}
  th:first-child, td:first-child {{ text-align: left; }}
  th {{ color: var(--text-secondary); font-weight: 600; }}
  details {{ margin-top: 12px; }} summary {{ cursor: pointer; color: var(--text-secondary); font-size: 13px; }}
  .warn {{ background: var(--surface-2); border-left: 3px solid {a_light};
           padding: 12px 16px; margin: 24px 0; font-size: 13px; }}
  .empty {{ color: var(--text-muted); padding: 48px 0; text-align: center; }}
</style></head>
<body><div class="viz-root">
<h1>OpenNMS Kafka metrics{label_suffix}</h1>
<p class="sub">Topic <code>{topic}</code> · bounded read · {bucket}s buckets · generated {generated}</p>

<div class="tiles">
  <div class="tile"><div class="k">Metrics received</div>
    <div class="v">{samples}</div><div class="u">numeric samples</div></div>
  <div class="tile"><div class="k">Mean rate</div>
    <div class="v">{mean}</div><div class="u">samples/second</div></div>
  <div class="tile"><div class="k">Peak rate</div>
    <div class="v">{peak}</div><div class="u">samples/second</div></div>
  <div class="tile"><div class="k">Span</div>
    <div class="v">{span}</div><div class="u">seconds accepted</div></div>
</div>
{warnings}
<h2>Samples per second</h2>
<figure>
  <figcaption>Two clocks. <strong>Collected</strong> is when OpenNMS took the sample;
  <strong>Accepted by Kafka</strong> is when the broker stored it. They track each other
  while the broker keeps up, and separate when it does not.</figcaption>
  {svg}
  <div id="tip"></div>
</figure>
<div class="legend">
  <span><i style="background:var(--s-collection)"></i>Collected</span>
  <span><i style="background:var(--s-accepted)"></i>Accepted by Kafka</span>
</div>

<h2>Detail</h2>
<table>
  <tr><th>Measure</th><th>Value</th></tr>
  <tr><td>Numeric samples</td><td>{samples}</td></tr>
  <tr><td>Kafka records read</td><td>{records}</td></tr>
  <tr><td>Resources</td><td>{resources}</td></tr>
  <tr><td>Samples per record</td><td>{per_record}</td></tr>
  <tr><td>Mean samples/second</td><td>{mean}</td></tr>
  <tr><td>Peak samples/second</td><td>{peak}</td></tr>
  <tr><td>Accepted span (s)</td><td>{span}</td></tr>
  <tr><td>Collection span (s)</td><td>{cspan}</td></tr>
</table>
<details><summary>Timeline as a table</summary>{table}</details>
<details><summary>Partition offsets covered</summary><pre>{offsets}</pre></details>

<script type="application/json" id="geom">{geom}</script>
<script>
(function () {{
  var geom = JSON.parse(document.getElementById("geom").textContent);
  if (!geom.series || !geom.series.length) return;
  var svg = document.querySelector("svg"), tip = document.getElementById("tip");
  var fig = svg.closest("figure");
  var hit = document.getElementById("hit"), cross = document.getElementById("crosshair");
  var line = cross.querySelector("line");
  function fmt(t) {{ return new Date(t * 1000).toISOString().substr(11, 8); }}
  hit.addEventListener("mousemove", function (e) {{
    var box = svg.getBoundingClientRect(), vb = svg.viewBox.baseVal;
    var vx = (e.clientX - box.left) / box.width * vb.width;
    var frac = (vx - geom.x0) / (geom.x1 - geom.x0);
    var t = geom.t0 + frac * (geom.t1 - geom.t0);
    var rows = geom.series.map(function (s) {{
      var best = null, bd = Infinity;
      s.points.forEach(function (p) {{ var d = Math.abs(p.t - t); if (d < bd) {{ bd = d; best = p; }} }});
      return best ? "<div>" + s.label + ": <strong>" + best.rate.toFixed(1) + "</strong>/s</div>" : "";
    }});
    cross.removeAttribute("hidden");
    line.setAttribute("x1", vx); line.setAttribute("x2", vx);
    tip.innerHTML = "<div>" + fmt(t) + "</div>" + rows.join("");
    tip.style.display = "block";
    // Offsets are relative to <figure>, the tooltip's offset parent — the
    // figcaption sits between it and the svg, so the svg's rect is the wrong
    // origin for `top`.
    var org = fig.getBoundingClientRect();
    tip.style.left = Math.min(e.clientX - org.left + 14, org.width - 170) + "px";
    tip.style.top = (e.clientY - org.top - 10) + "px";
  }});
  hit.addEventListener("mouseleave", function () {{
    cross.setAttribute("hidden", ""); tip.style.display = "none";
  }});
}})();
</script>
</div></body></html>
"""

WARNING_TEXT = {
    "poll_timeout": "the read stopped before every partition reached its end offset",
    "undecodable": "records could not be parsed as a CollectionSet",
    "no_record_timestamp": "records carried no broker timestamp and were excluded",
    "no_collection_timestamp": "records carried no collection timestamp and were excluded",
    "sparse_timeline": "timestamps spanned an implausible range, so the timeline shows only observed buckets",
}


def render_html(report, svg, geom):
    warnings = ""
    if report["warnings"]:
        items = "; ".join(f"{v}× {WARNING_TEXT.get(k, k)}" for k, v in report["warnings"].items())
        warnings = (
            f'<div class="warn"><strong>Read is not clean.</strong> {items}. '
            f"Excluded records are absent from every figure above.</div>"
        )
    rows = "".join(
        f"<tr><td>{datetime.fromtimestamp(b['t'], UTC).strftime('%H:%M:%S')}</td><td>{b['rate']:,.1f}</td></tr>"
        for b in report["series"]["accepted"]
    )
    table = f"<table><tr><th>Time (UTC)</th><th>Accepted samples/s</th></tr>{rows}</table>"
    mean = report["rate"]["mean_per_second"]
    label = html.escape(report["label"])
    return TEMPLATE.format(
        label=label or "benchmark run",
        label_suffix=f" — {label}" if label else "",
        topic=html.escape(report["topic"]),
        bucket=report["bucket_seconds"],
        generated=report["generated"],
        samples=f"{report['totals']['samples']:,}",
        records=f"{report['totals']['records']:,}",
        resources=f"{report['totals']['resources']:,}",
        per_record=f"{report['totals']['samples_per_record']:,.2f}",
        # A slice too short to have a span has no rate; "n/a" says that, where
        # 0.0 would read as a run that collected nothing.
        mean="n/a" if mean is None else f"{mean:,.1f}",
        peak=f"{report['rate']['peak_per_second']:,.1f}",
        span=f"{report['rate']['span_seconds']:,.0f}",
        cspan=f"{report['rate']['collection_span_seconds']:,.1f}",
        warnings=warnings,
        svg=svg,
        table=table,
        offsets=json.dumps(report["offsets"], indent=2),
        geom=geom,
        c_light=SERIES["collection"]["light"],
        c_dark=SERIES["collection"]["dark"],
        a_light=SERIES["accepted"]["light"],
        a_dark=SERIES["accepted"]["dark"],
    )


def main(argv=None):
    from confluent_kafka import Consumer

    args = parse_args(argv)
    start_offsets = json.loads(args.start_offsets.read_text()) if args.start_offsets else None
    replay_bounds = json.loads(args.replay.read_text())["offsets"] if args.replay else None
    consumer = Consumer(
        {
            "bootstrap.servers": args.bootstrap,
            "group.id": args.group,
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
        }
    )
    try:
        bounds = bounded_slice(consumer, args.topic, start_offsets, replay_bounds)
        samples, records, resources, errors = consume(consumer, args.topic, bounds, args.timeout)
    finally:
        consumer.close()

    report = summarise(samples, records, resources, errors, args, bounds)
    svg, geom = svg_chart(report)
    args.json_out.write_text(json.dumps(report, indent=2))
    args.html.write_text(render_html(report, svg, geom))

    r = report["rate"]
    mean = "n/a" if r["mean_per_second"] is None else f"{r['mean_per_second']:,.2f}/s"
    print(f"samples   {report['totals']['samples']:,}")
    print(f"mean      {mean} over {r['span_seconds']:,.1f}s")
    print(f"peak      {r['peak_per_second']:,.2f}/s")
    print(f"report    {args.html}")
    if report["warnings"]:
        print(f"WARNING   read is not clean: {report['warnings']}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
