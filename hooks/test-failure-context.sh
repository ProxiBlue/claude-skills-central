#!/bin/bash
# PostToolUse Bash hook — just-in-time investigation protocol injection.
#
# When a test-runner command fails, injects the compact investigation
# protocol (hooks/investigation-context.md) into context AT THE FAILURE
# MOMENT — full attention weight, instead of a session-start rule diluted
# 100k tokens ago. Replaces always-loading rules/reference/investigation.md (kept
# as on-demand reference; a trigger line in the global core points at it
# for non-test failures like user bug reports).
#
# SCOPE LIMIT (discovered 2026-08-01, claude-code v2.1.198 payload probe):
# PostToolUse Bash fires ONLY for exit-0 commands. A failing test run
# (non-zero exit) never reaches this hook, so this catches ONLY
# masked-exit cases: `runner | tee log`, `runner; echo done`, or runners
# that exit 0 while printing failures. For real non-zero failures the
# agent sees the failure directly in its tool result, and test-gate.sh
# blocks any commit — the protocol pointer also lives in core-triggers.
#
# Fires when BOTH:
#   - command looks like a test run (phpunit/pest/playwright/jest/etc.)
#   - output contains failure markers
# Debounced: at most once per 10 min per session (marker in /tmp) so a
# red->red->green loop doesn't re-inject every run.
#
# Per-project opt-out: line `test-failure-context` in
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op on any parse failure. Never blocks
# (PostToolUse, exit 0 always).

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

echo "$CMD" | grep -qE '(phpunit|paratest|pest|codecept|playwright|vitest|jest|npm[[:space:]]+(run[[:space:]]+)?test|yarn[[:space:]]+test|bin/magento[[:space:]]+dev:tests)' || exit 0

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'test-failure-context' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

OUT=$(echo "$INPUT" | jq -r '(.tool_response | if type == "object" then (.stdout // .output // "") else tostring end) // ""' 2>/dev/null)
[ -z "$OUT" ] && exit 0

echo "$OUT" | grep -qE '(FAILURES!|ERRORS!|Tests?[^a-zA-Z]*failed|[1-9][0-9]*[[:space:]]+failed|AssertionError|✘|✗)' || exit 0

# Debounce: once per 10 min per claude process
STAMP="/tmp/claude-invest-inject-$PPID"
if [ -f "$STAMP" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt 600 ] && exit 0
fi
touch "$STAMP" 2>/dev/null

CTX="$(dirname "$0")/investigation-context.md"
[ -f "$CTX" ] && cat "$CTX"

exit 0
