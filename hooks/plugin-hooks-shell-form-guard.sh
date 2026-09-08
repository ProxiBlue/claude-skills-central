#!/bin/bash
# PostToolUse Edit|Write hook — informational, fires the moment any plugin's
# hooks/hooks.json is written, if it now contains a shell-form "command" hook
# referencing ${user_config.*} (no "args" array).
#
# Why: 2026-09-08 incident — pb-graphiti's SessionEnd/PreCompact/
# TaskCompleted/SessionStart hooks used exactly this anti-pattern for months.
# A claude-code version bump started rejecting it at hook-fire time ("the
# substituted value would be re-parsed by the shell"), silently breaking
# graph consolidation on every session end. rule-evals.sh's mandatory
# "before moving the pin" gate never caught it because nothing in it ever
# touched a plugin's hooks.json (fixed: see scripts/plugin-hooks-lint.sh,
# wired as rule-evals eval 9). That fix only closes the gap at PIN-MOVE time;
# this hook closes it at AUTHORING time, same "catch it now, not diluted
# later" reasoning as hook-needs-eval-check.sh.
#
# Non-blocking (informational, like hook-needs-eval-check.sh / post-commit-
# wiki-check.sh) — editing a hooks.json is not itself destructive, and the
# fix (convert to exec form) is a one-line follow-up edit, not a redo.
#
# Per-project opt-out: line `plugin-hooks-shell-form-guard` in
# <repo>/.claude/rules-disable. (This only matters for someone editing a
# hooks.json from inside a plugin-repo checkout that has its own .claude/;
# the fleet's own seed edits have no such repo, so this basically never
# needs opting out in practice.)
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

F=$(echo "$INPUT" | jq -r '.tool_input.file_path // .file_path // ""' 2>/dev/null)
[ -z "$F" ] && exit 0

case "$F" in
  */hooks/hooks.json) ;;
  *) exit 0 ;;
esac

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'plugin-hooks-shell-form-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

[ -f "$F" ] || exit 0

HITS=$(jq -r '
  (.hooks // {}) | to_entries[] as $e |
  ($e.value[]?.hooks[]?) |
  select(.type == "command") |
  select((.command // "") | test("\\$\\{user_config\\.")) |
  select(has("args") | not) |
  "\($e.key): \(.command)"
' "$F" 2>/dev/null)

[ -z "$HITS" ] && exit 0

echo "[plugin-hooks-shell-form-guard] $F just landed with a shell-form" >&2
echo "\"command\" hook referencing \${user_config.*} — newer claude-code" >&2
echo "builds reject this at hook-fire time (\"the substituted value would" >&2
echo "be re-parsed by the shell\"). Fix now, before it ships silently broken:" >&2
echo "" >&2
echo "$HITS" >&2
echo "" >&2
echo "Convert to exec form: {\"command\": \"<executable>\", \"args\":" >&2
echo "[\"\${user_config.KEY}\", ...]} — see pb-graphiti/hooks/hooks.json" >&2
echo "(fixed 2026-09-08) for a worked example. Or have the script read" >&2
echo "\$CLAUDE_PLUGIN_OPTION_<KEY> from its environment instead." >&2

exit 0
