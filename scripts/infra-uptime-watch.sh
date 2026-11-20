#!/bin/bash
# infra-uptime-watch.sh — down alerts for the error tracker (Bugsink), the log
# store (VictoriaLogs behind its tenant proxy) and the host MCP that AI agents
# read logs through.
#
# Runs every 5 min (crontab -> `monitor.sh uptime`). Each check is a small
# state machine in $STATE_DIR/<check>: alert after FAIL_AFTER consecutive
# failures (one blip is not an outage), re-alert every RENOTIFY_SECS while it
# stays down, one "recovered" alert when it comes back. Every check that goes
# down in the same run is batched into ONE notify_alert (desktop + email +
# alerts.log + dashboard), so a dead droplet is one alert, not ten.
#
# Checks — every host comes from host-local config (this repo is public):
#   bugsink-http           GET $BUGSINK_URL/health/ready == 200 "OK"
#   bugsink-ingest-<p>-<e> header-only envelope POST for every *_PROD / *_UAT
#                          DSN in $BUGSINK_ENV. Bugsink checks installation
#                          AND project quota before it reads any item, so
#                          200 = up and accepting, 429 = quota exhausted (every
#                          event is being dropped), and no event is created.
#   logs-<p>-<e>           LogsQL count over the last MAXAGE with that tenant's
#                          read token. HTTP 000/5xx = store or proxy down
#                          (remaining tenants skipped); 403 = token not mapped
#                          to a tenant; 0 rows = shipper stalled / site silent.
#                          Auto-discovers every LOGS_R_<PROJ>_<ENV> in
#                          $LOGS_TOKENS, so an onboarded project is watched
#                          with no edit here. A tenant with no real rows in
#                          PENDING_WINDOW (30d) is "pending" (minted, shipper
#                          not live yet): skipped, listed, never alerted.
#                          source=pb_probe rows (manual probes) never count.
#   logs-mcp               $LOGS_MCP_URL answers 200 (the AI read path)
#   tls-bugsink, tls-logs  cert valid for >= TLS_MIN_DAYS (checked hourly)
#
# Config ($PB_UPTIME_CFG, default ~/.config/pb-uptime/config.env):
#   BUGSINK_URL=https://bugsink.example.com
#   LOGS_URL=https://logs.example.com
#   LOGS_MCP_URL=http://127.0.0.1:8081/          (optional; unset = skip)
#   BUGSINK_ENV=~/.pb-hcf/bugsink.env             (BUGSINK_DSN_* lines)
#   LOGS_TOKENS=~/.config/pb-logs/tokens.env      (LOGS_R_* lines)
#   LOGS_MAXAGE_PROD=30m  LOGS_MAXAGE_UAT=6h  LOGS_MAXAGE_<PROJ>_<ENV>=...
#
# Exit 0 whenever the checks ran: service state travels via alerts, not rc
# (monitor.sh run_job alerts on any rc != 0 with no cooldown, which would
# re-alert every 5 min). A broken config is reported as a failing check
# through the same state machine, for the same reason.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/notify-lib.sh"

CFG="${PB_UPTIME_CFG:-$HOME/.config/pb-uptime/config.env}"
STATE_DIR="${PB_UPTIME_STATE:-$HOME/monitor/uptime}"
mkdir -p "$STATE_DIR"

if [ -r "$CFG" ]; then
  # shellcheck disable=SC1090
  . "$CFG"
fi
BUGSINK_ENV="${BUGSINK_ENV:-$HOME/.pb-hcf/bugsink.env}"
LOGS_TOKENS="${LOGS_TOKENS:-$HOME/.config/pb-logs/tokens.env}"
BUGSINK_ENV="${BUGSINK_ENV/#\~/$HOME}"
LOGS_TOKENS="${LOGS_TOKENS/#\~/$HOME}"
FAIL_AFTER="${FAIL_AFTER:-2}"
RENOTIFY_SECS="${RENOTIFY_SECS:-21600}"
TLS_MIN_DAYS="${TLS_MIN_DAYS:-14}"
TLS_EVERY_SECS="${TLS_EVERY_SECS:-3600}"
CURL_MAX="${CURL_MAX:-20}"
PENDING_WINDOW="${PENDING_WINDOW:-30d}"

exec 9>"$STATE_DIR/.lock"
flock -n 9 || { echo "uptime: previous run still going, skipped"; exit 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NOW=$(date +%s)
DOWN=(); UP=(); FAILED=(); PENDING=(); OKS=0

fmt_dur() {
  local s=$1
  if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d$((s % 86400 / 3600))h"
  elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h$((s % 3600 / 60))m"
  else echo "$((s / 60))m"; fi
}
num() { [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo 0; }
lower() { echo "$1" | tr 'A-Z_' 'a-z-'; }

# record <check> <ok|fail|skip> [detail]
record() {
  local name="$1" res="$2" detail="${3:-}" f="$STATE_DIR/$1"
  local status="" fails=0 since=0 last=0
  [ -f "$f" ] && read -r status fails since last < "$f"
  fails=$(num "$fails"); since=$(num "$since"); last=$(num "$last")
  case "$res" in
    skip) return ;;
    ok)
      OKS=$((OKS + 1))
      [ "$last" -gt 0 ] && UP+=("$name: back after $(fmt_dur $((NOW - since)))")
      echo "ok 0 0 0" > "$f" ;;
    fail)
      [ "$fails" -eq 0 ] && since=$NOW
      fails=$((fails + 1))
      FAILED+=("$name")
      if [ "$fails" -ge "$FAIL_AFTER" ] &&
         { [ "$last" -eq 0 ] || [ $((NOW - last)) -ge "$RENOTIFY_SECS" ]; }; then
        DOWN+=("$name: $detail (failing since $(date -d "@$since" '+%a %d %b %H:%M'), ${fails} checks)")
        last=$NOW
      fi
      echo "fail $fails $since $last" > "$f" ;;
  esac
}

# http <curl args...> -> prints the status code ("000" = no HTTP response);
# body in $TMP/body, transport error in $TMP/err
http() {
  : > "$TMP/body"; : > "$TMP/err"
  curl -sS -o "$TMP/body" -w '%{http_code}' --connect-timeout 10 -m "$CURL_MAX" "$@" 2>"$TMP/err" || true
}
errline() { head -c 120 "$TMP/err" | tr '\n' ' '; }

# value of KEY=... in an env file, quotes stripped, last assignment wins
env_val() { sed -n "s/^$2=//p" "$1" | tail -1 | sed -E "s/^[\"']//; s/[\"']\$//"; }

check_bugsink() {
  if [ -z "${BUGSINK_URL:-}" ]; then
    record bugsink-http fail "BUGSINK_URL not set in $CFG"; return
  fi
  local code down=""
  code=$(http "$BUGSINK_URL/health/ready")
  if [ "$code" = 200 ] && grep -q '^OK' "$TMP/body"; then record bugsink-http ok
  else record bugsink-http fail "health/ready HTTP $code $(errline)"; down=1; fi

  if [ ! -r "$BUGSINK_ENV" ]; then
    record bugsink-config fail "DSN file $BUGSINK_ENV not readable"; return
  fi
  record bugsink-config ok
  local v dsn key base id name
  for v in $(grep -oE '^BUGSINK_DSN_[A-Z0-9_]+_(PROD|UAT)=' "$BUGSINK_ENV" | tr -d '=' | sort -u); do
    name="bugsink-ingest-$(lower "${v#BUGSINK_DSN_}")"
    [ -n "$down" ] && { record "$name" skip; continue; }
    dsn=$(env_val "$BUGSINK_ENV" "$v")
    key=$(sed -E 's#^https?://([^@:]+)[^@]*@.*#\1#' <<<"$dsn")
    base=$(sed -E 's#^(https?://)[^@]+@([^/]+)/.*#\1\2#' <<<"$dsn")
    id="${dsn##*/}"
    code=$(printf '{"dsn":"%s"}\n' "$dsn" | http -X POST "$base/api/$id/envelope/" \
      -H 'Content-Type: application/x-sentry-envelope' \
      -H @<(printf 'X-Sentry-Auth: Sentry sentry_version=7, sentry_key=%s, sentry_client=pb-uptime/1.0\n' "$key") \
      --data-binary @-)
    case "$code" in
      200) record "$name" ok ;;
      429) record "$name" fail "HTTP 429 quota exhausted: Bugsink is DROPPING every event for project $id" ;;
      *)   record "$name" fail "envelope POST HTTP $code $(errline)" ;;
    esac
  done
}

# logs_count <token> <window> -> HTTP code; body holds {"rows":"N"}. Rows with
# source=pb_probe (manual onboarding/tenancy probes) never count as shipping.
logs_count() {
  http "$LOGS_URL/select/logsql/query" \
    -H @<(printf 'Authorization: Bearer %s\n' "$1") \
    --data-urlencode "query=_time:$2 -source:pb_probe | stats count() rows"
}
rows_in_body() { num "$(grep -oE '"rows":"?[0-9]+' "$TMP/body" | grep -oE '[0-9]+$' | head -1)"; }

check_logs() {
  if [ -z "${LOGS_URL:-}" ] || [ ! -r "$LOGS_TOKENS" ]; then
    record logs-config fail "LOGS_URL unset in $CFG or $LOGS_TOKENS not readable"; return
  fi
  local vars; vars=$(grep -oE '^LOGS_R_[A-Z0-9_]+=' "$LOGS_TOKENS" | tr -d '=' | sort -u)
  if [ -z "$vars" ]; then record logs-config fail "no LOGS_R_* read tokens in $LOGS_TOKENS"; return; fi
  record logs-config ok
  local v pe proj env name tok maxage mvar code down=""
  for v in $vars; do
    pe="${v#LOGS_R_}"; env="${pe##*_}"; proj="${pe%_*}"
    name="logs-$(lower "$proj")-$(lower "$env")"
    [ -n "$down" ] && { record "$name" skip; continue; }
    mvar="LOGS_MAXAGE_$pe"; maxage="${!mvar:-}"
    if [ -z "$maxage" ]; then mvar="LOGS_MAXAGE_$env"; maxage="${!mvar:-}"; fi
    [ -z "$maxage" ] && { [ "$env" = PROD ] && maxage=30m || maxage=6h; }
    tok=$(env_val "$LOGS_TOKENS" "$v")
    code=$(logs_count "$tok" "$maxage")
    case "$code" in
      200)
        if [ "$(rows_in_body)" -gt 0 ]; then record "$name" ok
        # Silent window: a tenant that has NEVER shipped real data (minted,
        # shipper not deployed yet) is pending, not down — it starts being
        # watched the moment its first real line lands.
        elif [ "$(logs_count "$tok" "$PENDING_WINDOW")" = 200 ] && [ "$(rows_in_body)" -eq 0 ]; then
          record "$name" skip; PENDING+=("$name")
        else record "$name" fail "0 log lines in the last $maxage: shipper stalled or source silent"; fi ;;
      403) record "$name" fail "HTTP 403: read token not mapped to a tenant in the proxy" ;;
      000|5*) down=1
           record "$name" fail "log store unreachable (HTTP $code $(errline)); other tenants skipped" ;;
      *)   record "$name" fail "query HTTP $code $(head -c 120 "$TMP/body")" ;;
    esac
  done
}

check_mcp() {
  [ -z "${LOGS_MCP_URL:-}" ] && return
  local code; code=$(http "$LOGS_MCP_URL")
  if [ "$code" = 200 ]; then record logs-mcp ok
  else record logs-mcp fail "host mcp-victorialogs HTTP $code $(errline): AI log reads broken"; fi
}

check_tls() {
  local stamp="$STATE_DIR/.tls-last" lastrun
  lastrun=$(num "$(cat "$stamp" 2>/dev/null)")
  [ $((NOW - lastrun)) -lt "$TLS_EVERY_SECS" ] && return
  echo "$NOW" > "$stamp"
  local pair label url host end days
  for pair in "bugsink ${BUGSINK_URL:-}" "logs ${LOGS_URL:-}"; do
    label="${pair%% *}"; url="${pair#* }"
    case "$url" in https://*) ;; *) continue ;; esac
    host=$(sed -E 's#^https://([^/:]+).*#\1#' <<<"$url")
    end=$(echo | timeout 15 openssl s_client -servername "$host" -connect "$host:443" 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -z "$end" ]; then record "tls-$label" fail "could not read TLS cert"; continue; fi
    days=$(( ($(date -d "$end" +%s) - NOW) / 86400 ))
    if [ "$days" -ge "$TLS_MIN_DAYS" ]; then record "tls-$label" ok
    else record "tls-$label" fail "TLS cert expires in ${days}d ($end): Caddy renewal failing?"; fi
  done
}

check_bugsink
check_logs
check_mcp
check_tls

names() { local l out=""; for l in "$@"; do out+="${l%%:*}, "; done; echo "${out%, }"; }
total=$((OKS + ${#FAILED[@]}))
summary="uptime: $OKS/$total ok"
[ "${#FAILED[@]}" -gt 0 ] && summary+="; failing: ${FAILED[*]}"
[ "${#PENDING[@]}" -gt 0 ] && summary+="; pending (never shipped): ${PENDING[*]}"
echo "$summary"
if [ "${#DOWN[@]}" -gt 0 ]; then
  notify_alert critical "infra DOWN: $(names "${DOWN[@]}")" \
    "$(printf '%s\n' "${DOWN[@]}")
Runbook: claude-skills-central/infra/do-bugsink/README.md"
  echo "alert sent: ${#DOWN[@]} down"
fi
if [ "${#UP[@]}" -gt 0 ]; then
  notify_alert normal "infra recovered: $(names "${UP[@]}")" "$(printf '%s\n' "${UP[@]}")"
  echo "recovery sent: ${#UP[@]} up"
fi
exit 0
