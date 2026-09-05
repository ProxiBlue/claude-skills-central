#!/bin/bash
# PreToolUse Bash hook — traps the narrow Magento cache-clear form
#   rm -rf generated/code/* generated/metadata/*
# (with or without a /var/www/html/ prefix, either subdir alone or both) and
# redirects to the simpler, equally-safe form:
#   rm -rf generated/*
#
# Why: generated/ only ever holds code/ and metadata/ in a Magento install,
# so clearing the two subdirs individually buys nothing over clearing the
# whole directory in one shot. Lucas asked (2026-09-05) to standardize on
# the single-command form fleet-wide rather than keep repeating the longer
# one. Both forms are pre-authorized in settings.json permissions.allow —
# this hook is about which one Claude actually reaches for, not about
# permission (deterministic redirect > relying on the agent to remember a
# prose preference, see rules/feedback_deterministic_hooks.md).
#
# Per-project opt-out: add the line `magento-generated-clear-guard` to
# <repo>/.claude/rules-disable.
#
# Defensive: NO set -e. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$CMD" ] && exit 0

# Per-project opt-out
TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$TOPLEVEL" ] && [ -f "$TOPLEVEL/.claude/rules-disable" ]; then
  grep -qx 'magento-generated-clear-guard' "$TOPLEVEL/.claude/rules-disable" 2>/dev/null && exit 0
fi

# Matches `rm -rf <opt prefix>generated/code` or `.../generated/metadata`,
# with or without a trailing /* — either subdir alone is enough to trigger,
# since the fix is the same regardless of whether one or both are named.
PATTERN='rm[[:space:]]+-rf[[:space:]]+([^ ]*/)?generated/(code|metadata)([/*]|[[:space:]]|$)'

if echo "$CMD" | grep -qE "$PATTERN"; then
  echo "BLOCKED by magento-generated-clear-guard.sh: narrow generated/ clear in:" >&2
  echo "  $CMD" >&2
  echo "" >&2
  echo "generated/ only ever holds code/ and metadata/ in a Magento install —" >&2
  echo "clear the whole thing in one shot instead:" >&2
  echo "  rm -rf generated/* (or /var/www/html/generated/* with an absolute path)" >&2
  echo "Both forms are already pre-authorized, no permission prompt needed." >&2
  exit 2
fi

exit 0
