#!/bin/bash
# DDEV post-start hook: make sure the container's user settings carry the
# plugin userConfig values fleet plugins need, without touching anything else.
#
# Why: pb-graphiti's MCP url is `${user_config.graphiti_url}`, a value Claude
# Code only asks for when the plugin is enabled interactively. Central
# settings.json enables pb-graphiti for every container, so a fresh container
# (no prior interactive enable) starts with the variable unresolved and the
# graphiti MCP fails to load ("errors loading graphiti url" — ihop 2026-10-21).
#
# Semantics: only fills keys that are MISSING or empty. An existing value
# (e.g. a project pointing graphiti somewhere else) always wins.
#
# Usage: seed-plugin-config.sh [settings-file]   (default ~/.claude/settings.json)
# Safe to run repeatedly. Needs jq.

set -e

DEST="${1:-$HOME/.claude/settings.json}"
GRAPHITI_URL="${PB_GRAPHITI_URL:-http://host.docker.internal:8765/mcp}"

command -v jq >/dev/null || { echo "seed-plugin-config: jq missing, skipped" >&2; exit 0; }

mkdir -p "$(dirname "$DEST")"
[ -s "$DEST" ] || echo '{}' > "$DEST"

TMP="$(mktemp)"
if ! jq --arg url "$GRAPHITI_URL" '
    .pluginConfigs["pb-graphiti@pb-graphiti"].options.graphiti_url |= (if (. // "") == "" then $url else . end)
  ' "$DEST" > "$TMP"; then
  rm -f "$TMP"; echo "seed-plugin-config: $DEST is not valid JSON, left untouched" >&2; exit 0
fi
if cmp -s "$TMP" "$DEST"; then rm -f "$TMP"; exit 0; fi
cat "$TMP" > "$DEST"; rm -f "$TMP"
echo "seed-plugin-config: seeded pb-graphiti graphiti_url in $DEST"
