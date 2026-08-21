#!/bin/bash
# monitor — single entrypoint for the telemetry/health surface.
#
# Solves the "maintenance surface grew" risk not by adding a watcher, but by
# (a) collapsing 7 scripts + 7 cron lines behind ONE command, and (b) recording
# a heartbeat for every run so a silently-dead job becomes visible on the
# dashboard the operator already opens daily. No new alert channel, no
# watcher-of-watchers.
#
# Usage:
#   monitor <job>        run a job, record its heartbeat (used by cron)
#   monitor all-daily    run every daily job in sequence
#   monitor all-weekly   run every weekly job
#   monitor health       print each job's last-run age vs its max age; exit 1 if any stale
#   monitor list         show the job registry
#
# Jobs registry: name | script (relative to this dir, or absolute) | args | cadence-max-days
# cadence-max-days is how many days without a run counts as STALE (the dead-man
# threshold). The dashboard reads the same heartbeats + thresholds.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HB="$HOME/monitor/heartbeats"; mkdir -p "$HB"
GRAPHITI_BACKUP="$HOME/claude-plugins-central/seed/marketplaces/pb-graphiti/scripts/backup.sh"

# --- alert delivery -----------------------------------------------------------
# Actionable alerts (job failed / escalated / collector dead) fire a DESKTOP
# popup when you're at the machine, plus an EMAIL backup for when you're away.
# Passive weekly digests stay in chatroom only. Delivery functions live in
# notify-lib.sh (shared with cron-guard.sh, which wraps raw crontab lines that
# don't go through this dispatcher — same alert path, same alerts.log).
# shellcheck disable=SC1091
source "$DIR/notify-lib.sh"

# name          command                                  args             maxdays  freq
JOBS="
drift          $DIR/fleet-drift-check.sh                 ''               8        weekly
usage          $DIR/usage_telemetry.py                   ''               8        weekly
evals          $DIR/rule-evals.sh                        --notify         32       monthly
dashboard      $DIR/telemetry_dashboard.py               ''               2        daily
harness        $DIR/harness-release-watch.sh             ''               2        daily
pin            $DIR/pin-age-check.sh                      ''               2        daily
graphiti-backup $GRAPHITI_BACKUP                         ''               2        daily
graphiti-offsite $DIR/backup-offsite.sh                  ''               2        daily
bugsink-pull   $DIR/bugsink-prod-pull.py                 ''               2        daily
dep-audit      $DIR/dep-audit.sh                          ''               2        daily
"

job_field() { echo "$JOBS" | awk -v n="$1" -v f="$2" '$1==n{print $f}'; }

run_job() {
  local name="$1" cmd args
  cmd=$(job_field "$name" 2); args=$(job_field "$name" 3)
  [ -z "$cmd" ] && { echo "unknown job: $name" >&2; return 2; }
  [ "$args" = "''" ] && args=""
  local start out rc; start=$(date +%s)
  # capture output so we can detect content-level escalations, but still show it
  # shellcheck disable=SC2086
  out=$("$cmd" $args 2>&1); rc=$?
  echo "$out"
  printf '%s\t%s\t%s\n' "$(date -Iseconds)" "$rc" "$(( $(date +%s) - start ))s" \
    > "$HB/$name"

  # Alert on job FAILURE (couldn't run cleanly)...
  if [ "$rc" -ne 0 ] && [ "$name" != "evals" ]; then
    # evals exits 1 by design on any FAIL — handled as escalation below, not a crash
    notify_alert critical "monitor: $name failed (rc=$rc)" \
      "$(echo "$out" | tail -3)"
  fi
  # ...or on an ACTIONABLE content escalation the job printed.
  case "$name" in
    pin)   echo "$out" | grep -q 'STALE:' && notify_alert critical \
             "Pin re-eval due" "$(echo "$out" | grep -E 'Pin |STALE:' | head -2)" ;;
    drift) echo "$out" | grep -q 'drift detected' && notify_alert normal \
             "Fleet drift detected" "$(echo "$out" | grep -i 'drift\|stale' | head -2)" ;;
    evals) echo "$out" | grep -qE 'fail=[1-9]' && notify_alert critical \
             "Rule evals FAILING" "$(echo "$out" | grep -E ' FAIL |fail=[1-9]' | head -4)" ;;
    harness) echo "$out" | grep -q 'alert posted' && notify_alert normal \
             "New claude-code release" "$(echo "$out" | tail -1)" ;;
  esac
  return $rc
}

# health with optional --notify: fire a desktop+email alert per dead/stale job
health_notify() {
  local out; out=$(health); local rc=$?
  echo "$out"
  if [ "$rc" -ne 0 ]; then
    notify_alert critical "monitor: collector(s) stale" \
      "$(echo "$out" | grep -E 'STALE|NO HEARTBEAT')"
  fi
  return $rc
}

health() {
  local now stale=0
  now=$(date +%s)
  printf '%-16s %-8s %-10s %s\n' JOB LAST AGE STATUS
  while read -r name cmd args maxd freq; do
    [ -z "$name" ] && continue
    local hbf="$HB/$name" last age status
    if [ -f "$hbf" ]; then
      last=$(cut -f1 "$hbf")
      age=$(( (now - $(date -d "$last" +%s 2>/dev/null || echo "$now")) / 86400 ))
      if [ "$age" -gt "$maxd" ]; then status="STALE (>${maxd}d)"; stale=1
      else status="ok"; fi
      printf '%-16s %-8s %-10s %s\n' "$name" "${last%%T*}" "${age}d" "$status"
    else
      printf '%-16s %-8s %-10s %s\n' "$name" "never" "-" "NO HEARTBEAT"; stale=1
    fi
  done <<< "$(echo "$JOBS" | sed '/^\s*$/d')"
  return $stale
}

case "${1:-}" in
  list)  echo "$JOBS" | sed '/^\s*$/d' | awk '{printf "  %-16s %-8s %s\n",$1,$5,$2}' ;;
  health) [ "${2:-}" = "--notify" ] && health_notify || health ;;
  alerts) tail -n "${2:-20}" "$ALERT_LOG" 2>/dev/null | tac ;;
  test-alert) notify_alert "${2:-normal}" "monitor test alert" "desktop + email + logged; findable in 'monitor alerts' and on the dashboard" ; echo "sent" ;;
  all-daily)  for j in harness pin dashboard bugsink-pull dep-audit; do echo "-- $j"; run_job "$j"; done; health_notify >/dev/null ;;
  all-backup) run_job graphiti-backup && run_job graphiti-offsite ;;
  all-weekly) for j in drift usage; do echo "-- $j"; run_job "$j"; done ;;
  "" ) echo "usage: monitor <job|all-daily|all-weekly|health|list>"; exit 2 ;;
  *) run_job "$1" ;;
esac
