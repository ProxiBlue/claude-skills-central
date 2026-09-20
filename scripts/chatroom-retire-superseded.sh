#!/usr/bin/env bash
# Close chatroom threads that a newer one has superseded.
#
# Recurring notifiers post SNAPSHOTS: a morning digest, a fleet-drift report,
# a release summary. Each is only interesting until the next one arrives, but
# every one of them opens a fresh thread and none is ever closed, so the open
# inbox fills with stale copies of the same report. On 2026-09-20 that was 15
# morning digests and 17 pb-watch alerts out of 56 open threads -- the real
# threads were a minority of their own inbox.
#
# So: after posting the new one, retire the older ones.
#
# Usage: chatroom-retire-superseded.sh <subject-prefix> [keep-thread-id]
#
#   subject-prefix   match threads whose subject starts with this
#   keep-thread-id   leave this one open (the one just posted)
#
# Only ever touches OPEN threads created by this host's automation
# (host-auto), addressed to host. A human-authored thread that happens to
# share the prefix is left alone -- a notifier must not close someone's work.
#
# Acking rather than deleting: the content stays readable, and the retention
# prune removes it on its own schedule. Note that an ack posts a message and
# therefore resets that thread's prune clock (verified 2026-09-20) -- the
# thread lives ~14 more days, just not in the open inbox.
#
# Defensive: never fails the caller. A notifier must still succeed if the
# chatroom is unreachable.
set -u

PREFIX=${1:-}
KEEP=${2:-}
[ -n "$PREFIX" ] || { echo "usage: chatroom-retire-superseded.sh <subject-prefix> [keep-thread-id]" >&2; exit 2; }

URL="${PB_CHATROOM_REST_URL:-http://127.0.0.1:7476}"
IDENTITY="${PB_CHATROOM_PARTICIPANT_ID:-host-auto}"

command -v curl >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

THREADS=$(curl -sS -m 10 "$URL/api/threads?to=host&status=open" \
  -H "X-PB-Chatroom-Participant: $IDENTITY" 2>/dev/null) || exit 0
[ -n "$THREADS" ] || exit 0

IDS=$(printf '%s' "$THREADS" | python3 -c "
import sys, json
try:
    threads = json.load(sys.stdin)
except Exception:
    sys.exit(0)
prefix, keep = sys.argv[1], sys.argv[2]
for t in threads:
    if t.get('id') == keep:
        continue
    # host-auto only: never close a thread a person opened.
    if t.get('created_by') != 'host-auto':
        continue
    if str(t.get('subject', '')).startswith(prefix):
        print(t['id'])
" "$PREFIX" "$KEEP" 2>/dev/null) || exit 0

n=0
for id in $IDS; do
  curl -sS -m 10 -X POST "$URL/api/threads/$id/ack" \
    -H "X-PB-Chatroom-Participant: $IDENTITY" \
    -H 'Content-Type: application/json' \
    -d '{"body":"Superseded by a newer report. Closed automatically; nothing was actioned."}' \
    >/dev/null 2>&1 && n=$((n+1))
done
echo "retired $n superseded thread(s) matching '$PREFIX'"
exit 0
