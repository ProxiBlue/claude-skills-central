#!/bin/bash
# Weekly fleet drift telemetry — runs fleet-inventory.sh, diffs the
# CONFIG-relevant fields against the previous baseline, and opens a
# pb-chatroom thread (identity host-auto -> host) ONLY when drift exists.
#
# Rec #4 (tooling review 2026-07-31): first standing telemetry. Converts the
# phase-0 inventory from a one-shot audit into a recurring drift alarm.
#
# Comparison EXCLUDES work-noise: branch, dirty count, run status, and the
# settings-mount check (only measurable for running containers — reported
# fresh each run instead of diffed). Everything else (pin refs, pipeline.md,
# wires, dangling refs, mounts, stubs, AGENT_TEAMS, markers, gate config)
# is config state and diffs cleanly.
#
# Usage: fleet-drift-check.sh [--dry-run]
#   --dry-run: print what would be posted; do not POST, do not roll baseline.
#
# State: ~/monitor/fleet-inventory/ (snapshots kept 90 days + baseline.txt)

set -u
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SNAPDIR="$HOME/monitor/fleet-inventory"
mkdir -p "$SNAPDIR"
STAMP=$(date +%Y-%m-%d-%H%M)
RAW="$SNAPDIR/fleet-$STAMP.txt"
BASELINE="$SNAPDIR/baseline.txt"
IDENTITY="host-auto"
CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"

bash "$SCRIPT_DIR/fleet-inventory.sh" > "$RAW" 2>/dev/null
[ -s "$RAW" ] || { echo "[$(date -Iseconds)] inventory produced no output — aborting"; exit 1; }

# Normalize: keep project name + config fields only
# In-scope allowlist — only these projects count as drift (the rest are
# non-Magento / archived / not-yet-needing the tooling). Missing file = all.
SCOPE_FILE="$HOME/claude-skills-central/host/tooling-scope.txt"
in_scope() {
  [ -f "$SCOPE_FILE" ] || return 0
  grep -qxF "$1" <(grep -vE '^\s*#|^\s*$' "$SCOPE_FILE")
}

normalize() {
  awk '
    /^=== / { split($0, a, " \\| "); sub(/^=== /, "", a[1]); proj=a[1]; next }
    /branch=/ { line=$0; sub(/branch=[^ ]+ /, "", line); sub(/dirty=[0-9]+ \| /, "", line); print proj ": " line; next }
    /settings=/ { line=$0; sub(/ settings=[^ ]*/, "", line); print proj ": " line; next }
    /pipeline\.md=|ai-mounts=|test-gate/ { print proj ": " $0 }
  ' "$1" | sed 's/[[:space:]]\+/ /g' | while IFS= read -r ln; do
    p="${ln%%:*}"; in_scope "$p" && echo "$ln"
  done
}

CURRENT="$SNAPDIR/.current-normalized.txt"
normalize "$RAW" > "$CURRENT"

# Fresh (non-diffed) signal: stale settings mounts right now — in-scope only
STALE_NOW=""
for p in $(grep -B4 'settings=STALE' "$RAW" | grep '^=== ' | sed 's/^=== //; s/ |.*//'); do
  in_scope "$p" && STALE_NOW="$STALE_NOW $p"
done
STALE_NOW=$(echo "$STALE_NOW" | sed 's/^ *//')

if [ ! -f "$BASELINE" ]; then
  cp "$CURRENT" "$BASELINE"
  echo "[$(date -Iseconds)] baseline created ($RAW)"
  exit 0
fi

DIFF=$(diff -u "$BASELINE" "$CURRENT")

if [ -z "$DIFF" ] && [ -z "$STALE_NOW" ]; then
  echo "[$(date -Iseconds)] no drift"
  find "$SNAPDIR" -name 'fleet-*.txt' -mtime +90 -delete 2>/dev/null
  exit 0
fi

BODY=$(mktemp)
{
  echo "Fleet drift check $(date +%Y-%m-%d). Config drift vs baseline of $(stat -c %y "$BASELINE" | cut -d' ' -f1):"
  echo ""
  if [ -n "$DIFF" ]; then
    echo '```diff'
    echo "$DIFF" | tail -n +3
    echo '```'
  else
    echo "No config drift."
  fi
  [ -n "$STALE_NOW" ] && { echo ""; echo "Settings mounts STALE right now (need ddev restart): $STALE_NOW"; }
  echo ""
  echo "Full snapshot: $RAW"
  echo "Baseline rolls forward automatically; investigate then ack."
} > "$BODY"

if [ "$DRY" = "1" ]; then
  echo "--- DRY RUN: would post thread 'Fleet drift $(date +%Y-%m-%d)' ---"
  cat "$BODY"
  rm -f "$BODY"
  exit 0
fi

RESPONSE=$(curl -sS -X POST "${CHATROOM_URL}/api/threads" \
  -H "Content-Type: application/json" \
  -H "X-PB-Chatroom-Participant: ${IDENTITY}" \
  -d "$(python3 -c "
import json
with open('$BODY') as f:
    body = f.read()
print(json.dumps({
    'to': 'host',
    'subject': 'Fleet drift $(date +%Y-%m-%d)',
    'body': body,
    'discussion_type': 'postmortem'
}))
")" 2>/dev/null)
THREAD_ID=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('id', 'FAILED'))" 2>/dev/null)
echo "[$(date -Iseconds)] drift detected — posted thread ${THREAD_ID:-FAILED}"

# Roll baseline forward so the same drift doesn't re-alert weekly
cp "$CURRENT" "$BASELINE"
rm -f "$BODY"
find "$SNAPDIR" -name 'fleet-*.txt' -mtime +90 -delete 2>/dev/null
exit 0
