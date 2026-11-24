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
# Rule: a SendMessage whose target is a session on a DIFFERENT machine-id
# (container vs host) must start its first line with one of:
#   [test-slot]    test-slot / parallel-test needs (#428)
#   [lucas-asked]  Lucas explicitly asked for this message or task
# Same-machine sends (host<->host, container<->container), in-process
# subagents/teammates and pure notify_when_idle subscriptions (no message)
# are untouched. A uds: address with no registry record is treated as
# cross-machine (fail closed).
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
  mid=$(printf '%s' "$dom" | cut -d: -f2)
  if [ "$dom" != "?" ] && [ -n "$mid" ] && [ "$mid" != "$MY_MID" ]; then
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
  "[test-slot]"*|"[lucas-asked]"*) exit 0 ;;
esac

cat >&2 <<'EOF'
BLOCKED by peer-message-guard: host <-> container Claude messaging is restricted.
It is NOT a general chat channel. Allowed only for:
  [test-slot]    test-slot / parallel-test needs (#428), e.g. "[test-slot] GO t1"
  [lucas-asked]  Lucas explicitly asked you to send this message or task
Start the message's first line with one of those tags. If neither applies, do
not send it: use the pb-chatroom thread, or ask Lucas.
EOF
exit 2
