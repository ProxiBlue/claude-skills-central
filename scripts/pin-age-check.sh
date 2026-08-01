#!/bin/bash
# Pin-age forcing function — makes the claude-code version pin a DATED decision
# that expires, not a default that fossilizes. Closes rec #5 of the 2026-07-31
# tooling review.
#
# The pin decision lives in host/pin-decision.json (fleet_target, set_on,
# review_after_days, releases_behind_threshold). This checks it against today
# and against upstream, and escalates via chatroom when the pin is stale by
# EITHER measure:
#   - age:      today - set_on > review_after_days
#   - lag:      count of releases between fleet_target and upstream latest
#               > releases_behind_threshold
#
# Escalation posts a chatroom thread (host-auto -> host) telling you to run
# rule-evals against the newest version and then either RENEW or MOVE the pin.
# Renewing/moving re-dates the decision so it expires again — that is the
# forcing function: the pin cannot silently rot.
#
# Subcommands:
#   pin-age-check.sh                 check + (if stale) escalate
#   pin-age-check.sh --dry-run       check + print, never post
#   pin-age-check.sh --renew         keep same version, reset set_on=today
#   pin-age-check.sh --set X.Y.Z     record a NEW fleet target (set_on=today,
#                                    appends to history). Run rule-evals FIRST.
#
# Note: --set/--renew only update the DECISION RECORD. Actually changing the
# pin in each project's .ddev install hook is the phase-2 walk; this file is
# the source of truth the fleet aligns to and the dashboard reads.

set -u
DECISION="$HOME/claude-skills-central/host/pin-decision.json"
STATEDIR="$HOME/monitor/harness-watch"
CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"
TODAY=$(date +%F)

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
[ -f "$DECISION" ] || { echo "no decision file at $DECISION"; exit 2; }

read_json() { jq -r "$1" "$DECISION"; }

# ---- subcommands that mutate the decision record -----------------------------
case "${1:-}" in
  --renew)
    V=$(read_json '.fleet_target')
    tmp=$(mktemp)
    jq --arg d "$TODAY" --arg v "$V" \
       '.set_on=$d | .history += [{"version":$v,"set_on":$d,"reason":"renewed — held after review"}]' \
       "$DECISION" > "$tmp" && mv "$tmp" "$DECISION"
    echo "renewed $V, set_on=$TODAY"
    exit 0 ;;
  --set)
    NEW="${2:-}"
    [ -z "$NEW" ] && { echo "usage: --set X.Y.Z"; exit 2; }
    tmp=$(mktemp)
    jq --arg d "$TODAY" --arg v "$NEW" \
       '.fleet_target=$v | .set_on=$d | .history += [{"version":$v,"set_on":$d,"reason":"moved after rule-evals"}]' \
       "$DECISION" > "$tmp" && mv "$tmp" "$DECISION"
    echo "fleet_target set to $NEW, set_on=$TODAY (align projects in phase-2; commit host/pin-decision.json)"
    exit 0 ;;
esac

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1

TARGET=$(read_json '.fleet_target')
SET_ON=$(read_json '.set_on')
MAX_DAYS=$(read_json '.review_after_days')
MAX_LAG=$(read_json '.releases_behind_threshold')

# age in days
SET_EPOCH=$(date -d "$SET_ON" +%s 2>/dev/null || echo 0)
NOW_EPOCH=$(date +%s)
AGE_DAYS=$(( (NOW_EPOCH - SET_EPOCH) / 86400 ))

# upstream latest (prefer harness-watch's last-seen; fall back to npm)
UPSTREAM=""
[ -f "$STATEDIR/last-seen" ] && UPSTREAM=$(cat "$STATEDIR/last-seen")
[ -z "$UPSTREAM" ] && UPSTREAM=$(npm view @anthropic-ai/claude-code version 2>/dev/null)
[ -z "$UPSTREAM" ] && UPSTREAM="unknown"

# releases between target and upstream: count '## X.Y.Z' changelog headers
# strictly above target (i.e. newer). Best-effort; 0 if changelog unavailable.
LAG=0
if [ "$UPSTREAM" != "unknown" ] && [ "$UPSTREAM" != "$TARGET" ]; then
  CL=$(curl -sf https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md 2>/dev/null || true)
  if [ -n "$CL" ]; then
    LAG=$(printf '%s\n' "$CL" | awk -v t="## $TARGET" '
      /^## [0-9]+\.[0-9]+\.[0-9]+/ { if ($0==t) exit; c++ } END{ print c+0 }')
  else
    LAG="?"
  fi
fi

AGE_STALE=0; [ "$AGE_DAYS" -gt "$MAX_DAYS" ] && AGE_STALE=1
LAG_STALE=0; case "$LAG" in ''|*[!0-9]*) : ;; *) [ "$LAG" -gt "$MAX_LAG" ] && LAG_STALE=1 ;; esac

SUMMARY="Pin $TARGET set $SET_ON (${AGE_DAYS}d ago, limit ${MAX_DAYS}d). Upstream $UPSTREAM, ~${LAG} releases ahead (limit ${MAX_LAG})."
echo "$SUMMARY"

if [ "$AGE_STALE" = "0" ] && [ "$LAG_STALE" = "0" ]; then
  echo "pin fresh — no action"
  exit 0
fi

REASONS=""
[ "$AGE_STALE" = "1" ] && REASONS="${REASONS}age ${AGE_DAYS}d > ${MAX_DAYS}d; "
[ "$LAG_STALE" = "1" ] && REASONS="${REASONS}~${LAG} releases behind > ${MAX_LAG}; "
echo "STALE: $REASONS"

if [ "$DRY" = "1" ]; then echo "(dry-run: not posted)"; exit 0; fi

# Debounce: escalate on transition-to-stale, then at most weekly, and again
# whenever the target changes — so a standing lag nags weekly, not daily.
DEBOUNCE="$STATEDIR/pin-escalation-state"
mkdir -p "$STATEDIR"
if [ -f "$DEBOUNCE" ]; then
  LAST_TARGET=$(cut -f1 "$DEBOUNCE"); LAST_DATE=$(cut -f2 "$DEBOUNCE")
  LAST_EPOCH=$(date -d "$LAST_DATE" +%s 2>/dev/null || echo 0)
  DAYS_SINCE=$(( (NOW_EPOCH - LAST_EPOCH) / 86400 ))
  if [ "$LAST_TARGET" = "$TARGET" ] && [ "$DAYS_SINCE" -lt 7 ]; then
    echo "(already escalated ${DAYS_SINCE}d ago for $TARGET — debounced)"
    exit 0
  fi
fi
printf '%s\t%s\n' "$TARGET" "$TODAY" > "$DEBOUNCE"

BODY="Pin re-evaluation due. $SUMMARY
Trigger: $REASONS

Decide — do NOT let it fossilize:
1. bash ~/claude-skills-central/scripts/rule-evals.sh   (must be 8/8 against the candidate build)
2a. MOVE:  pin-age-check.sh --set $UPSTREAM  then align projects (phase-2) + commit host/pin-decision.json
2b. HOLD:  pin-age-check.sh --renew           (re-dates the decision; deliberate, not default)

Registry + dashboard read host/pin-decision.json as the fleet source of truth."

curl -sS -X POST "${CHATROOM_URL}/api/threads" \
  -H "Content-Type: application/json" \
  -H "X-PB-Chatroom-Participant: host-auto" \
  -d "$(python3 -c "import json,sys;print(json.dumps({'to':'host','subject':'Pin re-eval due: claude-code $TARGET stale','body':sys.stdin.read(),'discussion_type':'postmortem'}))" <<< "$BODY")" \
  >/dev/null 2>&1 && echo "(escalation posted to chatroom)"
