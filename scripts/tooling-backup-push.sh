#!/usr/bin/env bash
# Nightly backup-push of all central Claude tooling repos.
# Every aspect of the fleet tooling must survive an HD crash (requirement 2026-07-30).
# Commits are checkpoint commits — history noise is acceptable, data loss is not.
set -u

REPOS=(
  "$HOME/claude-skills-central"
  "$HOME/claude-plugins-central"
  "$HOME/claude-code-magento-agents"
  "$HOME/.claude/projects/-home-lucas/memory"
  "$HOME/claude-plugins-central/seed/marketplaces/pb-chatroom"
  "$HOME/claude-plugins-central/seed/marketplaces/pb-codegraph"
  "$HOME/claude-plugins-central/seed/marketplaces/pb-graphiti"
  "$HOME/claude-plugins-central/seed/marketplaces/pb-hcf"
  "$HOME/claude-plugins-central/seed/marketplaces/proxiblue-skills/skills"
)

STAMP=$(date +%Y-%m-%d)
LOG="$HOME/monitor/tooling-backup.log"
mkdir -p "$(dirname "$LOG")"

for repo in "${REPOS[@]}"; do
  [ -d "$repo/.git" ] || { echo "$STAMP SKIP $repo (no .git)" >> "$LOG"; continue; }
  cd "$repo" || continue
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "auto-backup $STAMP" || true
  fi
  if [ -n "$(git log --oneline @{u}..HEAD 2>/dev/null)" ]; then
    if git push -q 2>>"$LOG"; then
      echo "$STAMP PUSHED $repo" >> "$LOG"
    else
      echo "$STAMP PUSH-FAILED $repo" >> "$LOG"
    fi
  fi
done
