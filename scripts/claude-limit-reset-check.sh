#!/usr/bin/env bash
# claude-limit-reset-check.sh — surface Claude Code usage-limit reset grants
# ("cedar_ember" in the CLI) so they are not missed.
#
# Read-only. Never claims a reset; that stays manual via `/limit-reset`.
#
# Usage:
#   --json              full cached status (raw cedar_ember + derived summary)
#   --line [--pct N]    one short statusline token, or nothing when no reset
#                       is available. With --pct N (weekly %) the network is
#                       only hit when N >= LIMIT_RESET_REFRESH_MIN_PCT (80) or
#                       when there is no cache at all; otherwise cache only.
#   --startup           SessionStart hook: emits systemMessage +
#                       additionalContext JSON when a reset is available.
#   --refresh           force a network fetch, print summary line.
#
# Env:
#   CLAUDE_CONFIG_DIR            where .credentials.json lives (default ~/.claude)
#   LIMIT_RESET_TTL              cache TTL seconds (default 600)
#   LIMIT_RESET_REFRESH_MIN_PCT  weekly % at which --line refreshes (default 80)
#   LIMIT_RESET_FIXTURE          path to a JSON file used instead of the API (tests)
#   LIMIT_RESET_CACHE            cache file override
set -u
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

CFG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CREDS="$CFG_DIR/.credentials.json"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-limit-reset"
CACHE="${LIMIT_RESET_CACHE:-$CACHE_DIR/status.json}"
TTL="${LIMIT_RESET_TTL:-600}"
MIN_PCT="${LIMIT_RESET_REFRESH_MIN_PCT:-80}"
URL="https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1"
NOW=$(date +%s)

mode="--line"; pct=""; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json|--line|--startup) mode="$1" ;;
    --refresh) mode="--refresh"; force=1 ;;
    --pct) shift; pct="${1:-}" ;;
    *) ;;
  esac
  shift
done

cli_version() {
  local v
  v=$(claude --version 2>/dev/null | awk '{print $1}')
  printf '%s' "${v:-0.0.0}"
}

fetch() {
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null || return 1
  local body tmp
  if [ -n "${LIMIT_RESET_FIXTURE:-}" ]; then
    body=$(cat "$LIMIT_RESET_FIXTURE" 2>/dev/null) || return 1
  else
    [ -r "$CREDS" ] || return 1
    local tok exp
    tok=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
    exp=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS" 2>/dev/null)
    [ -n "$tok" ] || return 1
    # expiresAt is ms; skip when expired — the CLI refreshes it on its own.
    [ "${exp%???}" -gt "$NOW" ] 2>/dev/null || return 1
    body=$(curl -sS -m 8 \
      -H "Authorization: Bearer $tok" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "x-app: cli" \
      -H "anthropic-client-platform: $(uname -s | tr 'A-Z' 'a-z')" \
      -H "User-Agent: claude-cli/$(cli_version) (external, cli)" \
      -H "Content-Type: application/json" \
      "$URL" 2>/dev/null) || return 1
  fi
  printf '%s' "$body" | jq -e '.cedar_ember | type == "object"' >/dev/null 2>&1 || return 1
  tmp="$CACHE.tmp.$$"
  printf '%s' "$body" | jq --arg now "$NOW" '{fetched_at: ($now|tonumber),
      seven_day: .seven_day, five_hour: .five_hour, cedar_ember: .cedar_ember}' \
    > "$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE"
}

cache_age() {
  [ -r "$CACHE" ] || { echo 999999; return; }
  local f
  f=$(jq -r '.fetched_at // 0' "$CACHE" 2>/dev/null)
  echo $(( NOW - ${f:-0} ))
}

# Decide whether to hit the network.
age=$(cache_age)
want_fetch=0
if [ "$force" -eq 1 ]; then want_fetch=1
elif [ ! -r "$CACHE" ]; then want_fetch=1
elif [ "$age" -ge "$TTL" ]; then
  case "$mode" in
    --line)
      # Statusline hot path: only refresh when weekly usage is high.
      if [ -z "$pct" ] || [ "${pct%.*}" -ge "$MIN_PCT" ] 2>/dev/null; then want_fetch=1; fi ;;
    *) want_fetch=1 ;;
  esac
fi
[ "$want_fetch" -eq 1 ] && fetch
[ -r "$CACHE" ] || exit 0

# Derived summary. A grant counts as available when it has resets left, is not
# paused, and has not ended. `usable_now` is the server's own verdict for this
# instant (false when use_requires_limit and you are not at a limit).
summary=$(jq -c --arg now "$NOW" '
  def ts: if . == null then null else (sub("\\.[0-9]+";"") | sub("\\+00:00$";"Z") | fromdateiso8601) end;
  .cedar_ember as $c
  | [ ($c.grants // [])[]
      | select(.resets_left > 0 and (.paused|not) and ((.ends_at|ts) == null or (.ends_at|ts) > ($now|tonumber))) ] as $avail
  | {
      eligible: ($c.eligible // false),
      ineligible_reason: $c.ineligible_reason,
      at_limit: ($c.at_limit // false),
      weekly_pct: (.seven_day.utilization // null),
      session_pct: (.five_hour.utilization // null),
      weekly_resets_at: $c.weekly_resets_at,
      available: ($avail|length > 0),
      resets_left: ([$avail[].resets_left] | add // 0),
      usable_now: ([$avail[].usable_now] | any),
      anytime: ([$avail[] | (.use_requires_limit|not)] | any),
      use_by: ([$avail[].ends_at] | map(select(. != null)) | min),
      clears: ([$avail[].clears[]] | unique),
      labels: [$avail[].label],
      spent_grants: [ ($c.grants // [])[] | select(.resets_left == 0) | .id ]
    }' "$CACHE" 2>/dev/null) || exit 0

fmt_date() {  # ISO -> "22 Oct"
  local iso="${1:-}"; [ -n "$iso" ] && [ "$iso" != "null" ] || { printf ''; return; }
  date -d "$iso" '+%-d %b' 2>/dev/null || printf '%s' "${iso%%T*}"
}

avail=$(printf '%s' "$summary" | jq -r '.available')
left=$(printf '%s' "$summary" | jq -r '.resets_left')
use_by=$(fmt_date "$(printf '%s' "$summary" | jq -r '.use_by // empty')")
anytime=$(printf '%s' "$summary" | jq -r '.anytime')
wk=$(printf '%s' "$summary" | jq -r '.weekly_pct // empty')
clears=$(printf '%s' "$summary" | jq -r '.clears | join("+")')
when="at limit"; [ "$anytime" = "true" ] && when="anytime"

case "$mode" in
  --json)
    jq --argjson s "$summary" '. + {summary: $s}' "$CACHE" ;;
  --line)
    [ "$avail" = "true" ] || exit 0
    printf '⟲ reset avail ×%s · /limit-reset%s' "$left" "${use_by:+ · by $use_by}" ;;
  --refresh)
    if [ "$avail" = "true" ]; then
      printf 'reset available: %s left, usable %s, refills %s, use by %s (weekly %s%%)\n' \
        "$left" "$when" "$clears" "${use_by:-?}" "${wk:-?}"
    else
      printf 'no reset available (weekly %s%%, spent: %s)\n' "${wk:-?}" \
        "$(printf '%s' "$summary" | jq -r '.spent_grants | join(",") | if .=="" then "none" else . end')"
    fi ;;
  --startup)
    [ "$avail" = "true" ] || exit 0
    msg=$(printf 'Usage-limit reset available: %s left, usable %s, refills %s, use by %s. Weekly at %s%%. Run /limit-reset to claim (manual only).' \
      "$left" "$when" "$clears" "${use_by:-?}" "${wk:-?}")
    jq -n --arg m "$msg" '{systemMessage: $m,
      hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: ("[limit-reset] " + $m + " Do not claim it yourself; remind the user when weekly usage is high.")}}' ;;
esac
exit 0
