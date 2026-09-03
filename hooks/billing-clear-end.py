#!/usr/bin/env python3
"""SessionEnd hook (matcher "clear") — billing-context-guard, half 1 of 2.

/clear has no pre-hook (cannot block), so this pair reacts instead: SessionEnd
fires as the old session ends, computes the same deterministic uninvoiced
check + graphiti bridge-write as PreCompact, and persists any uninvoiced
finding to a small state file. billing-clear-start.py (SessionStart, matcher
"clear") reads and displays it right after the new session opens — that's
the one place in this hook family where exit-0 stdout is actually shown to
the user (SessionStart is one of the three exceptions to "exit 0 = silent").

Silent no-op for any non-billing-tracked project.
"""
import json
import os
import sys
from pathlib import Path

# Relative to this file — see billing-precompact-guard.py for the full
# rationale (hooks/ and scripts/ are siblings under .claude/ in both the
# container mount and the host repo; the old hardcoded container path
# crashed with ModuleNotFoundError anywhere else, before
# billing_bridge_configured() got a chance to gate it out).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from billing_context_lib import (  # noqa: E402
    billing_bridge_configured,
    current_repo,
    open_tickets_touched_this_session,
    project_id,
    state_path_for_cwd,
    uninvoiced_deployed_tickets,
    write_bridge_note,
)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()
    os.chdir(cwd)

    if not billing_bridge_configured():
        sys.exit(0)

    repo = current_repo()
    if not repo:
        sys.exit(0)
    proj_id = project_id(repo)

    open_tickets = open_tickets_touched_this_session(cwd)
    if open_tickets:
        write_bridge_note(cwd, proj_id, open_tickets, trigger="clear")

    uninvoiced = uninvoiced_deployed_tickets(repo)
    if uninvoiced:
        state_path_for_cwd(cwd).write_text(json.dumps({
            "repo": repo,
            "tickets": [{"number": i["number"], "title": i["title"]} for i in uninvoiced],
        }))

    sys.exit(0)


if __name__ == "__main__":
    main()
