#!/bin/bash
# Test suite for peer-message-guard.sh — fake session registry + machine-id,
# feed PreToolUse JSON, assert exit code. Run: bash peer-message-guard.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/peer-message-guard.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/sessions"

HOST_MID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CONT_MID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HOST_NS='[4026531836]'
PPS_NS='[4026534345]'
LCD_NS='[4026539999]'
rec() { # rec <pid> <name> <mid> <sock> [ns]
  jq -n --arg n "$2" --arg d "linux:$3:pid:${5:-$HOST_NS}" --arg s "$4" \
    '{pid:1, name:$n, pidDomain:$d, messagingSocketPath:$s}' >"$TMP/sessions/$1.json"
}
rec 100 host-ops   "$HOST_MID" /run/user/1000/cc-socks/100.sock
rec 200 host-other "$HOST_MID" /run/user/1000/cc-socks/200.sock
rec 300 pps-428    "$CONT_MID" /tmp/cc-socks/300.sock "$PPS_NS"
# Every DDEV web container has the SAME machine-id; only the pid ns differs.
rec 310 pps-mate   "$CONT_MID" /tmp/cc-socks/310.sock "$PPS_NS"
rec 320 lcd-main   "$CONT_MID" /tmp/cc-socks/320.sock "$LCD_NS"
jq -n --arg d "linux:$CONT_MID" '{pid:330, name:"no-ns", pidDomain:$d}' >"$TMP/sessions/330.json"
jq -n '{pid:400, name:"legacy"}' >"$TMP/sessions/400.json"   # no pidDomain
echo 'not json' >"$TMP/sessions/500.json"

t() { # t <expected-exit> <desc> <to> <message>
  local expect="$1" desc="$2" to="$3" msg="$4"
  jq -n --arg t "$to" --arg m "$msg" '{tool_name:"SendMessage", tool_input:{to:$t, message:$m}}' \
    | CLAUDE_CONFIG_DIR="$TMP" PEER_GUARD_MACHINE_ID="$HOST_MID" PEER_GUARD_PID_NS="$HOST_NS" bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — to=$to msg=$msg"; fi
}

# --- cross-machine (host -> container), untagged: blocked --------------------
t 2 "cross by name untagged"      "pps-428"         "hey how is the build going"
t 2 "cross by name+ref untagged"  "pps-428 [abc123]" "random chat"
t 2 "cross by uds untagged"       "uds:/tmp/cc-socks/300.sock" "pong"
t 2 "tag not on first line"       "pps-428"         $'hello\n[test-slot] GO t1'
t 2 "lookalike tag"               "pps-428"         "[test-slots] GO t1"
t 2 "unknown uds fails closed"    "uds:/tmp/cc-socks/999.sock" "hi"

# --- cross-machine, tagged: allowed --------------------------------------------
t 0 "test-slot tag"               "pps-428"         "[test-slot] GO t1"
t 0 "lucas-asked tag"             "pps-428 [abc123]" "[lucas-asked] please rebase"
t 0 "tag after leading blanks"    "uds:/tmp/cc-socks/300.sock" $'\n  [test-slot] t1 ready'
t 0 "pure idle subscription"      "pps-428"         ""
t 0 "host-task tag"               "pps-428"         "[host-task] start a cricut session"
t 0 "peer-ask tag"                "pps-428"         "[peer-ask] which bugsink project id is uat?"
t 0 "handover tag"                "pps-428"         "[handover] Google startups application, state below"
t 2 "lookalike host-tasks"        "pps-428"         "[host-tasks] do it"
t 2 "tag mid-line"                "pps-428"         "please [peer-ask] answer"

# --- same machine / not a session peer: untouched ------------------------------
t 0 "host to host untagged"       "host-other"      "anything goes here"
t 0 "same-machine uds"            "uds:/run/user/1000/cc-socks/200.sock" "hi"
t 0 "record without pidDomain"    "legacy"          "hi"
t 0 "teammate / subagent name"    "researcher"      "start task 1"
t 0 "main"                        "main"            "done"

# --- container side: container -> host untagged blocked, tagged allowed -------
tc() {
  local expect="$1" desc="$2" to="$3" msg="$4"
  jq -n --arg t "$to" --arg m "$msg" '{tool_name:"SendMessage", tool_input:{to:$t, message:$m}}' \
    | CLAUDE_CONFIG_DIR="$TMP" PEER_GUARD_MACHINE_ID="$CONT_MID" PEER_GUARD_PID_NS="$PPS_NS" bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): expected exit $expect got $got — to=$to msg=$msg"; fi
}
tc 2 "container->host untagged"   "host-ops"        "fyi I finished lunch"
tc 0 "container->host tagged"     "host-ops"        "[test-slot] GO t1"
# container -> OTHER container (same machine-id, different pid ns): cross.
tc 2 "pps->lcd untagged"          "lcd-main"        "hey lcd, quick question"
tc 2 "pps->lcd uds untagged"      "uds:/tmp/cc-socks/320.sock" "hi"
tc 0 "pps->lcd tagged"            "lcd-main"        "[lucas-asked] send me your bugsink ids"
tc 0 "same container untagged"    "pps-mate"        "anything inside one container"
tc 0 "record without ns, same mid" "no-ns"          "hi"
t  2 "host->lcd untagged"         "lcd-main"        "hi"

# --- defensive ------------------------------------------------------------------
echo '' | bash "$HOOK" >/dev/null 2>&1; [ $? = 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "FAIL (empty input)"; }

echo "peer-message-guard: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
