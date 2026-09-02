#!/bin/bash
# PreToolUse Edit|Write hook — enforces the PHP echo-debugging ban mechanically:
#
#   No var_dump / print_r / dd() / dump() / ray() / xdebug_break() /
#   debug-only error_log() added to PHP source. Use the xdebug-mcp tools
#   instead (xstep / xtrace / xprofile / xcoverage / xback / xcompare).
#
# Replaces the "Banned edits" section of rules/reference/php-debugging.md as prose
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
  echo "Xdebug/pcov default OFF fleet-wide in both FPM and CLI (see" >&2
  echo "rules/reference/xdebug-pcov-defaults.md) — that is NOT a reason to" >&2
  echo "fall back to var_dump/print_r. Load it on demand instead:" >&2
  echo "" >&2
  echo "  Bug is in a CLI script (phpunit, a cron/queue worker invoked" >&2
  echo "  directly, any xdebug-mcp tool call)? Nothing to do — xtrace/" >&2
  echo "  xstep/xprofile/xcoverage already self-heat (XdebugFinder in the" >&2
  echo "  plugin auto-adds -dzend_extension=xdebug to that one invocation" >&2
  echo "  when it's not loaded; CLI is a fresh process per call, zero" >&2
  echo "  restart cost). Just run the tool." >&2
  echo "" >&2
  echo "  Bug only reproduces on a live page load (e.g. something a" >&2
  echo "  Playwright test is driving, over FPM/nginx)? FPM is a persistent" >&2
  echo "  daemon — loading xdebug there needs a real restart, and you are" >&2
  echo "  running INSIDE this container with no 'ddev' binary or Docker" >&2
  echo "  socket, so the host-only 'ddev xdebug on' will not work here." >&2
  echo "  Use the in-container bracket instead (mounted fleet-wide," >&2
  echo "  read-only, at .claude/scripts/):" >&2
  echo "    .claude/scripts/xdebug-fpm-session.sh on   # loads it, arms a" >&2
  echo "                                                # 900s auto-off safety" >&2
  echo "    <drive the page load, use xdebug-mcp tools against the live" >&2
  echo "     DBGp connection on port 9003>" >&2
  echo "    .claude/scripts/xdebug-fpm-session.sh off  # turn it back off —" >&2
  echo "                                                # do this before any" >&2
  echo "                                                # real E2E/Playwright" >&2
  echo "                                                # batch runs" >&2
  echo "" >&2
  echo "Tool genuinely can't reach the code path at all (e.g. an" >&2
  echo "unattended cron/queue worker you cannot invoke interactively)?" >&2
  echo "Say so to the user before falling back. Genuine production use of" >&2
  echo "this function? Ask the user — they can add 'php-debug-guard' to" >&2
  echo ".claude/rules-disable." >&2
  echo "Full reference: rules/reference/php-debugging.md (claude-skills-central)." >&2
  exit 2
fi

exit 0
