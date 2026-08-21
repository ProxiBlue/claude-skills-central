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

def latest_usage_report():
    files = sorted(glob.glob(str(MON / "usage-telemetry" / "report-*.txt")))
    return Path(files[-1]) if files else None

def latest_modernization_projects():
    """Parse the per-project rows out of the newest usage-telemetry report
    (written by usage_telemetry.py's modernization_snapshot()) — the CSV only
    carries fleet-wide totals, so per-project drill-down comes from the report
    text, same pattern as latest_fleet()."""
    rp = latest_usage_report()
    if rp is None:
        return []
    txt = rp.read_text()
    rows = []
    for m in re.finditer(r"^\s{4}(\S+)\s+done=(\d+)\s+pending=(\d+)\s+blocked=(\d+)$", txt, re.M):
        rows.append((m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))))
    return rows

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

def recent_alerts(n=12):
    """Read ~/monitor/alerts.log (iso\\turgency\\ttitle\\tbody), newest first."""
    p = MON / "alerts.log"
    if not p.exists():
        return []
    rows = []
    for ln in p.read_text().splitlines()[-n:]:
        parts = ln.split("\t")
        if len(parts) >= 3:
            rows.append((parts[0], parts[1], parts[2], parts[3] if len(parts) > 3 else ""))
    return list(reversed(rows))

CRON_SNAPSHOT = Path(os.path.expanduser("~/.config/cron/crontab.lucas"))
CRON_FIELD_RE = re.compile(r'^(\S+\s+\S+\s+\S+\s+\S+\s+\S+)\s+(.*)$')

def read_crons():
    """Parse ~/.config/cron/crontab.lucas (refreshed nightly by
    ~/.config/cron/backup.sh) into (schedule, job_label, guard, full_cmd)
    rows. guard = 'cron-guard' | 'monitor.sh' | 'none' (unwrapped — no
    failure alert wired). Skips env-var header lines and comments."""
    if not CRON_SNAPSHOT.exists():
        return []
    rows = []
    for ln in CRON_SNAPSHOT.read_text().splitlines():
        ln = ln.strip()
        if not ln or ln.startswith("#") or re.match(r'^[A-Z_]+=\S*$', ln):
            continue
        m = CRON_FIELD_RE.match(ln)
        if not m:
            continue
        schedule, cmd = m.group(1), m.group(2)
        cg = re.search(r'cron-guard\.sh\s+(\S+)', cmd)
        mo = re.search(r'monitor\.sh\s+(\S+)', cmd)
        if cg:
            guard, label = "cron-guard", cg.group(1)
        elif mo:
            guard, label = "monitor.sh", f"monitor {mo.group(1)}"
        else:
            first_tok = cmd.split()[0] if cmd.split() else cmd
            guard, label = "none", os.path.basename(first_tok.split("=")[-1])
        rows.append((schedule, label, guard, cmd))
    return rows

# job name -> max age in days before STALE (mirrors monitor.sh registry)
JOB_MAXAGE = {"drift": 8, "usage": 8, "evals": 32, "dashboard": 2,
              "harness": 2, "pin": 2, "graphiti-backup": 2}

def collectors_health():
    """Read ~/monitor/heartbeats/<job> (iso\\trc\\tdur). Return list of
    (name, last_date, age_days, ok) and an overall_ok flag."""
    hbdir = MON / "heartbeats"
    now = datetime.datetime.now()
    rows = []
    overall = True
    for name, maxd in JOB_MAXAGE.items():
        f = hbdir / name
        if not f.exists():
            rows.append((name, "never", None, False)); overall = False; continue
        try:
            iso = f.read_text().split("\t")[0].strip()
            dt = datetime.datetime.fromisoformat(iso)
            age = (now - dt.replace(tzinfo=None)).days
            ok = age <= maxd
            rows.append((name, iso.split("T")[0], age, ok))
            if not ok:
                overall = False
        except Exception:
            rows.append((name, "?", None, False)); overall = False
    return rows, overall

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
    health_rows, health_ok = collectors_health()
    alerts = recent_alerts()
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

    # rector adoption — fired/clean/degraded are cumulative session counts
    # (same convention as guards); modernization done/pending/blocked is a
    # SNAPSHOT of current repo state, so take the latest row, not a sum.
    RECTOR = [("rector_fired", "fired"), ("rector_clean", "clean"),
              ("rector_degraded", "degraded")]
    cum_rector = {k: cum(k) for k, _ in RECTOR}
    rector_total = sum(cum_rector.values())
    rvmax = max(cum_rector.values(), default=0)
    rector_bars = "".join(bar_row(lbl, cum_rector[k], rvmax, "var(--accent)")
                          for k, lbl in RECTOR) if usage else '<p class="muted">no data yet</p>'
    rector_spark_rows = ""
    for k, lbl in RECTOR:
        series = [int(r.get(k, 0)) for r in usage]
        cur = series[-1] if series else 0
        rector_spark_rows += (f'<div class="srow"><span class="blabel">{lbl}</span>'
                              f'{sparkline(series)}<span class="bval">{cur}</span></div>')
    latest_row = usage[-1] if usage else None
    modern_done = int(latest_row.get("modernization_done", 0)) if latest_row else 0
    modern_pending = int(latest_row.get("modernization_pending", 0)) if latest_row else 0
    modern_blocked = int(latest_row.get("modernization_blocked", 0)) if latest_row else 0
    modern_total_cells = modern_done + modern_pending + modern_blocked
    modern_projects = latest_modernization_projects()
    rector_state = "warning" if cum_rector["rector_degraded"] > 0 else ("accent" if usage else "muted")
    usage_report = latest_usage_report()

    # quality-skill adoption — cumulative real invocation counts, registered
    # everywhere but only worth trusting once actually called
    QSKILLS = [("simplify_invoked", "/simplify"), ("code_review_invoked", "/code-review")]
    cum_qskill = {k: cum(k) for k, _ in QSKILLS}
    qskill_total = sum(cum_qskill.values())
    qvmax = max(cum_qskill.values(), default=0)
    qskill_bars = "".join(bar_row(lbl, cum_qskill[k], qvmax, "var(--accent)")
                          for k, lbl in QSKILLS) if usage else '<p class="muted">no data yet</p>'
    qskill_state = "critical" if qskill_total == 0 else ("warning" if qskill_total < 5 else "good")

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

    # crons — host inventory + recreate reference
    crons = read_crons()
    GUARD_CHIP = {"cron-guard": ("ok", "guarded"), "monitor.sh": ("ok", "monitor.sh"),
                  "none": ("warn", "unguarded")}
    cron_rows = ""
    for schedule, label, guard, cmd in crons:
        cls, chiptxt = GUARD_CHIP[guard]
        cron_rows += (f'<tr><td class="mono">{html.escape(schedule)}</td>'
                      f'<td>{html.escape(label)}</td>'
                      f'<td><span class="chip {cls}">{chiptxt}</span></td>'
                      f'<td class="mono" style="font-size:.72rem;color:var(--muted)" '
                      f'title="{html.escape(cmd)}">{html.escape(cmd[:70])}{"…" if len(cmd) > 70 else ""}</td></tr>')
    unguarded_n = sum(1 for *_, g, _ in crons if g == "none")
    CONTAINER_CRONS = [
        ("PVC + lcd-mageos", "* * * * *", "pb-chatroom heartbeat tick",
         ".ddev/web-build/pb-chatroom.cron", "opt-in via .chatroom-auto.enabled sentinel"),
        ("PVC + lcd-mageos", "0 */6 * * *", "pb-graphiti ticket ingest",
         ".ddev/web-build/pb-graphiti.cron", "email ingest moved host-side 2026-07-17"),
    ]
    container_cron_rows = "".join(
        f'<tr><td>{html.escape(proj)}</td><td class="mono">{html.escape(sched)}</td>'
        f'<td>{html.escape(desc)}</td><td class="mono" style="font-size:.75rem">{html.escape(path)}</td>'
        f'<td style="font-size:.78rem;color:var(--muted)">{html.escape(note)}</td></tr>'
        for proj, sched, desc, path, note in CONTAINER_CRONS)

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

    # modernization-sweep matrix table (per project, current repo state)
    modern_rows = ""
    for name, done, pending, blocked in modern_projects:
        total = done + pending + blocked
        pct = round(100 * done / total) if total else 0
        tag = (f'<span class="chip {"ok" if blocked == 0 else "warn"}">'
               f'{done}/{total} done{f", {blocked} blocked" if blocked else ""}</span>')
        modern_rows += (f'<tr><td>{html.escape(name)}</td>'
                        f'<td class="mono">{pct}%</td><td>{tag}</td></tr>')
    if not modern_rows:
        modern_rows = '<tr><td colspan="3" class="muted">no modernization-state.json found under ~/workspace</td></tr>'

    tiles = f'''
      <div class="tile {eval_state}"><div class="tlabel">Rule evals</div>
        <div class="tval">{eval_val}</div>
        <div class="tsub">{html.escape(evals["harness"]) if evals else ""}</div></div>
      <div class="tile accent"><div class="tlabel">Guards fired</div>
        <div class="tval">{guard_total}</div>
        <div class="tsub">cumulative, all guards</div></div>
      <div class="tile {rector_state}"><div class="tlabel">Rector adoption</div>
        <div class="tval">{cum_rector['rector_fired']}/{rector_total}</div>
        <div class="tsub">fired/total runs · {modern_done}/{modern_total_cells} modules modernized</div></div>
      <div class="tile {qskill_state}"><div class="tlabel">Quality skills used</div>
        <div class="tval">{qskill_total}</div>
        <div class="tsub">/simplify {cum_qskill['simplify_invoked']} · /code-review {cum_qskill['code_review_invoked']} — real invocations</div></div>
      <div class="tile {drift_state}"><div class="tlabel">Fleet config</div>
        <div class="tval">{drift_val}</div>
        <div class="tsub">vs baseline</div></div>
      <div class="tile {ver_state}"><div class="tlabel">Harness lag</div>
        <div class="tval mono">{html.escape(seen)}</div>
        <div class="tsub">upstream · fleet {FLEET_TARGET} (set {PIN_SET_ON})</div></div>
      <div class="tile {'good' if health_ok else 'critical'}"><div class="tlabel">Collectors</div>
        <div class="tval">{sum(1 for r in health_rows if r[3])}/{len(health_rows)}</div>
        <div class="tsub">heartbeats fresh</div></div>'''

    alert_rows = ""
    for ts, urg, title, body in alerts:
        cls = "critical" if urg == "critical" else "warn"
        when = ts.replace("T", " ")[:16]
        alert_rows += (f'<div class="estrip {"critical" if urg=="critical" else ""}">'
                       f'<span class="epill" style="color:var(--{"crit" if urg=="critical" else "warn"});'
                       f'background:var(--{"crit" if urg=="critical" else "warn"}-soft)">{html.escape(urg)}</span>'
                       f'<span class="ename" style="width:9.5rem">{html.escape(when)}</span>'
                       f'<span class="edetail">{html.escape(title)} — {html.escape(body)}</span></div>')
    if not alert_rows:
        alert_rows = '<p class="muted">no alerts logged yet</p>'

    health_cells = ""
    for name, last, age, ok in health_rows:
        cls = "ok" if ok else "warn"
        agestr = f"{age}d" if age is not None else last
        health_cells += (f'<span class="chip {cls}" title="last run {last}">'
                         f'{html.escape(name)} · {agestr}</span>')

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
a{{color:var(--accent)}}
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
.hstrip{{display:flex;flex-wrap:wrap;gap:.5rem}}
.muted{{color:var(--muted)}}
.note{{font-size:.78rem;color:var(--muted);margin-top:.6rem}}
.two{{display:grid;grid-template-columns:1fr 1fr;gap:1.5rem}}
@media (max-width:680px){{.two{{grid-template-columns:1fr}} .ename{{width:auto}} .edetail{{display:none}}}}
</style></head><body><div class="wrap">
<header><h1>Tooling Telemetry</h1>
<div class="sub">generated {now} · host · self-refreshes with the weekly crons</div></header>

<div class="tiles">{tiles}</div>

<section><h2>Recent alerts</h2>{alert_rows}
<p class="note">Every actionable alert (job failure, pin stale, drift, dead collector,
new release) is logged here as it fires — so a desktop popup you miss is still
findable. Full log: <code>~/monitor/alerts.log</code> or <code>monitor alerts</code>.
Delivered live to desktop when you're here, and to email when configured.</p></section>

<section><h2>Collectors — liveness</h2>
<div class="hstrip">{health_cells}</div>
<p class="note">Each telemetry job records a heartbeat on every run; a job that stops
writing turns red here (age &gt; its expected cadence). This is the dead-man's
switch — a silently-dead cron becomes visible on the dashboard you already open,
with no separate watcher. Run <code>monitor health</code> for the same check in the shell.</p></section>

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

<section><h2>Rector adoption — cumulative</h2>{rector_bars}
{f'<p class="note"><a href="file://{html.escape(str(usage_report))}">view raw report ({usage_report.name})</a> · <a href="file://{html.escape(str(MON / "usage-telemetry" / "metrics.csv"))}">metrics.csv</a></p>' if usage_report else ''}
<p class="note">How often <code>rector-check.sh</code> actually ran in real sessions across pb-hcf
projects (build gate + pre-commit-adversarial-pass's rector-diff judgment step). "degraded" = the
gate ran but the project isn't wired for rector yet (no <code>rector.php</code> / binary) — an
adoption gap, not a usage count.</p></section>

<div class="two">
<section><h2>Rector trend</h2>{rector_spark_rows}
<p class="note">Per-signal counts across telemetry runs.</p></section>
<section><h2>Modernization-sweep matrix</h2>
<div class="tval">{modern_done}/{modern_total_cells}</div>
<div class="tsub">module × ruleset cells done, current repo state across all projects</div>
<table style="margin-top:.75rem"><thead><tr><th>Project</th><th>% done</th><th>Status</th></tr></thead>
<tbody>{modern_rows}</tbody></table>
<p class="note">Snapshot of every <code>.claude/modernization-state.json</code> under
<code>~/workspace</code> — not cumulative like the counts above, re-read fresh each run.</p></section>
</div>

<section><h2>Quality skills — cumulative real invocations</h2>{qskill_bars}
<p class="note">Registered and available in every session (host + every ddev project) —
this counts actual <code>/simplify</code> / <code>/code-review</code> invocations found in
real transcripts, not availability. Available ≠ used; a skill sitting at 0 for weeks despite
being on the always-listed menu means nobody is reaching for it, whatever the reason.</p></section>

<section><h2>Rule evals — {evals["stamp"] if evals else "n/a"} · run {evals["runs"] if evals else 0}</h2>
{eval_strip}</section>

<section><h2>Crons — host ({len(crons)} jobs{f", {unguarded_n} unguarded" if unguarded_n else ""})</h2>
<table><thead><tr><th>Schedule (UTC)</th><th>Job</th><th>Alerting</th><th>Command</th></tr></thead>
<tbody>{cron_rows if cron_rows else '<tr><td colspan="4" class="muted">no crontab.lucas snapshot found</td></tr>'}</tbody></table>
<p class="note">Live snapshot of <code>crontab -l</code>, refreshed nightly by
<code>~/.config/cron/backup.sh</code> (git-backed in the dotfiles repo). "guarded" = wrapped in
<code>cron-guard.sh</code> or dispatched via <code>monitor.sh</code> — both fire a
desktop+email+alerts.log alert on nonzero exit. "unguarded" jobs fail silently into their log file.
<b>Recreate everything:</b> <code>cd ~/.config/cron &amp;&amp; ./restore.sh</code> (reinstalls
scripts + the full crontab from this snapshot). <b>Recreate one job:</b> copy its Command cell into
<code>crontab -e</code>.</p></section>

<section><h2>Crons — container (git-committed, not live-queried)</h2>
<table><thead><tr><th>Project</th><th>Schedule</th><th>Job</th><th>Source</th><th>Note</th></tr></thead>
<tbody>{container_cron_rows}</tbody></table>
<p class="note">Committed per-project at <code>.ddev/web-build/*.cron</code> +
<code>Dockerfile.ddev-cron</code> — <b>recreate:</b> <code>ddev restart</code> in the project
rebuilds the container cron from these files. Not polled live here (containers may be stopped when
this dashboard regenerates); this is the static reference, source of truth is the committed files.</p></section>

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
