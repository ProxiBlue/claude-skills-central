#!/bin/bash
# PreToolUse Bash hook — blocks hand-rolled waits on background work.
#
# Two banned shapes, one root cause:
#
#   1. Polling loops.   while ! pgrep -f playwright; do sleep 10; done
#                       until [ -f done.marker ]; do sleep 5; done
#   2. Detached launch. npx playwright test ... &     /  nohup ... &
#
# Why: a detached process outlives the tool call that spawned it, so the
# agent loses the exit code and has to guess. Every proxy it can reach for
# fails in the same direction — pgrep/kill -0/marker files report "still
# running" long after a clean exit, or time out silently while the run
# already succeeded. The agent then sits idle believing it is waiting.
# From the outside (ListAgents, ps, file mtimes) that is indistinguishable
# from a hung worker, so nobody notices for an hour.
#
# Live incident 2026-09-18 (chatroom thread 2f0d65cf, worktree
# pvcpipesupplies-491, ticket #491): two hcf:tdd-worker subagents each
# burned ~50min on self-authored pgrep wait loops. Playwright had exited 0
# minutes in; neither poll check noticed. 108 minutes of zero file activity.
#
# The fix is not a better wait loop — it is not backgrounding. Run the
# command in the foreground with the Bash tool's own timeout (max 600000ms),
# and if it does not fit, narrow the run (single spec / --filter / --bail)
# instead of detaching it. Subagents in particular usually declare only
# Read/Write/Edit/Bash/Glob/Grep — no Monitor, no BashOutput, no TaskOutput —
# so for them a detached process is unrecoverable by construction and a poll
# loop is the only move left. Don't put them in that position.
#
# Full rationale: rules/reference/background-tasks.md
#
# Per-project opt-out: add `background-wait-guard` to the repo's
# .claude/rules-disable file.
# One-off bypass for a genuine daemon/server start: CLAUDE_BG_WAIT_ALLOWED=1.
# (Even then, probe readiness — curl --retry-connrefused, a port check — not
# process liveness.)
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

[ "${CLAUDE_BG_WAIT_ALLOWED:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'background-wait-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

explain() { # explain <headline> <line...>
  echo "BLOCKED by background-wait-guard.sh: $1" >&2
  echo "  $CMD" >&2
  echo "" >&2
  shift
  for line in "$@"; do echo "$line" >&2; done
  echo "" >&2
  echo "See rules/reference/background-tasks.md. Starting a real daemon and" >&2
  echo "not a test run? Prefix CLAUDE_BG_WAIT_ALLOWED=1." >&2
  exit 2
}

# --- 1. polling loops --------------------------------------------------------
# Requires a loop keyword AND sleep AND a liveness probe. All three, so
# ordinary retry loops that do real work (curl, bin/magento) are untouched.
LOOP='(^|[;&|[:space:]])(while|until)([[:space:]]|$)'
if echo "$CMD" | grep -qE "$LOOP" && echo "$CMD" | grep -qE '(^|[;&|[:space:]])sleep[[:space:]]'; then

  if echo "$CMD" | grep -qE '(pgrep|pidof|kill[[:space:]]+-0|ps[[:space:]]+(aux|-ef|-p)|/proc/[0-9$])'; then
    explain "process-liveness polling loop." \
      "A dead-or-alive check cannot tell you the exit code, and it reports" \
      "'gone' for a crash exactly as it does for a clean finish. Run the" \
      "command in the foreground and pass the Bash tool's timeout instead" \
      "(max 600000ms). If it will not fit in 10 minutes, narrow it — one" \
      "spec, --filter, --bail — rather than detaching it."
  fi

  if echo "$CMD" | grep -qE '\[\[?[[:space:]]*(!|-e|-f|-s)' \
     || echo "$CMD" | grep -qE '(^|[;&|[:space:]])test[[:space:]]+(!|-e|-f|-s)'; then
    explain "marker-file polling loop." \
      "A marker file appears when the writer decides to write it, not when" \
      "the work ended — and a crash writes nothing, so you wait forever." \
      "Run the command in the foreground and read its real exit code."
  fi
fi

# --- 2. detached launch of a test/build run ----------------------------------
TESTISH='(playwright|phpunit|vendor/bin/(phpunit|phpstan|psalm|pest)|(npm|yarn|pnpm)[[:space:]]+(run[[:space:]]+)?test|jest|vitest|codecept|bin/magento[[:space:]]+dev:tests)'
if echo "$CMD" | grep -qiE "$TESTISH"; then
  if echo "$CMD" | grep -qE '&[[:space:]]*($|[;|)]|[[:space:]]*#)' \
     || echo "$CMD" | grep -qE '(^|[;&|[:space:]])nohup[[:space:]]'; then
    explain "detached test run." \
      "A backgrounded run outlives this tool call and takes its exit code" \
      "with it, leaving you nothing trustworthy to wait on. Run it in the" \
      "foreground with the Bash tool's timeout. Too slow for that? Narrow" \
      "the run — targeted spec first, full suite once it is green. Never" \
      "detach to dodge the timeout."
  fi
fi

exit 0
