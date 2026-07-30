#!/bin/bash
# DDEV post-start hook: merge plugins-seed/known_marketplaces.json into the
# project's cached known_marketplaces.json.
#
# Why: Claude Code only imports the seed list on first launch. Once a project
# has any cached known_marketplaces.json, adding new marketplaces to the seed
# (e.g. magento-tdd, hcf-gitnexus, proxiblue-skills) does NOT propagate. This
# script does the merge on every ddev start.
#
# Merge semantics: project entries win on conflict (preserves per-project
# autoUpdate flags and installLocation overrides). Seed entries that don't
# exist in the project are added verbatim.
#
# Safe to run repeatedly. No-op if seed file is missing.

set -e

SEED=/var/www/html/.claude/plugins-seed/known_marketplaces.json
DEST=~/.claude/plugins/known_marketplaces.json

[ -f "$SEED" ] || exit 0

mkdir -p "$(dirname "$DEST")"
[ -f "$DEST" ] || echo '{}' > "$DEST"

jq -s '.[0] * .[1]' "$SEED" "$DEST" > "$DEST.tmp" && mv "$DEST.tmp" "$DEST"

# Version-aware plugin sync: advance any locally-seeded plugin whose seed
# marketplace ships a newer version than installed_plugins.json pins (except
# the exclude-list — majors needing manual migration, default: hcf). Runs in
# its own process; `|| true` guarantees a sync failure never wedges start.
bash "$(dirname "$0")/sync-plugin-versions.sh" || true
