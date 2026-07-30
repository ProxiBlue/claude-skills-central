#!/bin/bash
# Version-aware plugin sync: for each locally-sourced plugin, if the seed
# marketplace ships a newer version than what installed_plugins.json pins,
# materialise the new version into the cache and repoint the manifest.
#
# SAFETY (fleet post-start hook — must never break a container):
#   * copies via tar --exclude=.git (never touches the seed's own .git)
#   * manifest edited through a validated temp file with a backup; on ANY
#     failure the original manifest is restored and the plugin is left on its
#     current version (degrade to no-op, never to broken).
#   * idempotent: same seed version => skip.
#
# Usage: sync-plugin-versions.sh [--dry-run] [SEED_MP_DIR] [PLUGINS_DIR]
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }

SEED_MP_DIR="${1:-/var/www/html/.claude/plugins-seed/marketplaces}"
PLUGINS_DIR="${2:-$HOME/.claude/plugins}"
MANIFEST="$PLUGINS_DIR/installed_plugins.json"

# Plugins to NEVER auto-advance (major upgrades needing manual migration).
# Space-separated; matched against plugin OR marketplace name. Override via env.
EXCLUDE="${PB_PLUGIN_SYNC_EXCLUDE:-hcf}"

command -v jq >/dev/null || { echo "[sync-versions] jq missing; skip"; exit 0; }
[ -f "$MANIFEST" ] || { echo "[sync-versions] no manifest; skip"; exit 0; }
[ -d "$SEED_MP_DIR" ] || { echo "[sync-versions] no seed marketplaces ($SEED_MP_DIR); skip"; exit 0; }

now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || echo 1970-01-01T00:00:00.000Z)"
changed=0

# Iterate manifest plugin keys "<plugin>@<marketplace>".
keys="$(jq -r '.plugins | keys[]' "$MANIFEST" 2>/dev/null)" || exit 0
for key in $keys; do
  plugin="${key%@*}"
  marketplace="${key#*@}"
  # Skip excluded plugins (major upgrades needing manual migration).
  skip=0
  for ex in $EXCLUDE; do
    [ "$ex" = "$plugin" ] || [ "$ex" = "$marketplace" ] && { skip=1; break; }
  done
  [ "$skip" = 1 ] && { echo "[sync-versions] $key: excluded"; continue; }

  seed_pj="$SEED_MP_DIR/$marketplace/.claude-plugin/plugin.json"
  [ -f "$seed_pj" ] || continue          # not a locally-seeded plugin; leave alone
  seed_ver="$(jq -r '.version // empty' "$seed_pj" 2>/dev/null)"
  [ -n "$seed_ver" ] || continue

  # Current user-scope installed version for this plugin.
  cur_ver="$(jq -r --arg k "$key" '.plugins[$k][] | select(.scope=="user") | .version' "$MANIFEST" 2>/dev/null | head -1)"
  [ -n "$cur_ver" ] || continue
  [ "$cur_ver" = "$seed_ver" ] && continue   # already current

  new_dir="$PLUGINS_DIR/cache/$marketplace/$plugin/$seed_ver"
  echo "[sync-versions] $key: $cur_ver -> $seed_ver"
  if [ "$DRY" = 1 ]; then changed=$((changed+1)); continue; fi

  # Materialise the new version dir from the seed (exclude VCS metadata).
  mkdir -p "$new_dir" || { echo "  ! mkdir failed; skip"; continue; }
  if ! tar -C "$SEED_MP_DIR/$marketplace" --exclude='.git' -cf - . 2>/dev/null | tar -C "$new_dir" -xf - 2>/dev/null; then
    echo "  ! copy failed; skip"; continue
  fi

  # Repoint the manifest entry (validated temp + backup + restore-on-fail).
  cp -f "$MANIFEST" "$MANIFEST.bak" 2>/dev/null
  tmp="$MANIFEST.tmp.$$"
  if jq --arg k "$key" --arg ver "$seed_ver" --arg path "$new_dir" --arg ts "$now" '
        .plugins[$k] |= map(
          if .scope=="user"
          then .version=$ver | .installPath=$path | .lastUpdated=$ts
          else . end)
      ' "$MANIFEST" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$MANIFEST"
    changed=$((changed+1))
    echo "  ok -> $new_dir"
  else
    rm -f "$tmp"
    [ -f "$MANIFEST.bak" ] && cp -f "$MANIFEST.bak" "$MANIFEST"
    echo "  ! manifest update failed; restored, left on $cur_ver"
  fi
done

echo "[sync-versions] done ($changed change(s))"
