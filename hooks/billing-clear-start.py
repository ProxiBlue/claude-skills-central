#!/usr/bin/env python3
"""SessionStart hook (matcher "clear") — billing-context-guard, half 2 of 2.

Reads the state file billing-clear-end.py wrote for this cwd (if any),
prints a visible heads-up (SessionStart is one of the few events where exit-0
stdout is actually shown), then deletes the state file — one-shot, doesn't
repeat on the next SessionStart if nothing new happened.
"""
import json
import os
import sys

sys.path.insert(0, "/var/www/html/.claude/scripts")
from billing_context_lib import state_path_for_cwd  # noqa: E402


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    cwd = payload.get("cwd") or os.getcwd()
    p = state_path_for_cwd(cwd)
    if not p.exists():
        sys.exit(0)

    try:
        data = json.loads(p.read_text())
    except Exception:
        p.unlink(missing_ok=True)
        sys.exit(0)
    p.unlink(missing_ok=True)

    tickets = data.get("tickets", [])
    if not tickets:
        sys.exit(0)

    lines = [f"  #{t['number']} {t['title']}" for t in tickets]
    print(
        f"billing-context-guard: {len(tickets)} deployed-but-uninvoiced ticket(s) in "
        f"{data.get('repo')} from before this /clear:\n" + "\n".join(lines)
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
