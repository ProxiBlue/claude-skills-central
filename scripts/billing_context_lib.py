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


BRIDGE_URL = os.environ.get("BILLING_BRIDGE_URL", "http://ddev-billing-web/internal/cli")
DEAD_INVOICE_STATUSES = {"VOIDED", "DELETED"}


def matching_invoices(query_stdout: str, number: int | str) -> list[dict]:
    """Invoices from `xero-invoice query` stdout that really bill ticket #N.

    The bridge's --ref match is a substring match (#1 hits an invoice naming
    #191), and some invoices name tickets only in line items (reference just
    "PPS"), so re-check reference + every line description for #N not
    followed by another digit. Voided/deleted invoices don't count."""
    try:
        invoices = json.loads(query_stdout)
    except Exception:
        return []
    if not isinstance(invoices, list):  # {"message": "No invoices found ..."}
        return []
    pat = re.compile(rf"#{number}(?!\d)")
    hits = []
    for inv in invoices:
        if str(inv.get("status", "")).upper() in DEAD_INVOICE_STATUSES:
            continue
        texts = [inv.get("reference") or ""] + [
            li.get("description") or "" for li in inv.get("line_items") or []]
        if any(pat.search(t) for t in texts):
            hits.append(inv)
    return hits


def xero_invoices_for_ticket(repo: str, number: int | str) -> list[dict] | None:
    """Query Xero via the billing bridge. None = bridge unreachable/failed
    (caller falls back to label-only), [] = genuinely no invoice."""
    try:
        import urllib.request
        token = Path("/etc/billing-bridge/token").read_text().strip()
        req = urllib.request.Request(
            BRIDGE_URL, method="POST",
            data=json.dumps({"script": "xero-invoice",
                             "argv": ["query", f"--ref=#{number}", f"--repo={repo}"]}).encode(),
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=8) as r:
            resp = json.loads(r.read().decode())
        if resp.get("exit_code") != 0:
            return None
        return matching_invoices(resp.get("stdout", ""), number)
    except Exception:
        return None


def uninvoiced_deployed_tickets(repo: str) -> list[dict]:
    """Mirrors billing-invoice SKILL.md's 'Finding all uninvoiced tickets'
    recipe (label is the cheap prefilter), then cross-checks each unlabelled
    ticket against Xero. Each returned issue carries "xero":
      "none"     — no invoice found: really unbilled (blocks)
      "invoiced" — invoice exists, only the `invoiced` label is missing
      "unknown"  — bridge down; treated as unbilled, today's label-only behaviour
    """
    try:
        out = subprocess.run(
            ["gh", "issue", "list", "--repo", repo, "--label", "has been deployed live",
             "--state", "closed", "--json", "number,title,labels"],
            capture_output=True, text=True, timeout=20, check=True,
        )
        issues = json.loads(out.stdout or "[]")
    except Exception:
        return []
    unlabelled = [i for i in issues
                  if not any(l.get("name", "").lower() == "invoiced" for l in i.get("labels", []))]
    bridge_up = True
    for i in unlabelled:
        found = xero_invoices_for_ticket(repo, i["number"]) if bridge_up else None
        if found is None:
            bridge_up = False  # one failure = outage; don't stack timeouts
            i["xero"] = "unknown"
        else:
            i["xero"] = "invoiced" if found else "none"
            if found:
                i["invoices"] = [f"{v.get('invoice_number')} {v.get('status')}" for v in found]
    return unlabelled


def split_by_xero(tickets: list[dict]) -> tuple[list[dict], list[dict]]:
    """(unbilled, invoiced_but_unlabelled)."""
    return ([t for t in tickets if t.get("xero") != "invoiced"],
            [t for t in tickets if t.get("xero") == "invoiced"])


def format_label_fix(repo: str, labelled_missing: list[dict]) -> str:
    lines = [f"  #{t['number']} {t['title']} — {', '.join(t.get('invoices', []))}"
             for t in labelled_missing]
    nums = " ".join(str(t["number"]) for t in labelled_missing)
    return (f"{len(labelled_missing)} ticket(s) already invoiced in Xero but missing the "
            f"`invoiced` GitHub label (label drift, not unbilled work):\n" + "\n".join(lines)
            + f"\nFix: one call per ticket — gh issue edit <N> --repo {repo} --add-label invoiced  (N in: {nums})")


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


def _cwd_key(cwd: str) -> str:
    return re.sub(r"[^A-Za-z0-9_-]", "_", cwd.strip("/"))


def state_path_for_cwd(cwd: str) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    return STATE_DIR / f"{_cwd_key(cwd)}.json"


def bypass_marker_path(cwd: str) -> Path:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    return STATE_DIR / f"{_cwd_key(cwd)}.bypass-once"


def consume_bypass_once(cwd: str) -> bool:
    """One-shot mid-session escape hatch for billing-precompact-guard's manual
    /compact block. BILLING_COMPACT_ALLOWED=1 only works if set BEFORE the
    session starts (env vars can't change mid-session) — too heavy for a
    non-critical reminder gate you just want past right now. Create the
    marker with `bash ~/claude-skills-central/scripts/billing-bypass-once.sh`
    (or the project-mounted /var/www/html/.claude/scripts/ path) from inside
    the blocked project; this consumes (deletes) it so the next real manual
    compact is gated again — it's a "just this once" pass, not a standing
    off switch. Silent no-op (never raises) if the marker isn't there."""
    p = bypass_marker_path(cwd)
    try:
        if p.exists():
            p.unlink()
            return True
    except Exception:
        pass
    return False
