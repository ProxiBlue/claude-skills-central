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
# 2026-10-13 widened (pvcpipesupplies #517, chat ec6e0e84): ANY partial wipe
# of a generated/ subdir is trapped, not just `rm -rf generated/code|metadata`:
# rm with any flags/args order (-r, -fr, -Rf, --recursive, multi-arg), find
# ... -delete / -exec rm, and php unlink loops. A partial wipe that leaves
# generated/metadata/*.php behind makes Magento keep the stale compiled DI
# (preferred over reflection even in developer mode) -> "Argument #N not
# passed" on every runtime after a constructor change. Whole dir, first resort.
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

# Any partial wipe of a generated/<sub>: rm (any flags, any arg position),
# find ... -delete / -exec rm, php unlink. `generated/*` itself never matches
# (the char after generated/ must be a name char, not `*`).
SEP='[^;&|]*'
SUB='generated/[A-Za-z0-9_]'
PATTERN="(^|[^A-Za-z0-9_-])rm[[:space:]]${SEP}(^|[[:space:]/'\"])${SUB}|(^|[^A-Za-z0-9_-])find[[:space:]]${SEP}${SUB}${SEP}(-delete|-exec[[:space:]]+rm)|unlink${SEP}${SUB}|${SUB}${SEP}unlink"

if echo "$CMD" | grep -qE "$PATTERN"; then
  echo "BLOCKED by magento-generated-clear-guard.sh: partial generated/ wipe in:" >&2
  echo "  $CMD" >&2
  echo "" >&2
  echo "A partial wipe leaves stale compiled DI in generated/metadata, which Magento" >&2
  echo "prefers over reflection even in developer mode (-> 'Argument #N not passed')." >&2
  echo "Wipe the WHOLE dir, first resort, then clean cache:" >&2
  echo "  rm -rf generated/* && bin/magento cache:clean" >&2
  echo "  (or /var/www/html/generated/* with an absolute path)" >&2
  echo "Both forms are already pre-authorized, no permission prompt needed." >&2
  exit 2
fi

exit 0
