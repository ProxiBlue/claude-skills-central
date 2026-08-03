#!/bin/bash
# dep-audit.sh — daily composer-advisory watch for in-scope projects (AP-5).
#
# Runs `composer audit --locked` (host composer, reads composer.lock + the
# packagist advisory DB — no container needed) for every project in
# host/tooling-scope.txt that has a lock file. Alerts ONLY on CHANGES: a new
# advisory set (vs the stored state) posts a chatroom thread; a clean or
# unchanged state stays silent. CVEs appear asynchronously — they are news,
# not a gate; blocking commits on them would punish the wrong event.
#
# State: ~/monitor/dep-audit/<project>.sha  (hash of the advisory list)
# Exit: 0 always unless the audit infrastructure itself broke (composer
# missing) — advisory findings are alerts, not job failures.

set -u
SCOPE="$HOME/claude-skills-central/host/tooling-scope.txt"
STATE="$HOME/monitor/dep-audit"; mkdir -p "$STATE"
CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"

command -v composer >/dev/null 2>&1 || { echo "dep-audit: composer not on host"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "dep-audit: jq missing"; exit 1; }

# project name -> repo dir. Dir names don't always match project names
# (lcd-mageos lives in ittools/lcdscreen_mageos), so grep the ddev configs.
resolve_dir() {
  local name="$1" cfg
  for cfg in "$HOME/workspace"/*/.ddev/config.yaml "$HOME/workspace"/*/*/.ddev/config.yaml; do
    [ -f "$cfg" ] || continue
    if grep -q "^name: $name\$" "$cfg" 2>/dev/null; then
      dirname "$(dirname "$cfg")"; return
    fi
  done
}

alert_chatroom() {  # <subject> <body>
  curl -sS -X POST "${CHATROOM_URL}/api/threads" \
    -H "Content-Type: application/json" \
    -H "X-PB-Chatroom-Participant: host-auto" \
    -d "$(python3 -c "import json,sys;print(json.dumps({'to':'host','subject':sys.argv[1],'body':sys.argv[2],'discussion_type':'escalation'}))" "$1" "$2")" \
    >/dev/null 2>&1
}

checked=0; alerted=0
while IFS= read -r proj; do
  case "$proj" in ''|\#*) continue ;; esac
  dir=$(resolve_dir "$proj")
  [ -z "$dir" ] && { echo "[$proj] dir not resolved — skipped"; continue; }
  [ -f "$dir/composer.lock" ] || { echo "[$proj] no composer.lock — skipped"; continue; }

  out=$(cd "$dir" && composer audit --locked --format=json 2>/dev/null)
  if [ -z "$out" ]; then
    # host composer may lack private-repo auth (e.g. wyomind on pps) — the
    # container has the auth.json, so fall back to running audit in there.
    out=$(cd "$dir" && timeout 120 ddev exec composer audit --locked --format=json </dev/null 2>/dev/null | sed -n '/^{/,$p')
  fi
  # infrastructure hiccup (network etc.) → skip quietly, try again tomorrow
  [ -z "$out" ] && { echo "[$proj] audit produced no output (host+container) — skipped"; continue; }

  advisories=$(echo "$out" | jq -c '[.advisories // {} | to_entries[]
      | .key as $pkg | .value[] | {pkg: $pkg, id: (.advisoryId // .cve // .title)}]
      | sort_by(.pkg + (.id|tostring))' 2>/dev/null)
  [ -z "$advisories" ] && advisories='[]'
  count=$(echo "$advisories" | jq length)
  new_hash=$(echo "$advisories" | sha1sum | cut -d' ' -f1)
  old_hash=$(cat "$STATE/$proj.sha" 2>/dev/null || echo none)

  checked=$((checked+1))
  if [ "$new_hash" != "$old_hash" ]; then
    echo "$new_hash" > "$STATE/$proj.sha"
    if [ "$count" -gt 0 ]; then
      detail=$(echo "$out" | jq -r '.advisories | to_entries[] |
        .key as $pkg | .value[] | "- \($pkg): \(.title // .cve // .advisoryId) [\(.severity // "?")]"' 2>/dev/null | head -15)
      alert_chatroom "Dependency advisories: $proj ($count)" \
"composer audit found $count advisory(ies) in $proj (changed since last run):

$detail

Check: cd $dir && composer audit --locked
Fix: update the affected package(s) on a feature branch; advisory clears on next run."
      alerted=$((alerted+1))
      echo "[$proj] $count advisories — ALERTED"
    elif [ "$old_hash" = "none" ]; then
      echo "[$proj] first run — seeded clean (0 advisories)"
    else
      echo "[$proj] advisories cleared (now 0)"
    fi
  else
    echo "[$proj] unchanged ($count advisories)"
  fi
done < <(grep -vE '^\s*(#|$)' "$SCOPE")

echo "dep-audit: $checked project(s) checked, $alerted alert(s)"
