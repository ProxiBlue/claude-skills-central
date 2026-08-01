#!/usr/bin/env python3
"""Regenerate ~/monitor/dashboard.html from the telemetry CSV/report files.

Static generator (no server, no daemon) — the weekly telemetry crons call it so
the file is current after each run. Open ~/monitor/dashboard.html in a browser.

Reads (all under ~/monitor/):
  usage-telemetry/metrics.csv   guard-fire + banned-phrase counts over time
  rule-evals/evals-*.txt         latest 8-eval pass/fail + run history
  fleet-inventory/fleet-*.txt    latest fleet snapshot -> per-project drift flags
  harness-watch/last-seen        newest upstream claude-code version seen

Self-contained HTML: inline CSS, light+dark, SVG marks computed here (no JS
charting lib, no external assets). Design follows the dataviz method — status
colours reserved + labelled, one teal accent for magnitude, recessive grid.
"""
from __future__ import annotations
import csv, glob, os, re, html, datetime
from pathlib import Path

MON = Path(os.path.expanduser("~/monitor"))
OUT = MON / "dashboard.html"

def _fleet_target():
    import json
    p = Path(os.path.expanduser("~/claude-skills-central/host/pin-decision.json"))
    try:
        d = json.loads(p.read_text())
        return d.get("fleet_target", "2.1.198"), d.get("set_on", "?")
    except Exception:
        return "2.1.198", "?"

FLEET_TARGET, PIN_SET_ON = _fleet_target()

def _in_scope():
    p = Path(os.path.expanduser("~/claude-skills-central/host/tooling-scope.txt"))
    if not p.exists():
        return None  # None = no filter (all in scope)
    names = set()
    for ln in p.read_text().splitlines():
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            names.add(ln)
    return names

SCOPE = _in_scope()

# ---- parse -------------------------------------------------------------------

def read_usage_rows():
    p = MON / "usage-telemetry" / "metrics.csv"
    if not p.exists():
        return []
    rows = []
    with p.open() as fh:
        for r in csv.DictReader(fh):
            # dedup identical stamps (same-minute reruns during testing)
            rows.append(r)
    # keep last row per stamp
    seen = {}
    for r in rows:
        seen[r["stamp"]] = r
    out = sorted(seen.values(), key=lambda r: r["stamp"])
    return out

def latest_evals():
    files = sorted(glob.glob(str(MON / "rule-evals" / "evals-*.txt")))
    if not files:
        return None
    txt = Path(files[-1]).read_text()
    harness = ""
    m = re.search(r"harness:\s*(.+)$", txt, re.M)
    if m:
        harness = m.group(1).strip()
    evals = []
    for m in re.finditer(r"^\s*(\d+)\s+(\S+)\s+(PASS|FAIL)\s+(.*)$", txt, re.M):
        evals.append((m.group(1), m.group(2), m.group(3), m.group(4).strip()))
    stamp = Path(files[-1]).stem.replace("evals-", "")
    return {"stamp": stamp, "harness": harness, "evals": evals,
            "npass": sum(1 for e in evals if e[2] == "PASS"),
            "n": len(evals), "runs": len(files)}

def latest_fleet():
    files = sorted(glob.glob(str(MON / "fleet-inventory" / "fleet-*.txt")))
    if not files:
        return None
    txt = Path(files[-1]).read_text()
    proj = {}
    cur = None
    for line in txt.splitlines():
        m = re.match(r"^=== (\S+) \| (\S+) \| (.+)$", line)
        if m:
            cur = m.group(1)
            proj[cur] = {"status": m.group(2), "flags": {}}
            continue
        if cur is None:
            continue
        for k in ("pin", "ver", "pipeline.md", "wires", "dangling",
                  "mcp-stub", "teams", "marker", "settings"):
            mm = re.search(rf"{re.escape(k)}=(\[[^\]]*\]|\S+)", line)
            if mm:
                proj[cur]["flags"][k] = mm.group(1)
    stamp = Path(files[-1]).stem.replace("fleet-", "")
    return {"stamp": stamp, "proj": proj}

def harness_seen():
    p = MON / "harness-watch" / "last-seen"
    return p.read_text().strip() if p.exists() else "?"

# ---- drift scoring -----------------------------------------------------------

def project_issues(name, flags):
    issues = []
    ver = flags.get("ver", "")
    if ver and FLEET_TARGET not in ver and ver != "[]":
        issues.append(f"pin {ver}")
    if flags.get("pipeline.md") == "YES-LEGACY":
        issues.append("legacy pipeline.md")
    if flags.get("dangling", "[]") not in ("[]", ""):
        issues.append("dangling ref")
    if flags.get("mcp-stub", "-") == "ZERO-BYTE-STUB":
        issues.append("0-byte mcp stub")
    if flags.get("marker") == "HAS-MARKER(bad)":
        issues.append("ddev marker")
    if flags.get("settings") == "STALE-MOUNT":
        issues.append("stale settings")
    return issues

# ---- svg helpers -------------------------------------------------------------

def bar_row(label, value, vmax, accent):
    w = 0 if vmax == 0 else round(100 * value / vmax, 1)
    return f'''<div class="brow">
      <span class="blabel">{html.escape(label)}</span>
      <span class="btrack"><span class="bfill" style="width:{w}%;background:{accent}"></span></span>
      <span class="bval">{value}</span></div>'''

def sparkline(values, w=120, h=28):
    if not values or len(values) < 2 or max(values) == 0:
        return '<span class="muted">—</span>'
    vmax = max(values); n = len(values)
    pts = []
    for i, v in enumerate(values):
        x = round(i * w / (n - 1), 1)
        y = round(h - (v / vmax) * (h - 4) - 2, 1)
        pts.append(f"{x},{y}")
    last_x, last_y = pts[-1].split(",")
    return (f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'preserveAspectRatio="none" class="spark">'
            f'<polyline points="{" ".join(pts)}" fill="none" '
            f'stroke="var(--accent)" stroke-width="2" '
            f'stroke-linecap="round" stroke-linejoin="round"/>'
            f'<circle cx="{last_x}" cy="{last_y}" r="2.5" fill="var(--accent)"/></svg>')

# ---- render ------------------------------------------------------------------

def main():
    usage = read_usage_rows()
    evals = latest_evals()
    fleet = latest_fleet()
    seen = harness_seen()
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")

    GUARDS = [("test_gate", "test-gate"), ("gh_comment", "gh-comment-guard"),
              ("php_debug", "php-debug-guard"), ("merge", "merge-guard"),
              ("push", "push-guard")]
    # CSV rows are per-run DELTAS (incremental scan) — cumulative = sum across rows
    def cum(k):
        return sum(int(r[k]) for r in usage) if usage else 0
    cum_guard = {k: cum(k) for k, _ in GUARDS}
    guard_total = sum(cum_guard.values())
    vmax = max(cum_guard.values(), default=0)
    bars = "".join(bar_row(lbl, cum_guard[k], vmax, "var(--accent)")
                   for k, lbl in GUARDS) if usage else '<p class="muted">no data yet</p>'

    # per-guard sparklines across history
    spark_rows = ""
    for k, lbl in GUARDS:
        series = [int(r[k]) for r in usage]
        cur = series[-1] if series else 0
        spark_rows += (f'<div class="srow"><span class="blabel">{lbl}</span>'
                       f'{sparkline(series)}<span class="bval">{cur}</span></div>')

    # status tiles
    eval_state = "good" if evals and evals["npass"] == evals["n"] else ("critical" if evals else "muted")
    eval_val = f'{evals["npass"]}/{evals["n"]}' if evals else "—"
    def scoped(name):
        return SCOPE is None or name in SCOPE
    drift_projects = []
    if fleet:
        for name, d in fleet["proj"].items():
            if not scoped(name):
                continue
            iss = project_issues(name, d["flags"])
            if iss:
                drift_projects.append((name, iss))
    drift_state = "good" if fleet and not drift_projects else ("warning" if fleet else "muted")
    drift_val = "clean" if fleet and not drift_projects else (f'{len(drift_projects)} drift' if fleet else "—")
    ver_lag = seen != FLEET_TARGET
    ver_state = "warning" if ver_lag else "good"

    banned = cum("banned")

    # eval strip
    eval_strip = ""
    if evals:
        for num, name, verdict, detail in evals["evals"]:
            cls = "good" if verdict == "PASS" else "critical"
            eval_strip += (f'<div class="estrip {cls}"><span class="epill">{verdict}</span>'
                           f'<span class="ename">{num} {html.escape(name)}</span>'
                           f'<span class="edetail">{html.escape(detail)}</span></div>')
    else:
        eval_strip = '<p class="muted">no eval runs yet</p>'

    # fleet table
    fleet_rows = ""
    if fleet:
        for name, d in sorted(fleet["proj"].items()):
            if not scoped(name):
                continue
            iss = project_issues(name, d["flags"])
            if iss:
                tag = f'<span class="chip warn">{html.escape(", ".join(iss))}</span>'
            else:
                tag = '<span class="chip ok">clean</span>'
            ver = html.escape(d["flags"].get("ver", "—"))
            fleet_rows += (f'<tr><td>{html.escape(name)}</td>'
                           f'<td class="mono">{ver}</td><td>{tag}</td></tr>')
    else:
        fleet_rows = '<tr><td colspan="3" class="muted">no snapshot yet</td></tr>'

    tiles = f'''
      <div class="tile {eval_state}"><div class="tlabel">Rule evals</div>
        <div class="tval">{eval_val}</div>
        <div class="tsub">{html.escape(evals["harness"]) if evals else ""}</div></div>
      <div class="tile accent"><div class="tlabel">Guards fired</div>
        <div class="tval">{guard_total}</div>
        <div class="tsub">cumulative, all guards</div></div>
      <div class="tile {drift_state}"><div class="tlabel">Fleet config</div>
        <div class="tval">{drift_val}</div>
        <div class="tsub">vs baseline</div></div>
      <div class="tile {ver_state}"><div class="tlabel">Harness lag</div>
        <div class="tval mono">{html.escape(seen)}</div>
        <div class="tsub">upstream · fleet {FLEET_TARGET} (set {PIN_SET_ON})</div></div>'''

    doc = f'''<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tooling Telemetry</title>
<style>
:root {{
  --bg:#F4F6F6; --surface:#FFFFFF; --ink:#182124; --muted:#5C7074; --line:#DDE5E5;
  --accent:#0E6E68; --accent-soft:#E2EFEE;
  --good:#2E6B3C; --good-soft:#E5F0E7; --warn:#8A6410; --warn-soft:#F4EEDB;
  --crit:#A6401E; --crit-soft:#F5E7E1; --code:#EDF1F1;
}}
@media (prefers-color-scheme:dark){{:root{{
  --bg:#121819; --surface:#192224; --ink:#E1E9E9; --muted:#8FA3A5; --line:#2A3739;
  --accent:#47B4AB; --accent-soft:#16302D;
  --good:#71C083; --good-soft:#1A3121; --warn:#D6A63C; --warn-soft:#332A12;
  --crit:#E07A50; --crit-soft:#38241B; --code:#212C2E;
}}}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--ink);
  font-family:system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.5;font-size:15px}}
.wrap{{max-width:1000px;margin:0 auto;padding:2.5rem 1.25rem 4rem;
  display:flex;flex-direction:column;gap:2rem}}
.mono{{font-family:ui-monospace,Menlo,Consolas,monospace}}
header h1{{font-size:1.5rem;margin:0 0 .25rem;letter-spacing:-.02em}}
.sub{{color:var(--muted);font-size:.85rem;font-family:ui-monospace,Menlo,monospace}}
h2{{font-size:.78rem;text-transform:uppercase;letter-spacing:.1em;color:var(--muted);
  margin:0 0 .75rem;font-family:ui-monospace,Menlo,monospace}}
section{{background:var(--surface);border:1px solid var(--line);border-radius:12px;padding:1.35rem 1.5rem}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:1rem}}
.tile{{background:var(--surface);border:1px solid var(--line);border-left-width:4px;
  border-radius:10px;padding:1rem 1.2rem}}
.tile.good{{border-left-color:var(--good)}} .tile.warning{{border-left-color:var(--warn)}}
.tile.critical{{border-left-color:var(--crit)}} .tile.accent{{border-left-color:var(--accent)}}
.tile.muted{{border-left-color:var(--line)}}
.tlabel{{font-size:.7rem;text-transform:uppercase;letter-spacing:.09em;color:var(--muted);
  font-family:ui-monospace,Menlo,monospace}}
.tval{{font-size:1.9rem;font-weight:700;letter-spacing:-.02em;margin:.15rem 0;
  font-variant-numeric:tabular-nums}}
.tsub{{font-size:.75rem;color:var(--muted)}}
.brow,.srow{{display:flex;align-items:center;gap:.75rem;margin-bottom:.5rem}}
.blabel{{width:150px;font-size:.82rem;font-family:ui-monospace,Menlo,monospace;flex:none}}
.btrack{{flex:1;height:12px;background:var(--code);border-radius:6px;overflow:hidden}}
.bfill{{display:block;height:100%;border-radius:6px}}
.bval{{width:2.5rem;text-align:right;font-variant-numeric:tabular-nums;font-weight:600}}
.spark{{flex:1;max-width:160px}}
.estrip{{display:flex;align-items:baseline;gap:.75rem;padding:.4rem .6rem;border-radius:6px;
  margin-bottom:.35rem;border-left:3px solid var(--line)}}
.estrip.good{{border-left-color:var(--good)}} .estrip.critical{{border-left-color:var(--crit)}}
.epill{{font-family:ui-monospace,Menlo,monospace;font-size:.65rem;font-weight:700;
  padding:.1em .5em;border-radius:4px;flex:none}}
.estrip.good .epill{{color:var(--good);background:var(--good-soft)}}
.estrip.critical .epill{{color:var(--crit);background:var(--crit-soft)}}
.ename{{font-family:ui-monospace,Menlo,monospace;font-size:.8rem;flex:none;width:11rem}}
.edetail{{font-size:.78rem;color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
table{{width:100%;border-collapse:collapse;font-size:.85rem}}
th{{text-align:left;font-size:.68rem;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);
  padding:.5rem .6rem;border-bottom:1px solid var(--line);font-family:ui-monospace,Menlo,monospace}}
td{{padding:.45rem .6rem;border-bottom:1px solid var(--line);vertical-align:top}}
tr:last-child td{{border-bottom:none}} td:first-child{{font-weight:600}}
.chip{{font-size:.72rem;padding:.15em .55em;border-radius:5px;font-family:ui-monospace,Menlo,monospace}}
.chip.ok{{color:var(--good);background:var(--good-soft)}}
.chip.warn{{color:var(--warn);background:var(--warn-soft)}}
.muted{{color:var(--muted)}}
.note{{font-size:.78rem;color:var(--muted);margin-top:.6rem}}
.two{{display:grid;grid-template-columns:1fr 1fr;gap:1.5rem}}
@media (max-width:680px){{.two{{grid-template-columns:1fr}} .ename{{width:auto}} .edetail{{display:none}}}}
</style></head><body><div class="wrap">
<header><h1>Tooling Telemetry</h1>
<div class="sub">generated {now} · host · self-refreshes with the weekly crons</div></header>

<div class="tiles">{tiles}</div>

<section><h2>Guard fires — cumulative</h2>{bars}
<p class="note">How often each deterministic guard actually blocked something in real sessions.
A guard idle for many weeks is a pruning candidate; a spike signals workflow friction.</p></section>

<div class="two">
<section><h2>Guard trend</h2>{spark_rows}
<p class="note">Per-guard counts across telemetry runs. Meaningful once several weeks accrue.</p></section>
<section><h2>Banned-phrase leakage</h2>
<div class="tval" style="color:var(--{'crit' if banned else 'good'})">{banned}</div>
<p class="note">Blame-shift phrases in assistant text. Includes false positives
(rule quotes, review docs) — a trend line, not a verdict; open the source session to confirm.</p></section>
</div>

<section><h2>Rule evals — {evals["stamp"] if evals else "n/a"} · run {evals["runs"] if evals else 0}</h2>
{eval_strip}</section>

<section><h2>Fleet consolidation — in-scope projects — {fleet["stamp"] if fleet else "n/a"}</h2>
<table><thead><tr><th>Project</th><th>claude-code</th><th>Status</th></tr></thead>
<tbody>{fleet_rows}</tbody></table>
<p class="note">Only projects that need the tooling (host/tooling-scope.txt). Drift vs
fleet target {FLEET_TARGET}. Clean = aligned pin, wired, no legacy pipeline.md /
dangling refs / stale mounts. Out-of-scope projects (non-Magento, archived) are
not shown and do not count as drift.</p></section>

</div></body></html>'''

    OUT.write_text(doc)
    print(f"wrote {OUT} ({len(doc)} bytes)")

if __name__ == "__main__":
    main()
