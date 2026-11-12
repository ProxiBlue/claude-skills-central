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
# Scopes advanced: every `user` entry, plus `project` entries whose projectPath
# is this container's project (PB_PLUGIN_SYNC_PROJECT, default /var/www/html).
# Before 2026-11-12 only `user` was advanced, so a container whose plugins were
# all installed project-scope (ahhgg) silently froze on its first-install
# versions while reporting "0 change(s)".
#
# Usage: sync-plugin-versions.sh [--dry-run] [SEED_MP_DIR] [PLUGINS_DIR]
set -u

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }

SEED_MP_DIR="${1:-/var/www/html/.claude/plugins-seed/marketplaces}"
PLUGINS_DIR="${2:-$HOME/.claude/plugins}"
MANIFEST="$PLUGINS_DIR/installed_plugins.json"

# Plugins never auto-advanced ACROSS a major version (major upgrades need manual
# migration, e.g. hcf 1.x -> 2.x). Same-major bumps (2.0.0 -> 2.0.1) still
# advance. Space-separated; matched against plugin OR marketplace name. Env override.
EXCLUDE="${PB_PLUGIN_SYNC_EXCLUDE:-hcf}"
PROJECT_PATH="${PB_PLUGIN_SYNC_PROJECT:-/var/www/html}"
major() { echo "${1%%.*}"; }

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
  seed_pj="$SEED_MP_DIR/$marketplace/.claude-plugin/plugin.json"
  [ -f "$seed_pj" ] || continue          # not a locally-seeded plugin; leave alone
  seed_ver="$(jq -r '.version // empty' "$seed_pj" 2>/dev/null)"
  [ -n "$seed_ver" ] || continue

  # Installed versions in the scopes we manage (user + this project's project scope).
  vers="$(jq -r --arg k "$key" --arg pp "$PROJECT_PATH" '
      .plugins[$k][] | select(.scope=="user" or (.scope=="project" and .projectPath==$pp)) | .version
    ' "$MANIFEST" 2>/dev/null | sort -u)"
  [ -n "$vers" ] || continue
  stale="$(echo "$vers" | grep -vxF "$seed_ver" || true)"
  [ -n "$stale" ] || continue                # every managed entry already current

  # Excluded plugins: advance only within the same major.
  excluded=0
  for ex in $EXCLUDE; do
    { [ "$ex" = "$plugin" ] || [ "$ex" = "$marketplace" ]; } && { excluded=1; break; }
  done
  if [ "$excluded" = 1 ]; then
    cross="$(for v in $stale; do [ "$(major "$v")" = "$(major "$seed_ver")" ] || echo "$v"; done)"
    if [ -n "$cross" ]; then
      echo "[sync-versions] $key: excluded ($(echo $cross | tr ' ' ',') -> $seed_ver crosses a major; migrate by hand)"
      continue
    fi
  fi

  new_dir="$PLUGINS_DIR/cache/$marketplace/$plugin/$seed_ver"
  echo "[sync-versions] $key: $(echo $stale | tr ' ' ',') -> $seed_ver"
  if [ "$DRY" = 1 ]; then changed=$((changed+1)); continue; fi

  # Materialise the new version dir from the seed (exclude VCS metadata).
  mkdir -p "$new_dir" || { echo "  ! mkdir failed; skip"; continue; }
  if ! tar -C "$SEED_MP_DIR/$marketplace" --exclude='.git' -cf - . 2>/dev/null | tar -C "$new_dir" -xf - 2>/dev/null; then
    echo "  ! copy failed; skip"; continue
  fi

  # Repoint the managed manifest entries (validated temp + backup + restore-on-fail).
  # Excluded plugins only reach here when no managed entry crosses a major.
  cp -f "$MANIFEST" "$MANIFEST.bak" 2>/dev/null
  tmp="$MANIFEST.tmp.$$"
  if jq --arg k "$key" --arg ver "$seed_ver" --arg path "$new_dir" --arg ts "$now" --arg pp "$PROJECT_PATH" '
        .plugins[$k] |= map(
          if (.scope=="user" or (.scope=="project" and .projectPath==$pp)) and .version != $ver
          then .version=$ver | .installPath=$path | .lastUpdated=$ts
          else . end)
      ' "$MANIFEST" > "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$MANIFEST"
    changed=$((changed+1))
    echo "  ok -> $new_dir"
  else
    rm -f "$tmp"
    [ -f "$MANIFEST.bak" ] && cp -f "$MANIFEST.bak" "$MANIFEST"
    echo "  ! manifest update failed; restored, left on $(echo $stale | tr ' ' ',')"
  fi
done

echo "[sync-versions] done ($changed change(s))"
