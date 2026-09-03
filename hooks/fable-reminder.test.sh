#!/bin/bash
# Test suite for fable-reminder.sh — feed UserPromptSubmit JSON, assert the
# decision:block JSON shape / passthrough behavior.
# Run: bash fable-reminder.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/fable-reminder.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

run() { # run <prompt>
  OUT=$(printf '{"prompt":%s}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK" 2>/dev/null)
}

# --- blocks: bare /hcf:plan-create --------------------------------------------
run '/hcf:plan-create 385 add checkout validation'
if echo "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
   && echo "$OUT" | jq -r '.reason' | grep -qi "fable"; then
  ok
else
  bad "expected decision:block with fable in reason, got: $OUT"
fi

# --- blocks: hcf:plan-create without leading slash -----------------------------
run 'please run hcf:plan-create for ticket 400'
echo "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 && ok || bad "expected block on bare hcf:plan-create, got: $OUT"

# --- bypass: confirm-fable token ------------------------------------------------
run '/hcf:plan-create 385 confirm-fable'
[ -z "$OUT" ] && ok || bad "expected silent passthrough with confirm-fable bypass, got: $OUT"

# --- silent: unrelated prompt ----------------------------------------------------
run 'what does this function do?'
[ -z "$OUT" ] && ok || bad "expected silent on unrelated prompt, got: $OUT"

# --- silent: mentions plan-create as prose, not a command invocation -------------
run 'I used hcf:plan-create-like workflow yesterday'
[ -z "$OUT" ] && ok || bad "expected silent — not a real command match, got: $OUT"

echo "fable-reminder tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
