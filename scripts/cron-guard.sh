#!/bin/bash
# cron-guard.sh <job-name> <command...>
#
# Wraps a raw crontab line that is NOT dispatched through monitor.sh (those
# already get failure alerts from run_job). Passes stdout/stderr straight
# through so existing `>> log 2>&1` redirects in the crontab keep working
# unchanged, and on nonzero exit fires the same desktop+email+alerts.log
# alert monitor.sh jobs get — so a broken cron shows up on the dashboard's
# "Recent alerts" panel instead of failing silently into a log nobody reads.
#
# Cooldown avoids alert storms from fast-repeating crons (e.g.
# git-lock-reaper, every ~9s): at most one alert per job per $COOLDOWN
# seconds, state tracked in ~/monitor/heartbeats/cron-guard-<name>.last-alert.
# The wrapped command still runs every time regardless of cooldown — only
# the alert is throttled.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$DIR/notify-lib.sh"

NAME="${1:?usage: cron-guard.sh <job-name> <command...>}"; shift
[ $# -ge 1 ] || { echo "cron-guard.sh: no command given for job '$NAME'" >&2; exit 2; }

COOLDOWN="${COOLDOWN:-1800}"
STATE_DIR="$HOME/monitor/heartbeats"
STATE="$STATE_DIR/cron-guard-$NAME.last-alert"

out=$("$@" 2>&1); rc=$?
printf '%s\n' "$out"

if [ "$rc" -ne 0 ]; then
  now=$(date +%s)
  last=$(cat "$STATE" 2>/dev/null || echo 0)
  if [ $(( now - last )) -ge "$COOLDOWN" ]; then
    mkdir -p "$STATE_DIR"
    echo "$now" > "$STATE"
    notify_alert critical "cron: $NAME failed (rc=$rc)" "$(echo "$out" | tail -3)"
  fi
fi
exit $rc
