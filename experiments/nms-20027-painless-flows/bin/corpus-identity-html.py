#!/usr/bin/env python3
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Render build/corpus-identity.json (+ the nl6 ledger it references) as a
# self-contained, human-readable HTML page in results/.
import html
import json
from datetime import UTC, datetime
from pathlib import Path

EXP = Path(__file__).resolve().parent.parent
ident = json.loads((EXP / "build" / "corpus-identity.json").read_text())

report_path = EXP / "build" / ident.get("seed_report", "")
summary = {}
if report_path.is_file():
    summary = json.loads(report_path.read_text()).get("summary", {})

t0 = datetime.fromtimestamp(ident["window_start_ms"] / 1000, tz=UTC)
t1 = datetime.fromtimestamp(ident["window_end_ms"] / 1000, tz=UTC)
dur = ident["window_end_ms"] - ident["window_start_ms"]
sent = summary.get("sent")
reconciled = sent == ident["doc_count"] if sent is not None else None

e = html.escape
rows = [
    ("Flow documents", f"{ident['doc_count']:,}"),
    ("Seeded window (UTC)", f"{t0:%Y-%m-%d %H:%M:%S} → {t1:%H:%M:%S} ({dur // 60000} min {dur % 60000 // 1000} s)"),
    ("Window (epoch ms)", f"{ident['window_start_ms']} – {ident['window_end_ms']}"),
    ("nl6 scenario", e(str(ident.get("scenario_id", "—")))),
    ("Ledger report", e(str(ident.get("seed_report", "—")))),
    ("Normalization", e(str(ident.get("normalization", "none")))),
]
if summary:
    rows += [
        ("Ledger: sent / in-window / drain",
         f"{summary.get('sent', 0):,} / {summary.get('in_window', 0):,} / {summary.get('drain', 0):,}"),
        ("Ledger: send failures / dropped",
         f"{summary.get('send_failures', 0):,} / {summary.get('dropped', 0):,}"),
        ("Participants armed", f"{summary.get('participants_armed', '—')}"),
        ("Protocol", e(str(summary.get("protocol", "—")))),
    ]

recon_html = ""
if reconciled is not None:
    cls, txt = ("ok", "✓ reconciled — ledger sent equals the Elasticsearch document count (zero loss)") \
        if reconciled else ("bad", "⚠ NOT reconciled — ledger and document count disagree")
    recon_html = f'<p class="recon {cls}">{txt}</p>'

page = f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Corpus identity — NMS-20027 painless-vs-drift benchmark</title>
<style>
  :root {{ color-scheme: light dark;
    --fg: #1a1a1a; --muted: #6b6b6b; --line: #dcdcdc; --bg: #ffffff; --ok: #1b7f3b; --bad: #b3261e; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --fg: #e8e8e8; --muted: #9a9a9a; --line: #3a3a3a; --bg: #121212; --ok: #6fce8f; --bad: #f2857c; }} }}
  body {{ font: 15px/1.5 system-ui, sans-serif; color: var(--fg); background: var(--bg);
         max-width: 46rem; margin: 3rem auto; padding: 0 1rem; }}
  h1 {{ font-size: 1.3rem; }} .sub {{ color: var(--muted); margin-top: -0.5rem; }}
  table {{ border-collapse: collapse; width: 100%; margin-top: 1rem; }}
  th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line);
            font-variant-numeric: tabular-nums; vertical-align: top; }}
  th {{ color: var(--muted); font-weight: 500; white-space: nowrap; width: 16rem; }}
  .recon {{ padding: 10px 12px; border-left: 3px solid; border-radius: 3px; }}
  .recon.ok {{ border-color: var(--ok); }} .recon.bad {{ border-color: var(--bad); }}
  footer {{ color: var(--muted); font-size: 12.5px; margin-top: 1.5rem; }}
</style></head><body>
<h1>Corpus identity</h1>
<p class="sub">NMS-20027 painless-vs-drift flow query benchmark — the fixture every trial run is gated against</p>
{recon_html}
<table><tbody>
{''.join(f'<tr><th>{e(k)}</th><td>{v}</td></tr>' for k, v in rows)}
</tbody></table>
<footer>Generated from <code>build/corpus-identity.json</code> and the nl6 ledger report.
This file is self-contained and safe to attach anywhere.</footer>
</body></html>
"""

dest = EXP / "results" / "corpus-identity.html"
dest.parent.mkdir(exist_ok=True)
dest.write_text(page)
print(f"written: {dest}")
