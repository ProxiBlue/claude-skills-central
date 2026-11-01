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
# Alert channel (2026-11-01, Lucas: "rather than a pb chat, raise tickets for
# work per project"): when the project's origin remote is a GitHub repo and
# `gh` is authenticated, the advisory set becomes ONE open issue per project
# titled "Dependency advisories: <proj> (<n>)". A changed set edits that issue
# in place (+ a minimized comment), a cleared set closes it. The chatroom
# thread is the FALLBACK only — no GitHub remote, gh unauthenticated, or the
# API call failed. Set DEP_AUDIT_TICKETS=0 to force chatroom-only.
# gh auth under cron: GH_TOKEN is not in cron's env; if unset, the token is
# read from $DEP_AUDIT_GH_TOKEN_FILE (default ~/.config/gh/dep-audit-token).
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

# GitHub repo (owner/name) from the project's origin remote; empty when the
# remote is not on github.com or the dir is not a git checkout.
resolve_repo() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  printf '%s\n' "$url" | sed -nE 's#^(git@|https?://|ssh://git@)github\.com[:/]([^/]+/[^/]+)/?$#\2#p' | sed -E 's/\.git$//'
}

# One open issue per project. Finds it by title prefix (open issues only, so
# a closed/cleared one never gets reopened — a fresh set gets a fresh issue).
find_ticket() {  # <repo> <proj>  -> issue number or ''
  gh issue list -R "$1" --state open --limit 20 \
     --search "\"Dependency advisories: $2\" in:title" --json number,title 2>/dev/null \
   | jq -r --arg p "Dependency advisories: $2" '[.[] | select(.title | startswith($p))][0].number // empty' 2>/dev/null
}

ticket_comment() {  # <repo> <number> <body>  — caveman, minimized (gh-ticket-comments rule)
  local helper="$HOME/claude-skills-central/scripts/gh-comment-hidden.sh"
  if [ -x "$helper" ]; then "$helper" "$1" "$2" "$3" >/dev/null 2>&1
  else gh issue comment "$2" -R "$1" --body "$3" >/dev/null 2>&1; fi
}

gh_ready() {
  [ "${DEP_AUDIT_TICKETS:-1}" != "0" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  if [ -z "${GH_TOKEN:-}" ]; then
    local tf="${DEP_AUDIT_GH_TOKEN_FILE:-$HOME/.config/gh/dep-audit-token}"
    [ -r "$tf" ] && GH_TOKEN=$(head -1 "$tf") && export GH_TOKEN
  fi
  gh auth status >/dev/null 2>&1
}

# Open-or-update the project's advisory issue. Prints the issue URL on
# success; returns 1 (caller falls back to chatroom) on any failure.
alert_ticket() {  # <proj> <repo> <count> <toolname> <detail> <check>
  local proj="$1" repo="$2" count="$3" tool="$4" detail="$5" check="$6" num url title body
  title="Dependency advisories: $proj ($count)"
  body="$tool found $count advisory(ies) in $proj (auto: dep-audit, $(date +%F)).

$detail

Check: $check
Fix: bump affected package(s) on feature branch, re-run audit clean, normal test-gate + UAT.
Issue auto-updates when advisory set changes; auto-closes when audit clean."
  num=$(find_ticket "$repo" "$proj")
  if [ -n "$num" ]; then
    gh issue edit "$num" -R "$repo" --title "$title" --body "$body" >/dev/null 2>&1 || return 1
    ticket_comment "$repo" "$num" "Updated. Advisory set changed: now $count. See issue body." || true
    url="https://github.com/$repo/issues/$num"
  else
    url=$(gh issue create -R "$repo" --title "$title" --body "$body" 2>/dev/null) || return 1
    case "$url" in https://*) ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$url"
}

close_ticket() {  # <proj> <repo>  — audit clean: close the open issue if any
  local num; num=$(find_ticket "$2" "$1")
  [ -n "$num" ] || return 0
  ticket_comment "$2" "$num" "Done. Audit clean on $(date +%F); auto-closed by dep-audit." || true
  gh issue close "$num" -R "$2" >/dev/null 2>&1 && echo "https://github.com/$2/issues/$num"
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
      repo=$(resolve_repo "$dir"); ticket_url=""
      if [ -n "$repo" ] && gh_ready; then
        ticket_url=$(alert_ticket "$proj" "$repo" "$count" "$TOOLNAME" "$detail" "$CHECK") || ticket_url=""
      fi
      if [ -n "$ticket_url" ]; then
        # ticket is the record now; retire any older chatroom copy for this project
        retire="$HOME/claude-skills-central/scripts/chatroom-retire-superseded.sh"
        [ -x "$retire" ] && "$retire" "Dependency advisories: $proj" >/dev/null 2>&1 || true
        alerted=$((alerted+1))
        echo "[$proj] $count advisories — TICKET $ticket_url"
      else
      alert_chatroom "Dependency advisories: $proj ($count)" \
"$TOOLNAME found $count advisory(ies) in $proj (changed since last run):

$detail

Check: $CHECK
Fix: update the affected package(s) on a feature branch; advisory clears on next run." \
        "Dependency advisories: $proj"
      alerted=$((alerted+1))
      echo "[$proj] $count advisories — ALERTED"
      fi
    elif [ "$old_hash" = "none" ]; then
      echo "[$proj] first run — seeded clean (0 advisories)"
    else
      closed=""
      repo=$(resolve_repo "$dir")
      if [ -n "$repo" ] && gh_ready; then closed=$(close_ticket "$proj" "$repo"); fi
      echo "[$proj] advisories cleared (now 0)${closed:+ — CLOSED $closed}"
    fi
  else
    echo "[$proj] unchanged ($count advisories)"
  fi
done < <(grep -vE '^\s*(#|$)' "$SCOPE")

echo "dep-audit: $checked project(s) checked, $alerted alert(s)"
