#!/bin/bash
# PreToolUse Edit|Write hook — enforces the PHP echo-debugging ban mechanically:
#
#   No var_dump / print_r / dd() / dump() / ray() / xdebug_break() /
#   debug-only error_log() added to PHP source. Use the xdebug-mcp tools
#   instead (xstep / xtrace / xprofile / xcoverage / xback / xcompare).
#
# Replaces the "Banned edits" section of rules/php-debugging.md as prose
# (file kept as on-demand reference for the tool-selection table).
#
# Blocks (exit 2): Edit/Write adding a banned call to a .php/.phtml file.
# Allows: edits that REMOVE such calls (only added lines are scanned),
#         non-PHP files, and projects that opted out.
#
# Per-project opt-out: add the line `php-debug-guard` to
# <repo>/.claude/rules-disable. Genuine production use of one of these
# functions: ask the user; they can opt the project out or make the edit.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
case "$FILE" in
  *.php|*.phtml) ;;
  *) exit 0 ;;
esac

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'php-debug-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

# Only the text being ADDED (Edit: new_string; Write: content)
NEW=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // ""' 2>/dev/null)
[ -z "$NEW" ] && exit 0

PATTERN='(var_dump|print_r|var_export|xdebug_break|ray)[[:space:]]*\(|(^|[^a-zA-Z0-9_$>])(dd|dump)[[:space:]]*\('

if echo "$NEW" | grep -qE "$PATTERN"; then
  MATCH=$(echo "$NEW" | grep -oE "$PATTERN" | head -1)
  echo "BLOCKED by php-debug-guard.sh: adding '$MATCH' to $FILE" >&2
  echo "" >&2
  echo "RULE: no echo-debugging in PHP source. Use xdebug-mcp instead:" >&2
  echo "  value at line N, why?        -> xstep --break='<file>:<line>'" >&2
  echo "  how did execution get here?  -> xback / xtrace" >&2
  echo "  flow of request/script?      -> xtrace" >&2
  echo "  why slow?                    -> xprofile" >&2
  echo "  is this line even reached?   -> xcoverage" >&2
  echo "  two inputs diverge where?    -> xcompare" >&2
  echo "" >&2
  echo "Xdebug not loaded? 'ddev xdebug on' first. Tool genuinely can't" >&2
  echo "reach the code path (cron/queue worker)? Say so to the user before" >&2
  echo "falling back. Genuine production use of this function? Ask the user" >&2
  echo "— they can add 'php-debug-guard' to .claude/rules-disable." >&2
  echo "Full reference: rules/php-debugging.md (claude-skills-central)." >&2
  exit 2
fi

exit 0
