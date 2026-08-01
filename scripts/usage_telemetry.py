#!/usr/bin/env python3
"""Weekly real-usage telemetry — counts how often rules/guards actually fire in
real Claude Code sessions (vs the synthetic rule-evals). Closes rec #4 of the
2026-07-31 tooling review: turn "I feel the rules help" into data.

CENTRALISED DISCOVERY: reuses pb-graphiti's ingest_sessions.iter_sessions() for
fleet transcript discovery (mangled-dir convention, project glob, host +
container roots) instead of re-walking. That module is the canonical transcript
walker; this shares it so there is ONE discovery path to maintain. Telemetry
needs raw tool-result lines (guard fires live in toolUseResult, which the
graphiti condenser strips), so it does its own fast single-pass regex per file
rather than reusing condense_session().

Metrics (incremental via a byte-offset state file):
  - guard fires per guard, counted only in tool-result / hook contexts
  - investigation-protocol injections + test-gate evidence passes
  - banned blame-shift phrases in ASSISTANT text (real-session leakage)

Usage: usage_telemetry.py [--dry-run] [--since-all] [--roots a:b] [--post]
Output: ~/monitor/usage-telemetry/report-<stamp>.txt + rolling metrics.csv
Posts a chatroom summary (host-auto -> host) when --post and not --dry-run.
"""
from __future__ import annotations
import argparse, json, os, re, sys, glob, subprocess, datetime
from pathlib import Path

# --- reuse the canonical walker ------------------------------------------------
INGEST_DIR = os.path.expanduser(
    "~/claude-plugins-central/seed/marketplaces/pb-graphiti/scripts"
)
sys.path.insert(0, INGEST_DIR)
try:
    from ingest_sessions import iter_sessions  # type: ignore
except Exception as e:  # pragma: no cover - fall back to a local walker
    iter_sessions = None
    _IMPORT_ERR = e

GUARDS = ["merge-guard", "push-guard", "test-gate",
          "gh-comment-guard", "php-debug-guard"]
BANNED = ["must be a flake", "not my code", "not caused by my changes",
          "this is environmental", "pre-existing issue",
          "infrastructure is down", "external service is broken"]

# guard fire signature: only in a tool result / hook error line, not in
# assistant prose or a tool INPUT (so a session discussing "BLOCKED by X" — like
# this build session — is not miscounted). The transcript stores these as JSON
# lines; the fire lands in a line whose parsed object has toolUseResult or
# attachment carrying the string. We detect that structurally per line.
FIRE_RE = {g: re.compile(r"BLOCKED by " + re.escape(g)) for g in GUARDS}
INJECT_RE = re.compile(r"investigation protocol now in force")


def default_roots() -> list[Path]:
    roots = [Path(os.path.expanduser("~/.claude/projects"))]
    for m in glob.glob(os.path.expanduser(
            "~/workspace/*/*/.ddev/claude-code/.claude/projects")):
        roots.append(Path(m))
    return [r for r in roots if r.is_dir()]


def walk(roots: list[Path]):
    """Yield jsonl Paths. Reuse ingest_sessions.iter_sessions per root when
    available; else a direct glob."""
    for root in roots:
        if iter_sessions is not None:
            for _proj, path in iter_sessions(root, None):
                yield path
        else:
            for path in root.glob("*/*.jsonl"):
                yield path


def line_is_fire(obj: dict) -> str | None:
    """Return guard name if this transcript line is an actual guard fire
    (string sits in a tool-result / hook context), else None."""
    haystacks = []
    tur = obj.get("toolUseResult")
    if tur is not None:
        haystacks.append(json.dumps(tur) if not isinstance(tur, str) else tur)
    att = obj.get("attachment")
    if att is not None:
        haystacks.append(json.dumps(att))
    if not haystacks:
        return None
    blob = "\n".join(haystacks)
    for g, rx in FIRE_RE.items():
        if rx.search(blob):
            return g
    return None


def assistant_text(obj: dict) -> str:
    if obj.get("type") != "assistant":
        return ""
    msg = obj.get("message", {})
    parts = []
    for b in msg.get("content", []) or []:
        if isinstance(b, dict) and b.get("type") == "text":
            parts.append(b.get("text", ""))
    return "\n".join(parts)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--since-all", action="store_true",
                    help="ignore offsets; rescan every transcript from start")
    ap.add_argument("--roots", default="", help="extra roots, colon-separated")
    ap.add_argument("--post", action="store_true",
                    help="post a chatroom summary (host-auto -> host)")
    args = ap.parse_args()

    outdir = Path(os.path.expanduser("~/monitor/usage-telemetry"))
    outdir.mkdir(parents=True, exist_ok=True)
    state_path = outdir / "offsets.json"
    csv_path = outdir / "metrics.csv"
    stamp = datetime.datetime.now().strftime("%Y-%m-%d-%H%M")
    report_path = outdir / f"report-{stamp}.txt"

    state = {}
    if state_path.exists() and not args.since_all:
        try:
            state = json.loads(state_path.read_text())
        except Exception:
            state = {}

    roots = default_roots()
    for extra in filter(None, args.roots.split(":")):
        p = Path(os.path.expanduser(extra))
        if p.is_dir():
            roots.append(p)

    g_fire = {g: 0 for g in GUARDS}
    ban = {b: 0 for b in BANNED}
    inject = 0
    files_scanned = 0
    lines_new = 0
    new_state = dict(state)

    for path in walk(roots):
        key = str(path)
        try:
            total = sum(1 for _ in path.open("r", errors="ignore"))
        except Exception:
            continue
        prev = state.get(key, 0)
        if total <= prev:
            new_state[key] = total
            continue
        files_scanned += 1
        with path.open("r", errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i < prev:
                    continue
                lines_new += 1
                # cheap prefilter before JSON parse
                if "BLOCKED by" in line:
                    try:
                        obj = json.loads(line)
                        g = line_is_fire(obj)
                        if g:
                            g_fire[g] += 1
                    except Exception:
                        pass
                if "investigation protocol now in force" in line:
                    inject += 1
                if any(b in line for b in BANNED):
                    try:
                        obj = json.loads(line)
                        txt = assistant_text(obj).lower()
                        for b in BANNED:
                            if b in txt:
                                ban[b] += 1
                    except Exception:
                        pass
        new_state[key] = total

    if not args.dry_run:
        state_path.write_text(json.dumps(new_state, indent=0, sort_keys=True))

    total_guards = sum(g_fire.values())
    total_banned = sum(ban.values())

    lines = []
    lines.append(f"USAGE TELEMETRY {stamp} — scanned {files_scanned} files, "
                 f"{lines_new} new lines")
    lines.append("")
    lines.append(f"Guard fires (real sessions): total {total_guards}")
    for g in GUARDS:
        lines.append(f"  {g:<18} {g_fire[g]}")
    lines.append("")
    lines.append(f"Investigation-protocol injections: {inject}")
    lines.append("")
    lines.append(f"Banned blame-shift phrases in assistant text: total {total_banned}")
    if total_banned:
        for b in BANNED:
            if ban[b]:
                lines.append(f"  {b:<32} {ban[b]}")
    else:
        lines.append("  (none — clean)")
    lines.append("")
    lines.append("Read: a guard at 0 over many weeks = pruning candidate; a "
                 "spike = workflow friction.")
    lines.append("CAVEAT: banned-phrase counts include FALSE POSITIVES — the "
                 "phrase in a rule quote, a review doc, or meta-discussion (like "
                 "the session that built this) counts too. Treat the number as a "
                 "trend line, not a verdict; open the source session to confirm "
                 "real blame-shift leakage before acting.")
    report = "\n".join(lines)
    print(report)
    report_path.write_text(report)

    if not csv_path.exists():
        csv_path.write_text("stamp,merge,push,test_gate,gh_comment,php_debug,"
                            "injections,banned\n")
    with csv_path.open("a") as fh:
        fh.write(f"{stamp},{g_fire['merge-guard']},{g_fire['push-guard']},"
                 f"{g_fire['test-gate']},{g_fire['gh-comment-guard']},"
                 f"{g_fire['php-debug-guard']},{inject},{total_banned}\n")

    if args.post and not args.dry_run:
        summary = (f"Usage telemetry {stamp}: guards fired {total_guards}x "
                   f"(gate {g_fire['test-gate']}, gh-comment "
                   f"{g_fire['gh-comment-guard']}, php-debug "
                   f"{g_fire['php-debug-guard']}, merge {g_fire['merge-guard']}, "
                   f"push {g_fire['push-guard']}); injections {inject}; banned "
                   f"phrases {total_banned}. Scanned {files_scanned} files.\n\n"
                   f"Full: {report_path}")
        url = os.environ.get("PB_CHATROOM_REST_URL", "http://127.0.0.1:7476")
        try:
            subprocess.run(
                ["curl", "-sS", "-X", "POST", f"{url}/api/threads",
                 "-H", "Content-Type: application/json",
                 "-H", "X-PB-Chatroom-Participant: host-auto",
                 "-d", json.dumps({"to": "host",
                                   "subject": f"Usage telemetry {stamp}",
                                   "body": summary,
                                   "discussion_type": "postmortem"})],
                check=False, capture_output=True, timeout=20)
            print("(summary posted to chatroom)")
        except Exception as e:
            print(f"(chatroom post failed: {e})")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
