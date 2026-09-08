#!/bin/bash
# Test suite for plugin-hooks-shell-form-guard.sh — feed PostToolUse JSON,
# assert stderr contains (or doesn't contain) the warning. Always exit 0
# (informational hook) — the test checks the warning text, not exit code.
# Run: bash plugin-hooks-shell-form-guard.test.sh   (exit 0 = all green)

HOOK="$(cd "$(dirname "$0")" && pwd)/plugin-hooks-shell-form-guard.sh"
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

write() { # write <path> <content>
  mkdir -p "$(dirname "$1")"
  printf '%s' "$2" > "$1"
}

run() { # run <file>
  jq -n --arg f "$1" '{tool_input:{file_path:$f}}' | bash "$HOOK" 2>"$TMP/err.txt" >/dev/null
  echo $?
}

BAD_JSON='{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"GRAPHITI_URL=\"${user_config.graphiti_url}\" python3 \"${CLAUDE_PLUGIN_ROOT}/x.py\"","timeout":200}]}]}}'
GOOD_JSON='{"hooks":{"SessionEnd":[{"hooks":[{"type":"command","command":"python3","args":["${CLAUDE_PLUGIN_ROOT}/x.py","--url","${user_config.graphiti_url}"],"timeout":200}]}]}}'
PLAIN_JSON='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/nudge.sh\"","timeout":5}]}]}}'

t() { # t <desc> <expect-warn:0|1> <file>
  local desc="$1" expect="$2" file="$3"
  local rc; rc=$(run "$file")
  local warned=0
  grep -q 'plugin-hooks-shell-form-guard' "$TMP/err.txt" && warned=1
  if [ "$rc" = "0" ] && [ "$warned" = "$expect" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); echo "FAIL ($desc): rc=$rc warned=$warned expect_warn=$expect"; cat "$TMP/err.txt"; fi
}

F1="$TMP/bad/hooks/hooks.json"; write "$F1" "$BAD_JSON"
t "bad manifest warns"           1 "$F1"

F2="$TMP/good/hooks/hooks.json"; write "$F2" "$GOOD_JSON"
t "exec-form manifest is quiet"  0 "$F2"

F3="$TMP/plain/hooks/hooks.json"; write "$F3" "$PLAIN_JSON"
t "plugin-root-only is quiet"    0 "$F3"

F4="$TMP/other/notes.json"; write "$F4" "$BAD_JSON"
t "non-hooks.json path ignored"  0 "$F4"

echo "plugin-hooks-shell-form-guard tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
