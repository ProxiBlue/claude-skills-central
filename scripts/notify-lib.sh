# notify-lib.sh — shared alert delivery (desktop + email + persistent log).
# Sourced by monitor.sh (dispatched telemetry jobs) and cron-guard.sh (raw
# crontab lines) so both paths fire the same alert, land in the same
# alerts.log, and show up in the dashboard's "Recent alerts" panel.
#
# Actionable alerts fire a DESKTOP popup when you're at the machine, plus an
# EMAIL backup for when you're away. Desktop is best-effort (needs an active
# X session); email is best-effort (needs SMTP creds in the config file
# below). Neither failing ever blocks the caller.
#
# Email backup uses Resend's HTTP API (same provider ai_assistant/webhooks
# already uses — no MTA, no SMTP). Config at ~/.config/monitor-notify.env;
# the shipped template sources the key LIVE from the ai_assistant .env so
# the secret is never duplicated. Needs: RESEND_API_KEY, NOTIFY_EMAIL_TO,
# RESEND_FROM_EMAIL.
NOTIFY_CFG="$HOME/.config/monitor-notify.env"
ALERT_LOG="$HOME/monitor/alerts.log"

notify_desktop() {  # <urgency> <title> <body>
  command -v notify-send >/dev/null 2>&1 || return 0
  local u=$(id -u)
  DISPLAY="${DISPLAY:-:0}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$u/bus}" \
    notify-send -u "$1" -a "monitor" "$2" "$3" 2>/dev/null || true
}

notify_email() {  # <subject> <body>
  [ -f "$NOTIFY_CFG" ] || return 0
  # shellcheck disable=SC1090
  . "$NOTIFY_CFG"
  [ -n "${RESEND_API_KEY:-}" ] && [ -n "${NOTIFY_EMAIL_TO:-}" ] || return 0
  local from="${RESEND_FROM_EMAIL:-monitor <onboarding@resend.dev>}"
  local payload
  payload=$(NOTIFY_EMAIL_TO="$NOTIFY_EMAIL_TO" FROM="$from" SUBJ="$1" BODY="$2" \
    python3 -c 'import json,os; print(json.dumps({
      "from": os.environ["FROM"], "to": [os.environ["NOTIFY_EMAIL_TO"]],
      "subject": "[monitor] " + os.environ["SUBJ"],
      "text": os.environ["BODY"]}))')
  curl -sS -X POST "https://api.resend.com/emails" \
    -H "Authorization: Bearer ${RESEND_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null 2>&1 || true
}

mkdir -p "$(dirname "$ALERT_LOG")"
notify_alert() {  # <urgency> <title> <body>
  # Persist FIRST — a transient popup you miss is gone, but the log and the
  # dashboard 'Recent alerts' panel keep every alert findable later.
  printf '%s\t%s\t%s\t%s\n' "$(date -Iseconds)" "$1" "$2" \
    "$(echo "$3" | tr '\n' ' ' | cut -c1-200)" >> "$ALERT_LOG"
  # rotate at ~500 lines
  if [ "$(wc -l < "$ALERT_LOG" 2>/dev/null || echo 0)" -gt 500 ]; then
    tail -n 300 "$ALERT_LOG" > "$ALERT_LOG.tmp" && mv "$ALERT_LOG.tmp" "$ALERT_LOG"
  fi
  notify_desktop "$1" "$2" "$3"
  notify_email "$2" "$3"
}
