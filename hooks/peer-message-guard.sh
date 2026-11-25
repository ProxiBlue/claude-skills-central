#!/bin/bash
# PreToolUse SendMessage hook — restricts CROSS-MACHINE Claude peer messages
# (host session <-> DDEV container session) to approved purposes only.
#
# Why (2026-11-24, pps #428): host and the pps container share the Claude
# session registry + socket dir (pps .ddev/docker-compose.peer-messaging.yaml)
# so the #428 test-slot work can ask the host to create/destroy slots without
# chatroom traffic. Lucas: this channel is NOT a general chat. Allowed only for
# test needs, or when Lucas explicitly tells an agent to message the other side.
#
# Rule: a SendMessage whose target is a session in a DIFFERENT pid domain
# (host vs container, or one DDEV container vs another) must start its first
# line with one of:
#   [test-slot]    test-slot / parallel-test needs (#428)
#   [lucas-asked]  Lucas explicitly asked for this message or task
#   [host-task]    container asks a live host session for a host-only op of a
#                  kind Lucas already approved (cricut session, Design Space
#                  update-dlls, token/mount provisioning), and the result
#   [peer-ask]     cross-project lookup / data request between AIs, and the answer
#   [handover]     hand in-flight work to another LIVE session
# (host-task/peer-ask/handover added 2026-11-25, Lucas.) Decisions, approvals,
# merges, prod changes and automated reports stay on the chatroom board for Lucas.
# Same-domain sends (host<->host, sessions inside ONE container), in-process
# subagents/teammates and pure notify_when_idle subscriptions (no message)
# are untouched. A uds: address with no registry record is treated as
# cross-domain (fail closed).
#
# Domain = machine-id + pid namespace, as in the registry's pidDomain
# ("linux:<machine-id>:pid:[<ns>]"). machine-id alone is NOT enough: every DDEV
# web container ships the SAME /etc/machine-id (baked into ddev-webserver), so
# pps -> lcd would look "same machine". Each container has its own pid ns.
# (2026-11-25, rollout to lcd-mageos / pdftovec / ihop.)
#
# No rules-disable opt-out on purpose: the container can write rules-disable,
# so an opt-out would let one side switch the guard off for itself.
#
# Blocks with exit 2. Silent no-op if jq missing or input unparseable.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

TO=$(printf '%s' "$INPUT" | jq -r '.tool_input.to // ""' 2>/dev/null)
MSG=$(printf '%s' "$INPUT" | jq -r '.tool_input.message // ""' 2>/dev/null)
[ -z "$TO" ] && exit 0
# Pure idle subscription carries no content.
[ -z "$(printf '%s' "$MSG" | tr -d '[:space:]')" ] && exit 0

REG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
[ -d "$REG" ] || exit 0
MY_MID="${PEER_GUARD_MACHINE_ID:-$(cat /etc/machine-id 2>/dev/null)}"
[ -z "$MY_MID" ] && exit 0
# "pid:[4026531836]" -> "[4026531836]"; empty = unknown -> machine-id-only compare.
MY_NS="${PEER_GUARD_PID_NS-$(readlink /proc/self/ns/pid 2>/dev/null | sed 's/^pid://')}"

SOCK=""
case "$TO" in
  uds:*) SOCK="${TO#uds:}" ;;
  /*.sock) SOCK="$TO" ;;
esac
NAME="${TO% \[*\]}"   # "name [ref]" -> "name"

MATCHED=0
CROSS=0
for f in "$REG"/*.json; do
  [ -f "$f" ] || continue
  if [ -n "$SOCK" ]; then
    dom=$(jq -r --arg s "$SOCK" 'select(.messagingSocketPath == $s) | .pidDomain // "?"' "$f" 2>/dev/null)
  else
    dom=$(jq -r --arg n "$NAME" 'select(.name == $n) | .pidDomain // "?"' "$f" 2>/dev/null)
  fi
  [ -z "$dom" ] && continue
  MATCHED=1
  # pidDomain = linux:<machine-id>:pid:[<ns>]; "?" = no domain recorded -> local.
  [ "$dom" = "?" ] && continue
  mid=$(printf '%s' "$dom" | cut -d: -f2)
  ns=$(printf '%s' "$dom" | cut -d: -f4)
  if [ -n "$mid" ] && [ "$mid" != "$MY_MID" ]; then
    CROSS=1
  elif [ -n "$MY_NS" ] && [ -n "$ns" ] && [ "$ns" != "$MY_NS" ]; then
    CROSS=1
  fi
done

if [ "$MATCHED" = 0 ]; then
  # Named target with no session record = teammate/subagent/main: not ours.
  [ -z "$SOCK" ] && exit 0
  CROSS=1
fi
[ "$CROSS" = 0 ] && exit 0

FIRST=$(printf '%s\n' "$MSG" | sed -n '/[^[:space:]]/{s/^[[:space:]]*//;p;q}')
case "$FIRST" in
  "[test-slot]"*|"[lucas-asked]"*|"[host-task]"*|"[peer-ask]"*|"[handover]"*) exit 0 ;;
esac

cat >&2 <<'EOF'
BLOCKED by peer-message-guard: host <-> container (and container <-> container)
Claude messaging is restricted.
It is NOT a general chat channel. Allowed only for:
  [test-slot]    test-slot / parallel-test needs (#428), e.g. "[test-slot] GO t1"
  [lucas-asked]  Lucas explicitly asked you to send this message or task
  [host-task]    ask a live host session for a host-only op Lucas already approved
                 in kind (cricut session, update-dlls, token/mount provisioning)
  [peer-ask]     cross-project lookup / data request between AIs, or its answer
  [handover]     hand in-flight work to another live session
Start the message's first line with one of those tags. If none applies, do
not send it. Decisions, approvals, merges, prod changes and reports go on the
pb-chatroom board for Lucas.
EOF
exit 2
