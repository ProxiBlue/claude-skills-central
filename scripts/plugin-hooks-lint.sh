#!/bin/bash
# Static lint over every plugin's hooks/hooks.json: flags a shell-form
# "command" hook (a single string, no "args" array) that references
# ${user_config.*}.
#
# Why this exists (2026-09-08 incident): pb-graphiti's SessionEnd/PreCompact/
# TaskCompleted/SessionStart hooks all used:
#   "command": "GRAPHITI_URL=\"${user_config.graphiti_url}\" python3 \"...\""
# A claude-code version bump started rejecting this at hook-fire time — "the
# substituted value would be re-parsed by the shell" — which silently broke
# graph consolidation on every session end. rule-evals.sh (the mandatory
# "before moving the pin" gate) never caught it, because its Phase C
# auto-discovery only runs claude-skills-central/hooks/*.test.sh — our OWN
# PreToolUse/PostToolUse guard scripts. No eval anywhere ever loaded, parsed,
# or exercised a PLUGIN's hooks.json (pb-graphiti, pb-hcf, pb-chatroom, hcf,
# ...). harness-release-watch.sh's changelog-impact summary is an LLM reading
# prose, not a probe against real manifests, so it has no teeth here either.
# This script is the missing check: cheap, deterministic, no LLM, no live
# session — it just has to read files that already exist on disk.
#
# Scans (in order, first that exists wins per invocation — pass explicit
# dirs to scan more than one):
#   $1 (optional): one or more directories to scan for */hooks/hooks.json
#                  (default: the fleet's seeded plugin marketplaces dir)
#
# Exit 0: clean. Exit 1: at least one violation (each printed as
#   "<file> [<event>]: <command>").
#
# Fix for a violation: convert to exec form (add "args": [...] and pass the
# value as a plain argv item instead of a shell env-assignment prefix), or
# have the script read $CLAUDE_PLUGIN_OPTION_<KEY> from its environment.
# See pb-graphiti/hooks/hooks.json (fixed 2026-09-08) for a worked example.
#
# Defensive: NO set -e. Silent no-op (exit 0) if jq missing.

command -v jq >/dev/null 2>&1 || exit 0

DIRS=("$@")
if [ "${#DIRS[@]}" -eq 0 ]; then
  DIRS=("$HOME/claude-plugins-central/seed/marketplaces")
fi

VIOLATIONS=0

for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || continue
  while IFS= read -r -d '' f; do
    hits=$(jq -r '
      (.hooks // {}) | to_entries[] as $e |
      ($e.value[]?.hooks[]?) |
      select(.type == "command") |
      select((.command // "") | test("\\$\\{user_config\\.")) |
      select(has("args") | not) |
      "\($e.key): \(.command)"
    ' "$f" 2>/dev/null)
    if [ -n "$hits" ]; then
      while IFS= read -r line; do
        echo "$f [$line]"
        VIOLATIONS=$((VIOLATIONS + 1))
      done <<< "$hits"
    fi
  done < <(find "$dir" -path '*/hooks/hooks.json' -print0 2>/dev/null)
done

if [ "$VIOLATIONS" -gt 0 ]; then
  echo "" >&2
  echo "$VIOLATIONS shell-form hook(s) reference \${user_config.*} without an" >&2
  echo "\"args\" array — newer claude-code builds reject these at hook-fire" >&2
  echo "time (re-parse-by-shell risk). Convert to exec form: {\"command\":" >&2
  echo "\"<executable>\", \"args\": [\"\${user_config.KEY}\", ...]}." >&2
  exit 1
fi

exit 0
