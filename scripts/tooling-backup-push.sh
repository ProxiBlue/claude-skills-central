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
  # A stale index.lock (from a previous interrupted git op, e.g. a crashed
  # cron overlap) makes `git commit` fail every night with the failure
  # swallowed below — silently, for as long as the lock sits there (found
  # 2026-09-08: pb-graphiti's lock from 2026-09-02 hid a 9-day backup gap,
  # invisible because commit failures were never logged at all). If nothing
  # else holds it (fuser check), it's orphaned — remove it so this run
  # doesn't join the silent-failure streak, and say so in the log.
  if [ -f "$repo/.git/index.lock" ] && ! fuser "$repo/.git/index.lock" >/dev/null 2>&1; then
    echo "$STAMP STALE-LOCK-REMOVED $repo ($(stat -c %y "$repo/.git/index.lock" 2>/dev/null))" >> "$LOG"
    rm -f "$repo/.git/index.lock"
  fi
  if [ -n "$(git status --porcelain)" ]; then
    git add -A
    if ! COMMIT_ERR=$(git commit -q -m "auto-backup $STAMP" 2>&1); then
      echo "$STAMP COMMIT-FAILED $repo: $(echo "$COMMIT_ERR" | tr '\n' ' ')" >> "$LOG"
      continue
    fi
  fi
  if [ -n "$(git log --oneline @{u}..HEAD 2>/dev/null)" ]; then
    if git push -q 2>>"$LOG"; then
      echo "$STAMP PUSHED $repo" >> "$LOG"
    else
      echo "$STAMP PUSH-FAILED $repo" >> "$LOG"
    fi
  fi
done
