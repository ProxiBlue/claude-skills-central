#!/usr/bin/env python3
"""bugsink-prod-pull — feed production Magento error logs into local Bugsink.

AP-2 option A (2026-08-03): production cannot push to the workstation-local
Bugsink, so we PULL. A cron job SSH-reads the prod exception log (READ-ONLY —
one `tail -c` per log, nothing else; honours the hard "SSH to live is read-only"
rule), parses new monolog records since the last run, and posts them to the
local Bugsink ingest API as Sentry-shaped events. Zero prod-side changes, zero
public exposure of Bugsink.

Config (env file, default ~/.config/bugsink-prod-pull.env):
    PULL_SSH_HOST=hypernode_pps            # ~/.ssh/config alias for prod
    PULL_REMOTE_LOGS=/path/exception.log[,/path/system.log]
    PULL_DSN=http://<key>@localhost:7788/<project-id>   # bugsink project DSN
    PULL_ENVIRONMENT=production
    PULL_MAX_EVENTS=50                     # per-run flood cap

State: ~/monitor/bugsink-pull/<host>-<logbasename>.state  (JSON: byte offset)
Log rotation: remote size < stored offset -> start over from 0.

Modes:
    (default)        SSH-pull each configured log, parse, post
    --dry-run        parse + print what would post; no posting
    --stdin NAME     read log content from stdin instead of SSH (tests); NAME
                     is the pretend log name. Combines with --dry-run.

Exit codes: 0 ok (posted or nothing new), 1 config/infra error. Never partial-
crashes on a malformed record — bad records are skipped and counted.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path

STATE_DIR = Path(os.environ.get("PULL_STATE_DIR", Path.home() / "monitor" / "bugsink-pull"))
CFG_FILE = Path(os.environ.get("PULL_CFG", Path.home() / ".config" / "bugsink-prod-pull.env"))

RECORD_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T[0-9:.+\-]+)\]\s+(\w+)\.(\w+):\s?(.*)$")
# "... (Some\Exception\Class(code: 0): message at /path/file.php:123)"
EXC_RE = re.compile(r"\(([A-Za-z_][A-Za-z0-9_\\]*)\(code:\s*\d+\):\s*(.*?)\s+at\s+(\S+?):(\d+)\)", re.S)


def load_cfg():
    cfg = {}
    if CFG_FILE.is_file():
        for line in CFG_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    for k in ("PULL_SSH_HOST", "PULL_REMOTE_LOGS", "PULL_DSN", "PULL_ENVIRONMENT", "PULL_MAX_EVENTS"):
        if k in os.environ:
            cfg[k] = os.environ[k]
    return cfg


def parse_records(text):
    """Split monolog output into records (a [ts] line + its continuation lines)."""
    records, cur = [], None
    for line in text.splitlines():
        m = RECORD_RE.match(line)
        if m:
            if cur:
                records.append(cur)
            cur = {"ts": m.group(1), "channel": m.group(2), "level": m.group(3).lower(),
                   "message": m.group(4), "extra_lines": []}
        elif cur:
            cur["extra_lines"].append(line)
    if cur:
        records.append(cur)
    return records


LEVEL_MAP = {"debug": "debug", "info": "info", "notice": "info", "warning": "warning",
             "error": "error", "critical": "fatal", "alert": "fatal", "emergency": "fatal"}


def record_to_event(rec, logname, environment):
    """Build a Sentry store-API event from one monolog record. None = skip (below error)."""
    if LEVEL_MAP.get(rec["level"], "error") not in ("error", "fatal"):
        return None
    full = rec["message"] + ("\n" + "\n".join(rec["extra_lines"]) if rec["extra_lines"] else "")
    event = {
        "event_id": uuid.uuid4().hex,
        "platform": "php",
        "level": LEVEL_MAP.get(rec["level"], "error"),
        "logger": f"{rec['channel']}/{logname}",
        "environment": environment,
        "tags": {"source": "log-pull"},
    }
    # timestamp: bugsink accepts RFC3339; pass through, fall back to now
    event["timestamp"] = rec["ts"] if "T" in rec["ts"] else time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    m = EXC_RE.search(full)
    if m:
        etype, evalue, efile, eline = m.group(1), m.group(2).strip(), m.group(3), int(m.group(4))
        # monolog JSON-escapes backslashes in the context string — undo for clean class names
        etype = etype.replace("\\\\", "\\")
        evalue = evalue.replace("\\\\", "\\")
        event["exception"] = {"values": [{
            "type": etype.split("\\")[-1],
            "value": evalue[:500],
            "module": etype,
            "stacktrace": {"frames": [{"filename": efile, "lineno": eline, "in_app": True}]},
        }]}
        event["culprit"] = f"{efile}:{eline}"
    else:
        event["message"] = full[:1000]
    return event


def post_event(dsn, event):
    """POST one event via the Sentry store API derived from the DSN."""
    m = re.match(r"(https?)://([0-9a-f]+)@([^/]+)/(\d+)$", dsn)
    if not m:
        raise ValueError(f"unparseable DSN")
    scheme, key, host, project = m.groups()
    url = f"{scheme}://{host}/api/{project}/store/"
    req = urllib.request.Request(
        url, data=json.dumps(event).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={key}, sentry_client=bugsink-prod-pull/1.0",
        })
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.status


def ssh_read(host, path, offset):
    """Read-only remote read: size check + tail from offset. Two commands, both reads."""
    out = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host,
         f"wc -c < {path} 2>/dev/null; echo ---SPLIT---; tail -c +{offset + 1} {path} 2>/dev/null | head -c 1048576"],
        capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        raise RuntimeError(f"ssh failed: {out.stderr.strip()[:200]}")
    head, _, body = out.stdout.partition("---SPLIT---\n")
    size = int(head.strip() or 0)
    return size, body


def state_path(host, logpath):
    return STATE_DIR / f"{host}-{Path(logpath).name}.state"


def run():
    dry = "--dry-run" in sys.argv
    stdin_name = None
    if "--stdin" in sys.argv:
        stdin_name = sys.argv[sys.argv.index("--stdin") + 1]

    cfg = load_cfg()
    environment = cfg.get("PULL_ENVIRONMENT", "production")
    max_events = int(cfg.get("PULL_MAX_EVENTS", "50"))
    dsn = cfg.get("PULL_DSN", "")
    if not dry and not stdin_name and not dsn:
        # Same "not switched on" state as missing host/logs — skip, don't page.
        print("bugsink-prod-pull: not configured (PULL_DSN) — skipping")
        return 0
    if not dry and stdin_name and not dsn:
        print("bugsink-prod-pull: PULL_DSN required to post stdin events", file=sys.stderr)
        return 1

    sources = []
    if stdin_name:
        sources.append((stdin_name, sys.stdin.read(), None, None))
    else:
        host = cfg.get("PULL_SSH_HOST", "")
        logs = [p for p in cfg.get("PULL_REMOTE_LOGS", "").split(",") if p.strip()]
        if not host or not logs:
            # Not configured is a valid state (feed not switched on yet), not a
            # failure — exit 0 so the monitor doesn't page about a choice.
            print("bugsink-prod-pull: not configured (PULL_SSH_HOST/PULL_REMOTE_LOGS) — skipping")
            return 0
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        for lp in logs:
            lp = lp.strip()
            sp = state_path(host, lp)
            offset = 0
            if sp.is_file():
                try:
                    offset = json.loads(sp.read_text()).get("offset", 0)
                except (ValueError, OSError):
                    offset = 0
            try:
                size, body = ssh_read(host, lp, offset)
            except (RuntimeError, subprocess.TimeoutExpired) as e:
                print(f"bugsink-prod-pull: {lp}: {e}", file=sys.stderr)
                return 1
            if size < offset:  # rotated — re-read from start
                size, body = ssh_read(host, lp, 0)
            sources.append((Path(lp).name, body, sp, size))

    total_posted = total_skipped = 0
    for logname, text, sp, new_offset in sources:
        records = parse_records(text)
        events = [e for e in (record_to_event(r, logname, environment) for r in records) if e]
        dropped = 0
        if len(events) > max_events:
            dropped = len(events) - max_events
            events = events[-max_events:]  # newest win
        for ev in events:
            if dry:
                print(json.dumps({k: ev[k] for k in ev if k != "event_id"})[:400])
            else:
                try:
                    post_event(dsn, ev)
                    total_posted += 1
                except Exception as e:  # noqa: BLE001 — one bad event must not kill the run
                    total_skipped += 1
                    print(f"bugsink-prod-pull: post failed: {e}", file=sys.stderr)
        if dropped:
            print(f"[{logname}] flood cap: dropped {dropped} oldest events (cap {max_events})")
        if sp is not None and not dry:
            sp.write_text(json.dumps({"offset": new_offset, "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}))
        print(f"[{logname}] records={len(records)} error-events={len(events)} posted={0 if dry else total_posted} dry={dry}")
    if total_skipped:
        print(f"bugsink-prod-pull: {total_skipped} events failed to post", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(run())
