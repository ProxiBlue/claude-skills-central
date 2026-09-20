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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP=$(date +%Y-%m-%d)
LOG="$HOME/monitor/tooling-backup.log"
mkdir -p "$(dirname "$LOG")"

# A blocked backup must be impossible to miss. This script already has form
# for silent failure: pb-graphiti's stale index.lock hid a 9-day backup gap
# (2026-09-08) purely because nothing announced it. A credential block stops
# backups for that repo until a human acts, so it opens a chatroom thread
# rather than only appending to a log nobody reads.
#
# The findings are "<file>:<line>: <pattern-name>" -- never the matched text,
# so this message cannot itself become the leak.
alert() {
  local repo=$1 where=$2 findings=$3
  command -v curl >/dev/null 2>&1 || return 0
  local body
  body=$(printf 'BACKUP BLOCKED — credential-shaped content in %s\n\nRepo: %s\nWhere: %s\n\nFindings (file:line: pattern — values deliberately not shown):\n%s\n\nThis repo was NOT committed and NOT pushed. Backups stay blocked for it until this is resolved.\n\nFix: move the secret out of the working tree (env file, password manager). If it is a genuine false positive, add a narrow regex to %s/.secret-scan-allow with a comment.\n\nBackground: scripts/secret-scan.sh, added after the 2026-09-19 Bugsink leak.' \
    "$where" "$repo" "$where" "$findings" "$repo")
  curl -s -m 10 -X POST "http://127.0.0.1:7476/api/threads" \
    -H "X-PB-Chatroom-Participant: host-auto" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import json,sys
print(json.dumps({'subject':'BACKUP BLOCKED: possible credential in '+sys.argv[1],
                  'recipients':['host'],'body':sys.argv[2]}))" "$(basename "$repo")" "$body")" \
    >/dev/null 2>&1 || true
}

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
  # Credential gate. claude-skills-central is deliberately public (the blog
  # deep-links its hooks and rules), and this loop is a `git add -A` straight
  # to a remote -- so whatever sits in the working tree is published within
  # the hour, reviewed by nobody. On 2026-09-19 that path published a Bugsink
  # superuser password and Django SECRET_KEY, then published a scratch file
  # containing those same values hours later during the cleanup.
  #
  # Scan BEFORE staging. A finding skips this repo entirely -- no commit, no
  # push -- and leaves the working tree untouched for a human to fix.
  if [ -n "$(git status --porcelain)" ]; then
    if ! SCAN_OUT=$("$SCRIPT_DIR/secret-scan.sh" --worktree "$repo" 2>&1); then
      echo "$STAMP SECRET-BLOCKED $repo: $(echo "$SCAN_OUT" | tr '\n' ' ')" >> "$LOG"
      alert "$repo" "uncommitted" "$SCAN_OUT"
      continue
    fi
    git add -A
    if ! COMMIT_ERR=$(git commit -q -m "auto-backup $STAMP" 2>&1); then
      echo "$STAMP COMMIT-FAILED $repo: $(echo "$COMMIT_ERR" | tr '\n' ' ')" >> "$LOG"
      continue
    fi
  fi
  if [ -n "$(git log --oneline @{u}..HEAD 2>/dev/null)" ]; then
    # Second gate: a secret can already be sitting in an unpushed commit --
    # from a hand commit, or from a run of this script that predates the gate.
    # Blocking only new work would let exactly that case through.
    if ! SCAN_OUT=$("$SCRIPT_DIR/secret-scan.sh" --range "$repo" '@{u}..HEAD' 2>&1); then
      echo "$STAMP SECRET-BLOCKED-PUSH $repo: $(echo "$SCAN_OUT" | tr '\n' ' ')" >> "$LOG"
      alert "$repo" "unpushed commits" "$SCAN_OUT"
      continue
    fi
    if git push -q 2>>"$LOG"; then
      echo "$STAMP PUSHED $repo" >> "$LOG"
    else
      echo "$STAMP PUSH-FAILED $repo" >> "$LOG"
    fi
  fi
done
