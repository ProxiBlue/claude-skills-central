#!/bin/bash
# Weekly backburner-project reminders. Reads ~/.config/project-reminders.tsv
# (one line: <graphiti-group>\t<nudge>) and posts each as a low-key chatroom
# thread (host-auto -> host) so idle ideas resurface in the session inbox +
# morning digest. Passive nudge channel by design — not a desktop/email alert.
#
# Add a line to the tsv to get a weekly reminder; remove it when the project
# goes active or is abandoned.

set -u
CFG="$HOME/.config/project-reminders.tsv"
CHATROOM_URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"
[ -f "$CFG" ] || { echo "no $CFG"; exit 0; }

posted=0
while IFS=$'\t' read -r group nudge; do
  case "$group" in ''|\#*) continue ;; esac
  [ -n "$nudge" ] || continue
  body="Backburner nudge: $nudge

(Weekly reminder so it doesn't get lost. Ack to snooze this week; remove its line from ~/.config/project-reminders.tsv to stop.)"
  curl -sS -X POST "${CHATROOM_URL}/api/threads" \
    -H "Content-Type: application/json" \
    -H "X-PB-Chatroom-Participant: host-auto" \
    -d "$(python3 -c "import json,sys;print(json.dumps({'to':'host','subject':'Reminder: '+sys.argv[1]+' project','body':sys.argv[2],'discussion_type':'postmortem'}))" "$group" "$body")" \
    >/dev/null 2>&1 && { echo "reminded: $group"; posted=$((posted+1)); }
done < "$CFG"
echo "posted $posted reminder(s)"
