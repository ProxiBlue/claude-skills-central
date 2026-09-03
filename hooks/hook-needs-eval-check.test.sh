#!/bin/bash
# Test suite for hook-needs-eval-check.sh — feed PostToolUse JSON, assert
# warning presence/absence (never blocks — exit always 0).
# Run: bash hook-needs-eval-check.test.sh

HOOK="$(cd "$(dirname "$0")" && pwd)/hook-needs-eval-check.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

D=$(mktemp -d)
mkdir -p "$D/hooks"
git -C "$D" init -q .
cd "$D" || exit 1

run() { # run <file_path>
  printf '{"tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)" | bash "$HOOK" > /tmp/hnec-out.txt 2>&1
  RC=$?
}

# --- warns: new hook script, no sibling test ------------------------------------
touch "$D/hooks/new-guard.sh"
run "$D/hooks/new-guard.sh"
if [ "$RC" = 0 ] && grep -q "no test coverage\|no.*test.*alongside" /tmp/hnec-out.txt; then
  ok
else
  bad "expected warning for hook with no sibling test, rc=$RC out=$(cat /tmp/hnec-out.txt)"
fi

# --- silent: hook script WITH sibling test --------------------------------------
touch "$D/hooks/new-guard.test.sh"
run "$D/hooks/new-guard.sh"
[ "$RC" = 0 ] && [ ! -s /tmp/hnec-out.txt ] && ok || bad "expected silent once sibling test exists, got: $(cat /tmp/hnec-out.txt)"
rm "$D/hooks/new-guard.test.sh"

# --- silent: editing the .test.sh file itself -------------------------------------
run "$D/hooks/new-guard.test.sh"
[ ! -s /tmp/hnec-out.txt ] && ok || bad "expected silent when the edited file IS a .test.sh"

# --- silent: not under hooks/ --------------------------------------------------
mkdir -p "$D/scripts"
touch "$D/scripts/something.sh"
run "$D/scripts/something.sh"
[ ! -s /tmp/hnec-out.txt ] && ok || bad "expected silent for non-hooks/ path"

# --- silent: non-.sh/.py file under hooks/ --------------------------------------
touch "$D/hooks/README.md"
run "$D/hooks/README.md"
[ ! -s /tmp/hnec-out.txt ] && ok || bad "expected silent for non-script file"

# --- billing family: shares ONE combined test file ------------------------------
run "$D/hooks/billing-precompact-guard.py"
if [ "$RC" = 0 ] && grep -q "billing-context-guard.test.sh" /tmp/hnec-out.txt; then
  ok
else
  bad "expected billing-family warning pointing at combined test file, got: $(cat /tmp/hnec-out.txt)"
fi

touch "$D/hooks/billing-context-guard.test.sh"
run "$D/hooks/billing-clear-end.py"
[ ! -s /tmp/hnec-out.txt ] && ok || bad "expected silent once combined billing test file exists, got: $(cat /tmp/hnec-out.txt)"

# --- rules-disable opt-out ---------------------------------------------------------
mkdir -p "$D/.claude" && echo hook-needs-eval-check > "$D/.claude/rules-disable"
run "$D/hooks/another-new-guard.sh"
[ ! -s /tmp/hnec-out.txt ] && ok || bad "expected silent with rules-disable opt-out, got: $(cat /tmp/hnec-out.txt)"

cd /
rm -rf "$D" /tmp/hnec-out.txt

echo "hook-needs-eval-check tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
