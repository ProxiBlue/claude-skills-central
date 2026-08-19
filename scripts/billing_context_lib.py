#!/usr/bin/env python3
"""Shared helpers for the billing-context-guard hook family (PreCompact,
SessionEnd(clear), SessionStart(clear)).

Deterministic only — no LLM judgment. "Invoiced" ground truth is GitHub issue
labels, the same source proxiblue-skills' billing-invoice SKILL.md already
uses (closed + "has been deployed live" label + no "invoiced" label =
billable and unbilled — see that skill's "Finding all uninvoiced tickets"
recipe, mirrored here rather than reinvented).

Silent no-op on any non-billing project (no /etc/billing-bridge/token) or any
gh/git failure — this must never be the reason a compact/clear fails.
"""
from __future__ import annotations
import json, os, re, subprocess, sys
from pathlib import Path

STATE_DIR = Path(os.path.expanduser("~/.claude/billing-context-guard"))


def billing_bridge_configured() -> bool:
    return os.path.exists("/etc/billing-bridge/token")


def project_id(repo: str | None) -> str:
    """Graphiti group_id — $DDEV_PROJECT is the established convention for
    per-project scoping from inside a container (see graphiti-usage.md),
    preferred over deriving from the repo name."""
    return os.environ.get("DDEV_PROJECT") or (repo.split("/")[-1] if repo else "unknown")


def current_repo() -> str | None:
    try:
        out = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            capture_output=True, text=True, timeout=15, check=True,
        )
        return out.stdout.strip() or None
    except Exception:
        return None


def uninvoiced_deployed_tickets(repo: str) -> list[dict]:
    """Mirrors billing-invoice SKILL.md's 'Finding all uninvoiced tickets' recipe."""
    try:
        out = subprocess.run(
            ["gh", "issue", "list", "--repo", repo, "--label", "has been deployed live",
             "--state", "closed", "--json", "number,title,labels"],
            capture_output=True, text=True, timeout=20, check=True,
        )
        issues = json.loads(out.stdout or "[]")
    except Exception:
        return []
    return [i for i in issues
            if not any(l.get("name", "").lower() == "invoiced" for l in i.get("labels", []))]


def open_tickets_touched_this_session(cwd: str) -> list[str]:
    """Ticket numbers referenced in recent commits that are still OPEN (not
    closed) — signals ongoing, not-yet-invoiceable work worth bridging to
    graphiti before context is lost. Session boundary is a time heuristic
    (BILLING_GUARD_SINCE, default 4h) since hooks don't get a clean
    session-start commit ref."""
    since = os.environ.get("BILLING_GUARD_SINCE", "4 hours ago")
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "log", f"--since={since}", "--oneline"],
            capture_output=True, text=True, timeout=15, check=True,
        )
    except Exception:
        return []
    numbers = sorted(set(re.findall(r"#(\d+)", out.stdout)), key=int)
    if not numbers:
        return []
    repo = current_repo()
    if not repo:
        return []
    open_nums = []
    for n in numbers:
        try:
            r = subprocess.run(
                ["gh", "issue", "view", n, "--repo", repo, "--json", "state", "--jq", ".state"],
                capture_output=True, text=True, timeout=15, check=True,
            )
            if r.stdout.strip().upper() == "OPEN":
                open_nums.append(n)
        except Exception:
            continue
    return open_nums


def recent_commit_summary(cwd: str, ticket_numbers: list[str]) -> str:
    """Factual anchor for later AI-actual-time estimation: commit subjects +
    first/last timestamp for the session window. No narrative summarization —
    deterministic, not an LLM judgment call."""
    since = os.environ.get("BILLING_GUARD_SINCE", "4 hours ago")
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "log", f"--since={since}", "--date=iso-strict",
             "--pretty=%ad %s"],
            capture_output=True, text=True, timeout=15, check=True,
        )
        lines = [l for l in out.stdout.splitlines() if l.strip()]
    except Exception:
        lines = []
    if not lines:
        return f"tickets {', '.join('#' + n for n in ticket_numbers)}, no commits found in window ({since})."
    first_ts = lines[-1].split(" ", 1)[0]
    last_ts = lines[0].split(" ", 1)[0]
    return (f"{len(lines)} commit(s) from {first_ts} to {last_ts}:\n"
            + "\n".join(f"  {l}" for l in lines))


def write_bridge_note(cwd: str, project_id: str, ticket_numbers: list[str], trigger: str) -> None:
    """Best-effort graphiti write — never raises, never blocks the hook.

    This hook family only ever runs inside a ddev container (gated on
    /etc/billing-bridge/token, which is a container-only mount) — so the
    paths below are container paths, not host paths. pb-graphiti's scripts
    live under the plugins-seed mount; graphiti itself is reached via
    host.docker.internal, same as this project's own mcp.json graphiti
    entry."""
    try:
        sys.path.insert(0, "/var/www/html/.claude/plugins-seed/marketplaces/pb-graphiti/scripts")
        from graphiti_client import GraphitiClient, GraphitiError  # type: ignore
        url = os.environ.get("GRAPHITI_URL", "http://host.docker.internal:8765/mcp")
        client = GraphitiClient(url)
        summary = recent_commit_summary(cwd, ticket_numbers)
        body = (
            f"Ongoing/unbilled work bridge note — {project_id}, "
            f"tickets {', '.join('#' + n for n in ticket_numbers)}. Session context is about to "
            f"be lost ({trigger}) before this work reached an invoice-ready state (not yet "
            f"closed + deployed). Captured so billing time-estimation detail (AI actual vs "
            f"human est) isn't lost:\n{summary}"
        )
        client.add_memory(
            group_id=project_id,
            name=f"Billing bridge — {project_id} {','.join(ticket_numbers)}",
            episode_body=body,
            source="text",
            source_description=f"billing-context-guard ({trigger})",
        )
    except Exception:
        pass


def state_path_for_cwd(cwd: str) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    key = re.sub(r"[^A-Za-z0-9_-]", "_", cwd.strip("/"))
    return STATE_DIR / f"{key}.json"
