#!/usr/bin/env python3
"""PreCompact hook — billing-context-guard.

manual /compact: BLOCKS (exit 2) if the current project has GitHub tickets
that are closed + deployed-live + not yet labeled "invoiced" — same
deterministic ground truth billing-invoice's own docs already use. Bypass
with BILLING_COMPACT_ALLOWED=1 (same pattern as merge-guard.sh's
CLAUDE_MERGE_ALLOWED=1, but only takes effect if set BEFORE the session
starts) for a compact unrelated to those tickets, or — for a mid-session
"just let me through right now" — run
scripts/billing-bypass-once.sh from the blocked project first; it's a
one-shot marker, consumed by the very compact it clears.

auto compact: NEVER blocks — blocking auto-compaction after it already hit
the context limit surfaces a raw API error to the user, worse than the
problem this hook exists to prevent. Silent side-effect only: if commits in
this session touch a still-OPEN ticket (ongoing, not yet invoice-ready),
write a graphiti bridge note so billing time-estimation detail survives the
compact even though nothing is shown to the user.

Silent no-op for any non-billing-tracked project (no billing-bridge token).
"""
import json
import os
import sys
from pathlib import Path

# Relative to this file, not a hardcoded container path — hooks/ and scripts/
# are siblings under .claude/ both in the container mount and on the host
# (claude-skills-central/), so this resolves correctly in both. The old
# hardcoded "/var/www/html/.claude/scripts" crashed with ModuleNotFoundError
# outside a container running this exact mount layout, before
# billing_bridge_configured() ever got a chance to gate it out — an
# unconditional top-level import can't be gated after the fact.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from billing_context_lib import (  # noqa: E402
    billing_bridge_configured,
    consume_bypass_once,
    current_repo,
    open_tickets_touched_this_session,
    project_id,
    uninvoiced_deployed_tickets,
    write_bridge_note,
)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()
    trigger = payload.get("trigger", "auto")
    os.chdir(cwd)

    if not billing_bridge_configured():
        sys.exit(0)

    repo = current_repo()
    if not repo:
        sys.exit(0)
    proj_id = project_id(repo)

    open_tickets = open_tickets_touched_this_session(cwd)
    if open_tickets:
        write_bridge_note(cwd, proj_id, open_tickets, trigger=f"precompact-{trigger}")

    if trigger != "manual":
        sys.exit(0)

    if os.environ.get("BILLING_COMPACT_ALLOWED") == "1":
        sys.exit(0)

    if consume_bypass_once(cwd):
        sys.exit(0)

    uninvoiced = uninvoiced_deployed_tickets(repo)
    if not uninvoiced:
        sys.exit(0)

    lines = [f"  #{i['number']} {i['title']}" for i in uninvoiced]
    print(
        "BLOCKED by billing-context-guard\n\n"
        f"{len(uninvoiced)} ticket(s) deployed + closed but not yet invoiced in {repo}:\n"
        + "\n".join(lines)
        + "\n\nInvoice these first, or bypass right now with:\n"
          "  bash ~/claude-skills-central/scripts/billing-bypass-once.sh\n"
          "(one-shot, just for this compact) — or export BILLING_COMPACT_ALLOWED=1 "
          "before starting a session if this'll come up repeatedly.",
        file=sys.stderr,
    )
    sys.exit(2)


if __name__ == "__main__":
    main()
