#!/bin/bash
# dep-audit.sh — daily dependency-advisory watch for in-scope projects (AP-5).
#
# Branches on the project's manifest:
#   composer.lock                         -> `composer audit --locked` (host
#                                            composer, packagist advisory DB)
#   uv.lock / pyproject.toml / requirements*.txt -> pip-audit (PyPI advisory
#                                            DB): `uv run pip-audit` when uv.lock,
#                                            else .venv/bin/pip-audit, else
#                                            pip-audit on PATH, else `pipx run`.
#                                            Not installed -> skipped with a note.
# for every project in host/tooling-scope.txt. Alerts ONLY on CHANGES: a new
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

alert_chatroom() {  # <subject> <body> [retire-prefix]
  local resp tid
  resp=$(curl -sS -X POST "${CHATROOM_URL}/api/threads" \
    -H "Content-Type: application/json" \
    -H "X-PB-Chatroom-Participant: host-auto" \
    -d "$(python3 -c "import json,sys;print(json.dumps({'to':'host','subject':sys.argv[1],'body':sys.argv[2],'discussion_type':'escalation'}))" "$1" "$2")" \
    2>/dev/null)
  # An advisory report for a project supersedes the previous one FOR THAT
  # PROJECT -- the prefix is per-project so lcd-mageos's report never closes
  # pvcpipesupplies's. Same advisory set re-reported weekly is noise, not news.
  local retire="$HOME/claude-skills-central/scripts/chatroom-retire-superseded.sh"
  tid=$(printf '%s' "$resp" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('id',''))
except Exception: print('')" 2>/dev/null)
  if [ -n "${3:-}" ] && [ -x "$retire" ] && [ -n "$tid" ]; then
    "$retire" "$3" "$tid" >/dev/null 2>&1 || true
  fi
}

# Python projects: pip-audit, JSON on stdout. Sets $out, $advisories,
# $PY_AUDIT_CMD. Returns 1 (caller skips) when no pip-audit is available or
# it produced nothing parseable. pip-audit exits 1 when it FINDS vulns, so
# its exit code is ignored — only its JSON counts.
py_audit() {
  local dir="$1" req=""
  PY_AUDIT_CMD=""; out=""
  for r in "$dir"/requirements.txt "$dir"/requirements*.txt; do [ -f "$r" ] && { req="${r##*/}"; break; }; done
  if [ -f "$dir/uv.lock" ] && command -v uv >/dev/null 2>&1; then
    PY_AUDIT_CMD="uv run --frozen pip-audit -f json"
    out=$(cd "$dir" && timeout 300 uv run --frozen pip-audit -f json </dev/null 2>/dev/null)
  fi
  if [ -z "$out" ] && [ -x "$dir/.venv/bin/pip-audit" ]; then
    PY_AUDIT_CMD=".venv/bin/pip-audit -f json"
    out=$(cd "$dir" && timeout 300 .venv/bin/pip-audit -f json </dev/null 2>/dev/null)
  fi
  if [ -z "$out" ]; then
    local pa=""
    if command -v pip-audit >/dev/null 2>&1; then pa="pip-audit"
    elif command -v pipx >/dev/null 2>&1; then pa="pipx run pip-audit"; fi
    if [ -n "$pa" ]; then
      if [ -n "$req" ]; then PY_AUDIT_CMD="$pa -r $req -f json"
      else PY_AUDIT_CMD="$pa -f json ."; fi
      out=$(cd "$dir" && timeout 300 $PY_AUDIT_CMD </dev/null 2>/dev/null)
    fi
  fi
  if [ -z "$PY_AUDIT_CMD" ]; then
    echo "[$proj] Python project but pip-audit unavailable (install: uv tool install pip-audit) — skipped"
    return 1
  fi
  out=$(printf '%s\n' "$out" | sed -n '/^[[{]/,$p')
  if [ -z "$out" ] || ! echo "$out" | jq -e . >/dev/null 2>&1; then
    echo "[$proj] pip-audit produced no parseable output — skipped"
    return 1
  fi
  advisories=$(echo "$out" | jq -c '[(if type == "array" then . else (.dependencies // []) end)[]
      | .name as $pkg | (.vulns // [])[] | {pkg: $pkg, id: .id}]
      | sort_by(.pkg + (.id|tostring))' 2>/dev/null)
  return 0
}

checked=0; alerted=0
while IFS=" 	" read -r proj _stack; do
  case "$proj" in ''|\#*) continue ;; esac
  dir=$(resolve_dir "$proj")
  [ -z "$dir" ] && { echo "[$proj] dir not resolved — skipped"; continue; }
  if [ -f "$dir/composer.lock" ]; then
    KIND=composer
  elif [ -f "$dir/uv.lock" ] || [ -f "$dir/pyproject.toml" ] || ls "$dir"/requirements*.txt >/dev/null 2>&1; then
    KIND=python
  else
    echo "[$proj] no composer.lock / Python manifest — skipped"; continue
  fi

  if [ "$KIND" = "python" ]; then
    py_audit "$dir" || continue
  else
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
  fi
  [ -z "$advisories" ] && advisories='[]'
  count=$(echo "$advisories" | jq length)
  new_hash=$(echo "$advisories" | sha1sum | cut -d' ' -f1)
  old_hash=$(cat "$STATE/$proj.sha" 2>/dev/null || echo none)

  checked=$((checked+1))
  if [ "$new_hash" != "$old_hash" ]; then
    echo "$new_hash" > "$STATE/$proj.sha"
    if [ "$count" -gt 0 ]; then
      if [ "$KIND" = "python" ]; then
        detail=$(echo "$out" | jq -r '(if type == "array" then . else (.dependencies // []) end)[]
          | .name as $pkg | .version as $v | (.vulns // [])[]
          | "- \($pkg) \($v): \(.id)\(if (.aliases // []) | length > 0 then " (" + ((.aliases) | join(", ")) + ")" else "" end) fix: \((.fix_versions // []) | join(", ") | if . == "" then "none" else . end)"' 2>/dev/null | head -15)
        TOOLNAME="pip-audit"; CHECK="cd $dir && $PY_AUDIT_CMD"
      else
        detail=$(echo "$out" | jq -r '.advisories | to_entries[] |
          .key as $pkg | .value[] | "- \($pkg): \(.title // .cve // .advisoryId) [\(.severity // "?")]"' 2>/dev/null | head -15)
        TOOLNAME="composer audit"; CHECK="cd $dir && composer audit --locked"
      fi
      alert_chatroom "Dependency advisories: $proj ($count)" \
"$TOOLNAME found $count advisory(ies) in $proj (changed since last run):

$detail

Check: $CHECK
Fix: update the affected package(s) on a feature branch; advisory clears on next run." \
        "Dependency advisories: $proj"
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
